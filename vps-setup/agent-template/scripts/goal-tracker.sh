#!/usr/bin/env bash
# goal-tracker.sh — quarterly OKRs / strategic goals.
#
# Goals are different from tasks: a task is "do this thing once, mark done."
# A goal is "achieve this outcome by date, accumulate progress over weeks."
# Goals live longer, have target metrics, and pull tasks toward them.
#
# Lifecycle:
#   proposed  ✏️    committed  🎯   in_progress 🔧    at_risk ⚠️
#   achieved  ✅    missed     ❌   deferred    ⏭️    cancelled ✖️
#
# Subcommands:
#   create   --summary TEXT [--target-date YYYY-MM-DD] [--metric NAME]
#            [--target-value N] [--owner X]
#   state    --id GOAL_ID --state STATE [--msg "note"]
#   progress --id GOAL_ID --value N [--msg "note"]
#   link     --id GOAL_ID --task TASK_ID    or    --memory MEMORY_ID
#   list     [--state STATE]
#   render   Render active goals as MarkdownV2 (for /goals command)
#   rebuild  Re-materialize active.json from ledger.jsonl

set -euo pipefail

GOALS_DIR="${TENANT_AGENT_HOME:-/opt/{{TENANT_LINUX_USER}}/agents}/goals"
LEDGER="$GOALS_DIR/ledger.jsonl"
ACTIVE="$GOALS_DIR/active.json"
HELPERS="$(dirname "$0")/_goals_helpers.py"

mkdir -p "$GOALS_DIR"
touch "$LEDGER"
[[ -f "$ACTIVE" ]] || echo "{}" > "$ACTIVE"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
gen_id() { printf "g-%s-%s" "$(date +%Y%m%d)" "$(openssl rand -hex 2)"; }

cmd="${1:-help}"; shift || true
id="" summary="" target_date="" metric="" target_value="" owner="" state=""
msg="" value="" task_id="" memory_id="" link_kind=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)            id="$2"; shift 2 ;;
    --summary)       summary="$2"; shift 2 ;;
    --target-date)   target_date="$2"; shift 2 ;;
    --metric)        metric="$2"; shift 2 ;;
    --target-value)  target_value="$2"; shift 2 ;;
    --owner)         owner="$2"; shift 2 ;;
    --state)         state="$2"; shift 2 ;;
    --msg)           msg="$2"; shift 2 ;;
    --value)         value="$2"; shift 2 ;;
    --task)          task_id="$2"; link_kind="task"; shift 2 ;;
    --memory)        memory_id="$2"; link_kind="memory"; shift 2 ;;
    *)               shift ;;
  esac
done

export TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-/opt/{{TENANT_LINUX_USER}}/agents}"

