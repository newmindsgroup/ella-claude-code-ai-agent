#!/usr/bin/env bash
# hot-lead-inbox-watcher.sh — proactive Telegram nudge when a known prospect
# emails {{TENANT_PERSON_FIRST_NAME}} between morning briefs.
#
# Architecture (refactored 2026-05-04):
#   - LLM does ONE thing: fetch Gmail threads from the last N hours and
#     return them as JSON. Single tool call, ~$0.01 per run.
#   - This script (bash) does ALL GHL cross-referencing via direct REST
#     API calls. Deterministic, fast, no LLM second-guessing.
#   - Telegram dedup + nudge formatting also in bash.
#
# Why split: LLMs short-circuit multi-step prompts ("0 threads, so I'll
# skip GHL too") and rationalize unavailable tools when results are
# sparse. Splitting the work means the LLM has zero room to bail on
# step N+1 if step N returned 0 results — the bash side just no-ops.
#
# Schedule: 4×/day at 12, 16, 20, 00 tenant TZ. The 09:00 morning
# brief covers the overnight window itself, so the first watcher run at
# 12:00 picks up any movement since.
#
# Dedup: notifications/hot-lead-nudges.jsonl using (sender_email,
# ISO date).
#
# Tunables (env vars):
#   WINDOW_HOURS         — Gmail lookback window (default 4)
#   HOT_LEAD_TIMEOUT_SEC — claude --print timeout (default 240)
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/hot-lead-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"
LOG_DIR="$TENANT_AGENT_HOME/logs"
MCP_JSON="$TENANT_AGENT_HOME/.mcp.json"

WINDOW_HOURS="${WINDOW_HOURS:-4}"
HOT_LEAD_TIMEOUT_SEC="${HOT_LEAD_TIMEOUT_SEC:-240}"

mkdir -p "$(dirname "$NUDGE_LOG")" "$LOG_DIR"
touch "$NUDGE_LOG"

[[ ! -x "$TG_SEND" ]] && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }
[[ ! -f "$MCP_JSON" ]] && { echo "ERROR: $MCP_JSON missing" >&2; exit 1; }

GHL_API_KEY=$(jq -r '.mcpServers.ghl.env.GHL_API_KEY' "$MCP_JSON")
GHL_LOCATION_ID=$(jq -r '.mcpServers.ghl.env.GHL_LOCATION_ID' "$MCP_JSON")
GHL_BASE_URL=$(jq -r '.mcpServers.ghl.env.GHL_BASE_URL // "https://services.leadconnectorhq.com"' "$MCP_JSON")

today=$(date -u +%Y-%m-%d)
log_file="$LOG_DIR/hot-lead-inbox-$(date -u +%Y-%m-%d).log"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$log_file" >&2; }

log "=== hot-lead-inbox-watcher started (window=${WINDOW_HOURS}h) ==="

# ── STEP 1: LLM-driven Gmail fetch (single, focused tool call) ──────────────
# The agent stack accesses Gmail via Claude.ai's hosted connector; there's
# no local OAuth token. Until/unless that's set up, the cheapest route is
# one focused claude --print call that returns thread metadata as JSON.
#
# IMPORTANT: --permission-mode bypassPermissions, NOT dontAsk. The dontAsk
# mode silently blocks Claude.ai-hosted MCPs (Gmail, Calendar, Drive, etc.)
# and the LLM reports "tool denied" instead of attempting the call.
# bypassPermissions allows them through. Safe here because: (a) prompt is
# hardcoded, no user injection, (b) script runs as danielgonell (not root),
# (c) settings.json deny list still blocks sudo/rm/systemctl/etc.

PROMPT=$(cat <<EOF
Use mcp__claude_ai_Gmail__search_threads with q="newer_than:${WINDOW_HOURS}h" to retrieve recent threads. For each thread, also call mcp__claude_ai_Gmail__get_thread to get the sender email + first 200 chars of body.

Return ONLY a JSON object — no markdown, no preamble:

{
  "threads": [
    {"sender_email": "...", "sender_name": "...", "subject": "...", "preview": "...", "thread_id": "..."}
  ]
}

If 0 threads found, return {"threads": []}. NEVER skip the search_threads call. The Gmail tools ARE available — use them.
EOF
)

log "step 1: claude --print → fetch Gmail threads"
raw=$(timeout "$HOT_LEAD_TIMEOUT_SEC" claude --permission-mode bypassPermissions --print "$PROMPT" 2>>"$log_file" || echo "")

if [[ -z "$raw" ]]; then
  log "claude --print empty (timeout or error)"
  exit 0
