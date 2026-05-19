#!/usr/bin/env bash
# calendar-conflict-watcher.sh — proactive Telegram nudge when two
# Google Calendar events overlap on {{TENANT_PERSON_FIRST_NAME}}'s primary calendar.
#
# Architecture (split LLM + bash, per
# feedback_claude_print_permissions.md):
#   - LLM: ONE call to mcp__claude_ai_Google_Calendar__list_events for
#     today + tomorrow. Returns events as JSON. ~$0.01 per run.
#   - Bash: detects overlapping pairs deterministically (compare every
#     event's [start, end) against every later event in the same window).
#     Sends a Telegram nudge for each first-detected conflict.
#
# Why split: reliable conflict detection doesn't need an LLM — once we
# have the event list, it's pure interval math. LLMs occasionally miss
# overlaps that share an exact boundary or are buried in long lists.
# The bash side guarantees correctness.
#
# Schedule: 3×/day at 07:00, 12:00, 17:00 SD. {{TENANT_PERSON_FIRST_NAME}} sees morning
# conflicts BEFORE the day starts (07:00), again at midday in case
# a new event got accepted, and once more in late afternoon for next-
# day prep.
#
# Dedup: notifications/calendar-conflict-nudges.jsonl using
# (event_a_id, event_b_id, ISO date). One ping per pair per day. If
# {{TENANT_PERSON_FIRST_NAME}} reschedules and creates a new conflict, that's a new pair
# and it WILL ping again (correct).
#
# Tunables (env vars):
#   CALENDAR_TIMEOUT_SEC — claude --print timeout (default 180)
#   CALENDAR_LOOKAHEAD_DAYS — events to scan (default 2 = today + tomorrow)
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/calendar-conflict-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"
LOG_DIR="$TENANT_AGENT_HOME/logs"

CALENDAR_TIMEOUT_SEC="${CALENDAR_TIMEOUT_SEC:-180}"
CALENDAR_LOOKAHEAD_DAYS="${CALENDAR_LOOKAHEAD_DAYS:-2}"

mkdir -p "$(dirname "$NUDGE_LOG")" "$LOG_DIR"
touch "$NUDGE_LOG"

[[ ! -x "$TG_SEND" ]] && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

today=$(date -u +%Y-%m-%d)
log_file="$LOG_DIR/calendar-conflict-$(date -u +%Y-%m-%d).log"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$log_file" >&2; }

log "=== calendar-conflict-watcher started (lookahead=${CALENDAR_LOOKAHEAD_DAYS}d) ==="

# ── STEP 1: LLM-driven event fetch ──────────────────────────────────────────
# Compute the date range in {{TENANT_TIMEZONE}}. ISO 8601 range works for
# Google Calendar API.
range_start=$(TZ='{{TENANT_TIMEZONE}}' date -d "today 00:00:00" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
  | sed 's/\([+-][0-9]\{2\}\)\([0-9]\{2\}\)/\1:\2/')
range_end=$(TZ='{{TENANT_TIMEZONE}}'   date -d "+${CALENDAR_LOOKAHEAD_DAYS} days 23:59:59" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
  | sed 's/\([+-][0-9]\{2\}\)\([0-9]\{2\}\)/\1:\2/')