ping_telegram() {
  local id="$1" state="$2" msg="$3"
  local g
  g=$(jq --arg id "$id" '.[$id] // empty' "$ACTIVE")
  [[ -z "$g" ]] && return 0
  local summary cur tgt
  summary=$(echo "$g" | jq -r '.summary // "(no summary)"')
  cur=$(echo "$g" | jq -r '.current_value // 0')
  tgt=$(echo "$g" | jq -r '.target_value // ""')
  local emoji label
  case "$state" in
    proposed)    emoji="✏️"; label="Proposed";;
    committed)   emoji="🎯"; label="Committed";;
    in_progress) emoji="🔧"; label="In progress";;
    at_risk)     emoji="⚠️"; label="At risk";;
    achieved)    emoji="✅"; label="Achieved";;
    missed)      emoji="❌"; label="Missed";;
    deferred)    emoji="⏭️"; label="Deferred";;
    cancelled)   emoji="✖️"; label="Cancelled";;
    *)           emoji="•"; label="$state";;
  esac
  local esc_summary esc_msg esc_id
  esc_summary=$(printf "%s" "$summary" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
  esc_msg=$(printf "%s" "$msg" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
  esc_id=$(printf "%s" "$id" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
  local body
  body=$(printf '%s *Goal — %s* — %s\n\n%s\n\n`%s`' "$emoji" "$label" "$esc_summary" "$esc_msg" "$esc_id")
  if [[ -n "$tgt" && "$tgt" != "null" ]]; then
    local pct=0
    if [[ "$tgt" != "0" ]]; then pct=$(awk "BEGIN{printf \"%d\", ($cur/$tgt)*100}"); fi
    body=$(printf '%s\n_%s/%s \\(%s%%\\)_' "$body" "$cur" "$tgt" "$pct")
  fi
  /opt/{{TENANT_LINUX_USER}}/agents/scripts/tg-send.sh send --md --text "$body" >/dev/null 2>&1 || true
}

case "$cmd" in
  create)
    [[ -z "$summary" ]] && { echo "missing --summary" >&2; exit 1; }
    new_id=$(gen_id)
    ev=$(jq -nc --arg ts "$(now)" --arg id "$new_id" --arg summary "$summary" \
                --arg target_date "$target_date" --arg metric "$metric" \
                --arg target_value "$target_value" --arg owner "$owner" \
                --arg state "${state:-committed}" \
        '{ts:$ts, id:$id, event:"create", summary:$summary,
          target_date:(if $target_date=="" then null else $target_date end),
          metric:(if $metric=="" then null else $metric end),
          target_value:(if $target_value=="" then null else ($target_value|tonumber) end),
          owner:(if $owner=="" then null else $owner end),
          state:$state, current_value:0}')
    echo "$ev" >> "$LEDGER"
    python3 "$HELPERS" rebuild >/dev/null
    ping_telegram "$new_id" "${state:-committed}" "${msg:-Tracking it.}"
    echo "$new_id"
    ;;
  state)
    [[ -z "$id" || -z "$state" ]] && { echo "missing --id or --state" >&2; exit 1; }
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" --arg state "$state" --arg msg "$msg" \
        '{ts:$ts, id:$id, event:"state", state:$state, msg:$msg}')
    echo "$ev" >> "$LEDGER"
    python3 "$HELPERS" rebuild >/dev/null
    ping_telegram "$id" "$state" "${msg:-state change}"
    echo "ok"
    ;;
  progress)
    [[ -z "$id" || -z "$value" ]] && { echo "missing --id or --value" >&2; exit 1; }
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" --argjson val "$value" --arg msg "$msg" \
        '{ts:$ts, id:$id, event:"progress", current_value:$val, msg:$msg}')
    echo "$ev" >> "$LEDGER"
    python3 "$HELPERS" rebuild >/dev/null
    # Read back the goal state to ping
    cur_state=$(jq -r --arg id "$id" '.[$id].state // "in_progress"' "$ACTIVE")
    ping_telegram "$id" "$cur_state" "Progress: $value${msg:+ — $msg}"
    echo "ok"
    ;;
  link)
    [[ -z "$id" ]] && { echo "missing --id" >&2; exit 1; }
    [[ -z "$link_kind" ]] && { echo "missing --task or --memory" >&2; exit 1; }
    link_id="$task_id$memory_id"
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" --arg kind "$link_kind" --arg link_id "$link_id" \
        '{ts:$ts, id:$id, event:"link", kind:$kind, link_id:$link_id}')
    echo "$ev" >> "$LEDGER"
    python3 "$HELPERS" rebuild >/dev/null
    echo "ok"
    ;;
  list)
    if [[ -n "$state" ]]; then
      jq --arg s "$state" 'to_entries | map(select(.value.state == $s)) | from_entries' "$ACTIVE"
    else
      cat "$ACTIVE"
    fi
    ;;
  render)
    python3 "$HELPERS" render
    ;;
  rebuild)
    python3 "$HELPERS" rebuild
    ;;
  help|*)
    cat <<EOF
goal-tracker.sh — quarterly OKRs

  create   --summary TEXT [--target-date YYYY-MM-DD] [--metric NAME] [--target-value N] [--owner X]
  state    --id GOAL_ID --state STATE [--msg "note"]
  progress --id GOAL_ID --value N [--msg "note"]
  link     --id GOAL_ID --task TASK_ID  OR  --memory MEMORY_ID
  list     [--state STATE]
  render   MarkdownV2 for /goals
  rebuild  Re-materialize active.json
EOF
    ;;
esac