fi

# Extract JSON object — accept fenced or bare
json=$(echo "$raw" | sed -n '/^{/,/^}$/p' | head -200)
[[ -z "$json" ]] && json="$raw"

if ! echo "$json" | jq -e .threads >/dev/null 2>&1; then
  log "claude returned invalid JSON — first 300 chars: $(echo "$raw" | head -c 300)"
  exit 0
fi

n_threads=$(echo "$json" | jq -r '.threads | length')
log "step 1: $n_threads threads returned"
[[ "$n_threads" == "0" ]] && exit 0

# ── STEP 2: Cross-reference each sender against GHL contacts (direct REST) ──
log "step 2: cross-referencing $n_threads senders against GHL"

nudged_this_run=0

# Loop in main shell (no subshell) so nudged_this_run sticks.
while IFS= read -r thread; do
  sender_email=$(echo "$thread" | jq -r '.sender_email // ""')
  sender_name=$(echo  "$thread" | jq -r '.sender_name // ""')
  subject=$(echo      "$thread" | jq -r '.subject // ""')
  preview=$(echo      "$thread" | jq -r '.preview // ""')
  thread_id=$(echo    "$thread" | jq -r '.thread_id // ""')

  [[ -z "$sender_email" || "$sender_email" == "null" ]] && continue

  # Skip if already nudged today
  nudge_key="$sender_email:$today"
  if grep -q "\"$nudge_key\"" "$NUDGE_LOG"; then
    log "  $sender_email — already nudged today"
    continue
  fi

  # GHL contact search by email (direct REST). v2 endpoint is /contacts/
  # with email query param. /contacts/search is POST in some accounts; we
  # use GET /contacts/?locationId=X&query=email which works with PIT tokens.
  ghl_resp=$(curl -sS --max-time 10 -X GET \
    "$GHL_BASE_URL/contacts/?locationId=$GHL_LOCATION_ID&query=$(printf %s "$sender_email" | jq -sRr @uri)&limit=5" \
    -H "Authorization: Bearer $GHL_API_KEY" \
    -H "Version: 2021-07-28" \
    -H "Accept: application/json" 2>>"$log_file" || echo '{}')

  ghl_match_name=$(echo "$ghl_resp" | jq -r '.contacts[0].contactName // .contacts[0].firstName // ""' 2>/dev/null)
  ghl_match_id=$(echo   "$ghl_resp" | jq -r '.contacts[0].id // ""' 2>/dev/null)

  if [[ -z "$ghl_match_id" || "$ghl_match_id" == "null" ]]; then
    log "  $sender_email — no GHL contact match (cold lead, skip)"
    continue
  fi

  log "  $sender_email — GHL match: $ghl_match_name ($ghl_match_id) — HOT LEAD"

  # Build the nudge message
  whoami_line="From: $sender_email"
  [[ -n "$sender_name" && "$sender_name" != "null" ]] && whoami_line="From: $sender_name <$sender_email>"

  msg=$(printf "🔥 Hot lead in inbox\n\n%s\nSubject: %s\n\n%s\n\nMatch: %s (GHL contact %s)\n\nTap or type: /research %s  ·  /draft email reply" \
    "$whoami_line" "$subject" "${preview:0:200}" "$ghl_match_name" "$ghl_match_id" "$sender_email")

  # Send with email triage callback buttons if thread_id present
  send_ok=0
  if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
    if "$TG_SEND" send --text "$msg" \
        --callback-buttons "📎 Reply|email:reply:$thread_id,🗃 Archive|email:archive:$thread_id,⏰ Snooze|email:snooze:$thread_id" \
        >/dev/null 2>>"$log_file"; then send_ok=1; fi
  else
    if "$TG_SEND" send --text "$msg" >/dev/null 2>>"$log_file"; then send_ok=1; fi
  fi

  if [[ $send_ok -eq 1 ]]; then
    printf '{"key":"%s","sent_at":"%s","sender":"%s","subject":%s,"ghl_contact_id":"%s","ghl_contact_name":%s,"thread_id":"%s"}\n' \
      "$nudge_key" "$(date -u +%FT%TZ)" "$sender_email" \
      "$(jq -nc --arg s "$subject" '$s')" \
      "$ghl_match_id" \
      "$(jq -nc --arg n "$ghl_match_name" '$n')" \
      "${thread_id:-}" \
      >> "$NUDGE_LOG"
    nudged_this_run=$((nudged_this_run + 1))
  fi
done < <(echo "$json" | jq -c '.threads[]')

log "=== done — $nudged_this_run hot-lead nudges sent ==="
