#!/usr/bin/env bash
# task-deadline-watcher.sh — proactive Telegram nudge for tasks coming due.
#
# Runs every hour via task-deadline-watcher.timer. For each active task with
# a deadline in the next 24h that we haven't nudged about yet, sends a
# Telegram heads-up with one-tap actions (Done / Snooze / Cancel — these
# reuse the existing draft: callback prefix patterns? No: tasks use a
# different prefix because draft: is for drafts. We just tell {{TENANT_PERSON_FIRST_NAME}} to type
# the existing /done /cancel /extend slash commands).
#
# Dedup via {{TENANT_AGENT_HOME}}/notifications/deadline-nudges.jsonl —
# append-only log of (task_id, nudge_window) pairs we've already sent.
# A task gets at most THREE nudges per deadline:
#   - 24h out
#   - 4h out
#   - on-deadline (within 30 min)
#
# Idempotent — safe to re-run any time.
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
TASKS_PATH="$TENANT_AGENT_HOME/tasks/active.json"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/deadline-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$NUDGE_LOG")"
touch "$NUDGE_LOG"

[[ ! -f "$TASKS_PATH" ]] && { echo "no tasks file at $TASKS_PATH"; exit 0; }
[[ ! -x "$TG_SEND" ]]    && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

now_epoch=$(date -u +%s)

# Walk active tasks. For each one with a non-empty deadline that's in the
# next 24h, decide which window it falls in (24h/4h/now), check the
# nudge log, and emit a notification if we haven't already.
nudged_this_run=0
while IFS=$'\t' read -r task_id state summary deadline; do
  [[ -z "$task_id" ]] && continue
  [[ "$state" == "done" || "$state" == "cancelled" ]] && continue
  [[ -z "$deadline" || "$deadline" == "null" ]] && continue

  # Parse deadline → epoch
  dl_epoch=$(date -d "$deadline" +%s 2>/dev/null || echo "")
  [[ -z "$dl_epoch" ]] && continue

  diff_sec=$((dl_epoch - now_epoch))

  # Pick the nudge window. Past-due gets nudged once at "due_now".
  if   [[ $diff_sec -le 1800  && $diff_sec -gt -3600 ]]; then  window="due_now";    label="due now"
  elif [[ $diff_sec -le 14400 && $diff_sec -gt 1800 ]]; then   window="4h";         label="due in ~4h"
  elif [[ $diff_sec -le 86400 && $diff_sec -gt 14400 ]]; then  window="24h";        label="due in ~24h"
  else continue
  fi

  # Already nudged this window for this task?
  nudge_key="$task_id:$window"
  if grep -q "\"$nudge_key\"" "$NUDGE_LOG"; then
    continue
  fi

  # Build the message — plain text only. MarkdownV2 escape rules are
  # painful on task IDs (dashes) and ISO dates, and the watcher fires
  # often enough that one bad escape silences a real deadline. Emojis
  # carry the visual weight; tap-to-execute uses slash commands which
  # Telegram renders as clickable buttons regardless of parse mode.
  emoji="⏰"
  [[ "$window" == "due_now" ]] && emoji="🚨"

  msg=$(printf "%s Task %s — %s\n\n%s\n\nTap or type: /done %s  ·  /cancel %s  ·  /extend %s YYYY-MM-DD" \
    "$emoji" "$label" "$task_id" "$summary" "$task_id" "$task_id" "$task_id")

  if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
    printf '{"key":"%s","sent_at":"%s","task_id":"%s","window":"%s"}\n' \
      "$nudge_key" "$(date -u +%FT%TZ)" "$task_id" "$window" >> "$NUDGE_LOG"
    nudged_this_run=$((nudged_this_run + 1))
  fi
done < <(jq -r 'to_entries[] | .value | [.id, .state, .summary, (.deadline // "")] | @tsv' "$TASKS_PATH")

echo "task-deadline-watcher: $nudged_this_run nudges sent at $(date -u +%FT%TZ)"
