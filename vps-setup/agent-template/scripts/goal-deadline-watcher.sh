#!/usr/bin/env bash
# goal-deadline-watcher.sh — proactive Telegram nudge for goals approaching
# their target_date.
#
# Sibling to task-deadline-watcher.sh — same architecture, different state
# file. Goals live in goals/active.json with target_date (YYYY-MM-DD) and
# current_value vs target_value. Ping windows are wider than tasks because
# goals are longer-horizon objectives:
#   - 7 days out
#   - 1 day out
#   - on/past target_date (and not yet achieved)
#
# Goals ALSO get a "behind pace" nudge if current_value/target_value
# trails the time-elapsed ratio by more than 25 percentage points. This
# catches goals that are tracking poorly before the target_date hits.
#
# Dedup via {{TENANT_AGENT_HOME}}/notifications/goal-nudges.jsonl —
# append-only log of (goal_id, nudge_window) pairs.
#
# Idempotent — safe to re-run any time.
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
GOALS_PATH="$TENANT_AGENT_HOME/goals/active.json"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/goal-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$NUDGE_LOG")"
touch "$NUDGE_LOG"

[[ ! -f "$GOALS_PATH" ]] && { echo "no goals file at $GOALS_PATH"; exit 0; }
[[ ! -x "$TG_SEND" ]]   && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

now_epoch=$(date -u +%s)
nudged_this_run=0

# Walk active goals. For each non-achieved goal with target_date and
# numeric values, decide nudge window + behind-pace state.
while IFS=$'\t' read -r goal_id state summary target_date current_value target_value created_at; do
  [[ -z "$goal_id" ]] && continue
  [[ "$state" == "achieved" || "$state" == "abandoned" ]] && continue
  [[ -z "$target_date" || "$target_date" == "null" ]] && continue

  # Parse target_date → epoch (end-of-day in {{TENANT_TIMEZONE}} for fairness).
  # GNU date: pass timezone via TZ env var, not as part of -d string.
  td_epoch=$(TZ='{{TENANT_TIMEZONE}}' date -d "$target_date 23:59:59" +%s 2>/dev/null || echo "")
  [[ -z "$td_epoch" ]] && continue

  diff_sec=$((td_epoch - now_epoch))

  # Date-based windows
  window=""
  label=""
  emoji="🎯"
  if   [[ $diff_sec -le 0 && $diff_sec -gt -604800 ]]; then  window="overdue";  label="past target date"; emoji="🚨"
  elif [[ $diff_sec -le 86400 ]]; then                       window="1d";       label="target tomorrow"
  elif [[ $diff_sec -le 604800 ]]; then                      window="7d";       label="target in 7 days"
  fi

  # Behind-pace check: if we have created_at + numeric values, compare
  # progress vs time-elapsed. If trailing by >25pp, fire a "behind_pace"
  # nudge (but only once per week — append week-of-year to the dedup key).
  behind_pace=""
  if [[ -n "$created_at" && "$current_value" != "null" && "$target_value" != "null" ]]; then
    ca_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
    if [[ -n "$ca_epoch" && $td_epoch -gt $ca_epoch ]]; then
      total_dur=$((td_epoch - ca_epoch))
      elapsed=$((now_epoch - ca_epoch))
      if [[ $elapsed -gt 0 && $total_dur -gt 0 ]]; then
        time_pct=$((100 * elapsed / total_dur))
        # Use awk for float division on progress
        prog_pct=$(awk -v c="$current_value" -v t="$target_value" 'BEGIN{ if(t>0) printf "%d", (c/t)*100; else print 0 }')
        if [[ $prog_pct -lt $((time_pct - 25)) ]]; then
          week=$(date -u +%G-W%V)
          behind_pace="$week:behind:$time_pct-vs-$prog_pct"
        fi
      fi
    fi
  fi

  # Emit deadline-window nudge if any
  if [[ -n "$window" ]]; then
    nudge_key="$goal_id:$window"
    if ! grep -q "\"$nudge_key\"" "$NUDGE_LOG"; then
      msg=$(printf "%s Goal %s — %s\n\n%s\n\nProgress: %s / %s\nTap or type: /goals  ·  /goal_progress %s <new_value>" \
        "$emoji" "$label" "$goal_id" "$summary" "${current_value:-0}" "${target_value:-1}" "$goal_id")
      if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
        printf '{"key":"%s","sent_at":"%s","goal_id":"%s","window":"%s"}\n' \
          "$nudge_key" "$(date -u +%FT%TZ)" "$goal_id" "$window" >> "$NUDGE_LOG"
        nudged_this_run=$((nudged_this_run + 1))
      fi
    fi
  fi

  # Emit behind-pace nudge (separate dedup key, max 1/week)
  if [[ -n "$behind_pace" ]]; then
    nudge_key="$goal_id:$behind_pace"
    if ! grep -q "\"$nudge_key\"" "$NUDGE_LOG"; then
      msg=$(printf "📉 Goal behind pace — %s\n\n%s\n\nTime elapsed: %s%%\nProgress: %s%% (target %s)\n\nTap or type: /goal_progress %s <new_value>" \
        "$goal_id" "$summary" "$time_pct" "$prog_pct" "$target_value" "$goal_id")
      if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
        printf '{"key":"%s","sent_at":"%s","goal_id":"%s","window":"behind_pace"}\n' \
          "$nudge_key" "$(date -u +%FT%TZ)" "$goal_id" >> "$NUDGE_LOG"
        nudged_this_run=$((nudged_this_run + 1))
      fi
    fi
  fi
done < <(jq -r 'to_entries[] | .value | [.id, .state, .summary, (.target_date // ""), (.current_value // 0), (.target_value // 0), (.created_at // "")] | @tsv' "$GOALS_PATH")

echo "goal-deadline-watcher: $nudged_this_run nudges sent at $(date -u +%FT%TZ)"
