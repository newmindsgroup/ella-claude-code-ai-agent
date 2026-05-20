#!/usr/bin/env bash
# spend-guard.sh — daily LLM spend ceiling + auto-throttle.
#
# Reads today's api_cost_usd from telemetry.json, compares to the daily
# ceiling, and:
#   - at >=80%: warns Daniel (once/day)
#   - at >=100%: turns ON frugal mode (a flag file) + alerts (once/day).
#     In frugal mode, LLM-using watchers skip their claude --print calls,
#     the self-growth loop defers, and dispatch-job refuses new --prompt
#     (LLM) jobs. Deterministic watchers + the conversational agent keep
#     working — Daniel is never cut off, the bleeding just stops.
#   - when today's cost drops back under the ceiling (new day → telemetry
#     resets): frugal mode auto-clears + Daniel is told budget is fresh.
#
# Runs every 30 min via timer. Idempotent. State in state/spend-guard.json.
#
# This is the Charter's "spend discipline" made enforceable: the more
# autonomous the agent gets, the more this keeps it economical.
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp

TELEMETRY="${SPEND_TELEMETRY_PATH:-/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/telemetry.json}"
CEILING="${DAILY_SPEND_CEILING_USD:-{{TENANT_DAILY_SPEND_CEILING_USD}}}"
STATE_DIR="$AGENT_HOME/state"
STATE="$STATE_DIR/spend-guard.json"
FRUGAL_FLAG="$STATE_DIR/frugal-mode"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"
LOG="$AGENT_HOME/logs/spend-guard-$(date -u +%Y-%m-%d).log"

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG" >&2; }

# Default ceiling if the placeholder didn't render to a number
[[ "$CEILING" =~ ^[0-9.]+$ ]] || CEILING=20

today=$(date -u +%Y-%m-%d)

[[ ! -f "$TELEMETRY" ]] && { log "no telemetry at $TELEMETRY — skipping"; exit 0; }

cost=$(jq -r '.rollup.today.api_cost_usd // 0' "$TELEMETRY" 2>/dev/null || echo 0)
[[ "$cost" =~ ^[0-9.]+$ ]] || cost=0

# pct = cost / ceiling * 100 (integer)
pct=$(awk -v c="$cost" -v cap="$CEILING" 'BEGIN{ if(cap>0) printf "%d", (c/cap)*100; else print 0 }')
log "today cost=\$$cost ceiling=\$$CEILING (${pct}%)"

# Load prior state (reset if it's a new day)
prev_date=""; alerted80=0; alerted100=0
if [[ -f "$STATE" ]]; then
  prev_date=$(jq -r '.date // ""' "$STATE" 2>/dev/null)
  if [[ "$prev_date" == "$today" ]]; then
    alerted80=$(jq -r '.alerted80 // 0' "$STATE" 2>/dev/null)
    alerted100=$(jq -r '.alerted100 // 0' "$STATE" 2>/dev/null)
  fi
fi

save_state() {
  jq -nc --arg d "$today" --argjson a80 "$alerted80" --argjson a100 "$alerted100" \
    --arg cost "$cost" --arg pct "$pct" \
    '{date:$d, alerted80:$a80, alerted100:$a100, last_cost:($cost|tonumber), last_pct:($pct|tonumber), updated_at:now|todateiso8601}' \
    > "$STATE"
}

# ── Over ceiling → frugal mode ON ──────────────────────────────────────────
if [[ "$pct" -ge 100 ]]; then
  if [[ ! -f "$FRUGAL_FLAG" ]]; then
    echo "$today" > "$FRUGAL_FLAG"
    log "FRUGAL MODE ON — ceiling breached"
  fi
  if [[ "$alerted100" -eq 0 ]]; then
    "$TG_SEND" send --text "🛑 Daily LLM budget hit: \$$cost / \$$CEILING (${pct}%). Frugal mode ON — LLM watchers paused, self-growth deferred, new LLM background jobs blocked. I stay available to chat. Resets at midnight." >/dev/null 2>&1 || true
    alerted100=1
  fi
  save_state
  exit 0
fi

# ── Under ceiling → ensure frugal mode OFF ─────────────────────────────────
if [[ -f "$FRUGAL_FLAG" ]]; then
  rm -f "$FRUGAL_FLAG"
  log "frugal mode CLEARED — back under ceiling"
  "$TG_SEND" send --text "✅ LLM budget refreshed: \$$cost / \$$CEILING (${pct}%). Frugal mode OFF — full autonomy restored." >/dev/null 2>&1 || true
  # reset daily alert flags since we're in a fresh window
  alerted80=0; alerted100=0
fi

# ── 80% warning (once/day) ─────────────────────────────────────────────────
if [[ "$pct" -ge 80 && "$alerted80" -eq 0 ]]; then
  "$TG_SEND" send --text "⚠️ 80% of daily LLM budget used: \$$cost / \$$CEILING. Frugal mode triggers at 100%." >/dev/null 2>&1 || true
  alerted80=1
fi

save_state
log "done"
