#!/usr/bin/env bash
# stalled-deal-watcher.sh — proactive Telegram nudge for GHL opportunities
# that have gone stale.
#
# Calls GHL's /opportunities/search endpoint directly (no LLM, no MCP) so
# this is cheap to run hourly. Reads credentials from agents/.mcp.json so
# there's a single source of truth (matches reference_canonical_paths
# memory: "If you ever see them diverge, the canonical source is the VPS
# agent's .mcp.json").
#
# Stalled criteria (all must be true):
#   - status == open (not won/lost/abandoned)
#   - monetaryValue >= MIN_VALUE_USD (default $2,000)
#   - days since updatedAt >= STALE_DAYS (default 7)
#
# Nudge cadence: one nudge per stalled deal per 7-day calendar window.
# If a deal stays stalled across multiple weeks, you get one ping per week
# until it moves or you mark it abandoned.
#
# Dedup via {{TENANT_AGENT_HOME}}/notifications/stalled-deal-nudges.jsonl —
# append-only log of (opp_id, ISO-week) pairs.
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
MCP_JSON="$TENANT_AGENT_HOME/.mcp.json"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/stalled-deal-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

# Tunable thresholds
MIN_VALUE_USD="${STALLED_MIN_VALUE_USD:-2000}"
STALE_DAYS="${STALLED_STALE_DAYS:-7}"

mkdir -p "$(dirname "$NUDGE_LOG")"
touch "$NUDGE_LOG"

[[ ! -f "$MCP_JSON" ]] && { echo "ERROR: $MCP_JSON missing — can't read GHL creds" >&2; exit 1; }
[[ ! -x "$TG_SEND" ]]  && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

GHL_API_KEY=$(jq -r '.mcpServers.ghl.env.GHL_API_KEY' "$MCP_JSON")
GHL_LOCATION_ID=$(jq -r '.mcpServers.ghl.env.GHL_LOCATION_ID' "$MCP_JSON")
GHL_BASE_URL=$(jq -r '.mcpServers.ghl.env.GHL_BASE_URL // "https://services.leadconnectorhq.com"' "$MCP_JSON")

[[ -z "$GHL_API_KEY" || "$GHL_API_KEY" == "null" ]] && { echo "ERROR: no GHL_API_KEY in $MCP_JSON" >&2; exit 1; }

now_epoch=$(date -u +%s)
iso_week=$(date -u +%G-W%V)
nudged_this_run=0

# Pull open opportunities. Limit to a reasonable page size; if the pipeline
# is huge, the watcher will only catch the first 100 — fine for most cases,
# and a follow-up implementation can paginate.
resp=$(curl -sS --max-time 20 -X GET \
  "$GHL_BASE_URL/opportunities/search?location_id=$GHL_LOCATION_ID&status=open&limit=100" \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -H "Accept: application/json")

if ! echo "$resp" | jq -e '.opportunities' >/dev/null 2>&1; then
  echo "ERROR: GHL response malformed: $(echo "$resp" | head -c 200)"
  exit 1
fi

opp_count=$(echo "$resp" | jq -r '.opportunities | length')
echo "stalled-deal-watcher: $opp_count open opps in pipeline"

# Extract fields. Field names per GHL API v2 (Version: 2021-07-28):
#   id, name, monetaryValue (or value), updatedAt (ISO 8601), assignedTo,
#   contact (object with name), status, pipelineStageId
# We tolerate missing fields gracefully (default to 0 / empty / now).
while IFS=$'\t' read -r opp_id name value updated_at contact_name; do
  [[ -z "$opp_id" ]] && continue

  # Coerce value to integer for comparison. Some opps have null value.
  value_int=$(printf '%d' "${value%%.*}" 2>/dev/null || echo 0)
  if [[ $value_int -lt $MIN_VALUE_USD ]]; then continue; fi

  # Days since last update
  upd_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo "$now_epoch")
  days_idle=$(( (now_epoch - upd_epoch) / 86400 ))
  if [[ $days_idle -lt $STALE_DAYS ]]; then continue; fi

  # Dedup per ISO week
  nudge_key="$opp_id:$iso_week"
  if grep -q "\"$nudge_key\"" "$NUDGE_LOG"; then continue; fi

  # Build the message
  who="${contact_name:-(no contact)}"
  msg=$(printf "💼 Stalled deal — %d days idle\n\n%s\nValue: \$%s\nContact: %s\n\nLast touched: %s\n\nTap or type: /research %s  ·  /draft email %s re-engagement" \
    "$days_idle" "$name" "$value_int" "$who" "$updated_at" "$opp_id" "$opp_id")

  if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
    printf '{"key":"%s","sent_at":"%s","opp_id":"%s","name":%s,"value":%d,"days_idle":%d,"week":"%s"}\n' \
      "$nudge_key" "$(date -u +%FT%TZ)" "$opp_id" "$(jq -nc --arg n "$name" '$n')" "$value_int" "$days_idle" "$iso_week" \
      >> "$NUDGE_LOG"
    nudged_this_run=$((nudged_this_run + 1))
  fi
done < <(echo "$resp" | jq -r '.opportunities[] | [.id, (.name // "(no name)"), (.monetaryValue // 0), (.updatedAt // ""), (.contact.name // "")] | @tsv')

echo "stalled-deal-watcher: $nudged_this_run nudges sent at $(date -u +%FT%TZ)"