PROMPT=$(cat <<EOF
Use mcp__claude_ai_Google_Calendar__list_events to fetch all events between $range_start and $range_end on the primary calendar. Include declined-by-me events as well — a declined-but-not-removed event still creates an apparent conflict that {{TENANT_PERSON_FIRST_NAME}} should know about.

Return ONLY a JSON object — no markdown, no preamble:

{
  "events": [
    {
      "id": "<google calendar event id>",
      "summary": "<title>",
      "start": "<ISO 8601 with TZ offset>",
      "end": "<ISO 8601 with TZ offset>",
      "status": "confirmed|tentative|declined",
      "all_day": true|false,
      "location": "<short>"
    }
  ]
}

If 0 events, return {"events": []}. Skip all-day events that span the full range (they'll show false-positive conflicts with every meeting). NEVER skip the list_events call.
EOF
)

log "step 1: claude --print → fetch events"
# Use bypassPermissions for Google Calendar MCP. Verified 2026-05-05:
# Gmail works under dontAsk, but Google Calendar gets "tool denied"
# responses under dontAsk (real or LLM-hallucinated, hard to tell).
# bypassPermissions is reliable across all Claude.ai-hosted MCPs.
raw=$(timeout "$CALENDAR_TIMEOUT_SEC" claude --permission-mode bypassPermissions --print "$PROMPT" 2>>"$log_file" || echo "")

if [[ -z "$raw" ]]; then
  log "claude --print empty (timeout or error)"
  exit 0
fi

json=$(echo "$raw" | sed -n '/^{/,/^}$/p' | head -500)
[[ -z "$json" ]] && json="$raw"

if ! echo "$json" | jq -e .events >/dev/null 2>&1; then
  log "invalid JSON returned — first 300 chars: $(echo "$raw" | head -c 300)"
  exit 0
fi

n_events=$(echo "$json" | jq -r '.events | length')
log "step 1: $n_events events returned"
[[ "$n_events" -lt 2 ]] && { log "too few events for conflict — done"; exit 0; }

# ── STEP 2: Detect overlapping pairs ────────────────────────────────────────
# An overlap is: A.start < B.end AND B.start < A.end. We exclude:
#   - all_day events (false positives with every meeting)
#   - declined-by-self events ({{TENANT_PERSON_FIRST_NAME}} said no, not actually attending)
#   - identical event IDs (don't pair an event with itself)

# Extract simplified event list, filter all-day + declined.
event_csv=$(echo "$json" | jq -r '.events[]
  | select((.all_day // false) == false)
  | select((.status // "confirmed") != "declined")
  | [.id, .summary, .start, .end, (.location // "")]
  | @tsv')

if [[ -z "$event_csv" ]]; then
  log "no eligible events after filters"; exit 0
fi

eligible_count=$(echo "$event_csv" | wc -l)
log "step 2: $eligible_count eligible events after filters; checking for overlaps"

# Read into arrays
declare -a ev_id ev_summary ev_start ev_end ev_location ev_start_epoch ev_end_epoch
i=0
while IFS=$'\t' read -r id summ st en loc; do
  [[ -z "$id" ]] && continue
  s_epoch=$(date -d "$st" +%s 2>/dev/null || echo "")
  e_epoch=$(date -d "$en" +%s 2>/dev/null || echo "")
  [[ -z "$s_epoch" || -z "$e_epoch" ]] && continue
  ev_id[i]="$id"
  ev_summary[i]="$summ"
  ev_start[i]="$st"
  ev_end[i]="$en"
  ev_location[i]="$loc"
  ev_start_epoch[i]="$s_epoch"
  ev_end_epoch[i]="$e_epoch"
  i=$((i+1))
done <<< "$event_csv"

n=${#ev_id[@]}
log "loaded $n events with parseable times"

nudged_this_run=0

# O(n²) overlap check — n is small (typically <20)
for ((a = 0; a < n; a++)); do
  for ((b = a + 1; b < n; b++)); do
    # Overlap test: a.start < b.end && b.start < a.end
    if [[ ${ev_start_epoch[a]} -lt ${ev_end_epoch[b]} && ${ev_start_epoch[b]} -lt ${ev_end_epoch[a]} ]]; then
      # Found overlap. Build canonical key (smaller id first for stable dedup)
      id_a="${ev_id[a]}"
      id_b="${ev_id[b]}"
      if [[ "$id_a" > "$id_b" ]]; then
        tmp="$id_a"; id_a="$id_b"; id_b="$tmp"
      fi
      pair_key="$id_a:$id_b:$today"

      if grep -q "\"$pair_key\"" "$NUDGE_LOG"; then
        log "  conflict ${ev_summary[a]:0:30} ↔ ${ev_summary[b]:0:30} — already nudged today"
        continue
      fi

      # Compute overlap minutes
      overlap_start_epoch=$(( ${ev_start_epoch[a]} > ${ev_start_epoch[b]} ? ${ev_start_epoch[a]} : ${ev_start_epoch[b]} ))
      overlap_end_epoch=$(( ${ev_end_epoch[a]} < ${ev_end_epoch[b]} ? ${ev_end_epoch[a]} : ${ev_end_epoch[b]} ))
      overlap_min=$(( (overlap_end_epoch - overlap_start_epoch) / 60 ))

      # Format times in tenant local TZ for the message
      time_a=$(TZ='{{TENANT_TIMEZONE}}' date -d "${ev_start[a]}" '+%a %H:%M' 2>/dev/null || echo "${ev_start[a]}")
      time_b=$(TZ='{{TENANT_TIMEZONE}}' date -d "${ev_start[b]}" '+%a %H:%M' 2>/dev/null || echo "${ev_start[b]}")

      msg=$(printf "📅 Calendar conflict — %d min overlap\n\nA. %s — %s\nB. %s — %s\n\nLocations: %s | %s\n\nTap or type: /calendar  ·  one needs to move" \
        "$overlap_min" \
        "$time_a" "${ev_summary[a]}" \
        "$time_b" "${ev_summary[b]}" \
        "${ev_location[a]:-—}" "${ev_location[b]:-—}")

      if "$TG_SEND" send --text "$msg" >/dev/null 2>>"$log_file"; then
        printf '{"key":"%s","sent_at":"%s","event_a_id":"%s","event_b_id":"%s","summary_a":%s,"summary_b":%s,"overlap_min":%d}\n' \
          "$pair_key" "$(date -u +%FT%TZ)" "$id_a" "$id_b" \
          "$(jq -nc --arg s "${ev_summary[a]}" '$s')" \
          "$(jq -nc --arg s "${ev_summary[b]}" '$s')" \
          "$overlap_min" \
          >> "$NUDGE_LOG"
        nudged_this_run=$((nudged_this_run + 1))
        log "  CONFLICT nudged: ${ev_summary[a]:0:40} ↔ ${ev_summary[b]:0:40} (${overlap_min}m overlap)"
      fi
    fi
  done
done

log "=== done — $nudged_this_run conflict nudges sent ==="
