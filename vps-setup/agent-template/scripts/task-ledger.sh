#!/usr/bin/env bash
# task-ledger.sh — single source of truth for what the agent is tracking.
# Append-only event log + materialized active state.
set -euo pipefail

TASKS_DIR="{{TENANT_AGENT_HOME}}/tasks"
LEDGER="$TASKS_DIR/ledger.jsonl"
ACTIVE="$TASKS_DIR/active.json"
ARCHIVE="$TASKS_DIR/archive.json"

mkdir -p "$TASKS_DIR"
touch "$LEDGER"
[[ -f "$ACTIVE" ]] || echo "{}" > "$ACTIVE"
[[ -f "$ARCHIVE" ]] || echo "{}" > "$ARCHIVE"

usage() {
  cat <<EOF
task-ledger.sh — task event log + queries

Subcommands:
  create   --summary TEXT [--owner ID] [--deadline ISO_DATE] [--loud true|false] [--source TEXT]
             Returns: the new task ID (e.g. t-20260430-a1b2)
  state    --id TASK_ID --state STATE [--msg "progress note"]
             States: proposed | committed | in_progress | awaiting_review | awaiting_external | blocked | done | cancelled | stale
  comment  --id TASK_ID --msg "free-form note"  (no state change)
  list     [--state STATE | --all]   Render JSON of matching tasks
  get      --id TASK_ID              Show one task with full event history
  rebuild                            Re-materialize active.json from ledger
  archive                            Move done/cancelled tasks older than 7 days to archive

Auto-side-effects on state change:
  Tasks with loud:true ping Telegram via tg-send.sh on every state transition.
EOF
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
gen_id() { printf "t-%s-%s" "$(date +%Y%m%d)" "$(openssl rand -hex 2)"; }

# Append a JSON event to the ledger and re-materialize active.json
append_event() {
  local event_json="$1"
  echo "$event_json" >> "$LEDGER"
  rebuild_active
}

# Re-materialize active.json from the ledger
rebuild_active() {
  python3 - <<PY
import json, os, sys
ledger_path = "$LEDGER"
active_path = "$ACTIVE"

active = {}
if os.path.exists(ledger_path):
  with open(ledger_path) as f:
    for line in f:
      line = line.strip()
      if not line: continue
      try:
        ev = json.loads(line)
      except json.JSONDecodeError:
        continue
      tid = ev.get("id")
      if not tid: continue
      task = active.setdefault(tid, {
        "id": tid, "summary": "", "owner": None, "deadline": None,
        "loud": True, "source": None, "state": "proposed",
        "created_at": ev.get("ts"), "updated_at": ev.get("ts"),
        "events": [],
      })
      task["events"].append(ev)
      task["updated_at"] = ev.get("ts", task["updated_at"])
      e = ev.get("event")
      if e == "create":
        for k in ("summary", "owner", "deadline", "loud", "source"):
          if k in ev: task[k] = ev[k]
        task["state"] = ev.get("state", "proposed")
      elif e == "state":
        task["state"] = ev.get("state", task["state"])
      elif e == "comment":
        pass

# move done/cancelled tasks > 7 days out to archive_buffer (we'll keep them in active for now;
# the explicit "archive" subcommand handles the move)
out_active = {tid: t for tid, t in active.items() if t["state"] not in ("done", "cancelled") or
              (t["state"] in ("done", "cancelled") and (
                __import__("datetime").datetime.utcnow() - __import__("datetime").datetime.fromisoformat(t["updated_at"].replace("Z",""))).days < 7)}

with open(active_path, "w") as f:
  json.dump(out_active, f, indent=2, sort_keys=True)
PY
}

# Send an auto-ping to Telegram on a state change for loud tasks
maybe_ping() {
  local id="$1" state="$2" msg="$3"
  local task_json
  task_json=$(jq --arg id "$id" '.[$id] // empty' "$ACTIVE")
  [[ -z "$task_json" ]] && return 0
  local loud
  loud=$(echo "$task_json" | jq -r '.loud // true')
  [[ "$loud" != "true" ]] && return 0

  local summary owner deadline
  summary=$(echo "$task_json" | jq -r '.summary // "(no summary)"')
  owner=$(echo "$task_json"   | jq -r '.owner // ""')
  deadline=$(echo "$task_json" | jq -r '.deadline // ""')

  local emoji label
  case "$state" in
    proposed)          emoji="\xe2\x9c\x8f\xef\xb8\x8f"; label="Proposed";;
    committed)         emoji="\xf0\x9f\x93\x8c"; label="Committed";;
    in_progress)       emoji="\xf0\x9f\x94\xa7"; label="Working on it";;
    awaiting_review)   emoji="\xf0\x9f\x91\x80"; label="Awaiting review";;
    awaiting_external) emoji="\xe2\x8f\xb3"; label="Waiting on you";;
    blocked)           emoji="\xf0\x9f\x9a\xa7"; label="Blocked";;
    done)              emoji="\xe2\x9c\x85"; label="Done";;
    cancelled)         emoji="\xe2\x9c\x96\xef\xb8\x8f"; label="Cancelled";;
    stale)             emoji="\xf0\x9f\x95\x90"; label="Stale";;
    *)                 emoji="\xe2\x80\xa2"; label="$state";;
  esac

  # Compose markdown — escape user-supplied text for MarkdownV2
  local esc_summary esc_msg esc_id deadline_part owner_part msg_part
  esc_summary=$(printf "%s" "$summary" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
  esc_msg=$(printf "%s" "$msg" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
  esc_id=$(printf "%s" "$id" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')

  local body
  body=$(printf '%b *%s* \xe2\x80\x94 %s\n\n%s\n\n`%s`' "$emoji" "$label" "$esc_summary" "$esc_msg" "$esc_id")

  if [[ -n "$deadline" && "$deadline" != "null" ]]; then
    deadline_esc=$(printf "%s" "$deadline" | sed 's/[][_*()~`>#+=|{}.!\\\-]/\\&/g')
    body=$(printf '%s\n_due %s_' "$body" "$deadline_esc")
  fi

  {{TENANT_AGENT_HOME}}/scripts/tg-send.sh send --md --text "$body" >/dev/null 2>&1 || true
}

cmd="${1:-help}"; shift || true

# parse common flags
id="" summary="" owner="" deadline="" loud="true" source="" state=""
msg="" all=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)        id="$2"; shift 2 ;;
    --summary)   summary="$2"; shift 2 ;;
    --owner)     owner="$2"; shift 2 ;;
    --deadline)  deadline="$2"; shift 2 ;;
    --loud)      loud="$2"; shift 2 ;;
    --source)    source="$2"; shift 2 ;;
    --state)     state="$2"; shift 2 ;;
    --msg)       msg="$2"; shift 2 ;;
    --all)       all="1"; shift ;;
    *)           shift ;;
  esac
done

case "$cmd" in
  create)
    [[ -z "$summary" ]] && { echo "missing --summary" >&2; exit 1; }
    new_id=$(gen_id)
    ev=$(jq -nc --arg ts "$(now)" --arg id "$new_id" --arg summary "$summary" \
        --arg owner "$owner" --arg deadline "$deadline" --argjson loud "$loud" \
        --arg source "$source" --arg state "${state:-committed}" \
        '{ts:$ts, id:$id, event:"create", summary:$summary, owner:$owner,
          deadline:$deadline, loud:$loud, source:$source, state:$state}')
    append_event "$ev"
    maybe_ping "$new_id" "${state:-committed}" "${msg:-Tracking it.}"
    echo "$new_id"
    ;;
  state)
    [[ -z "$id" || -z "$state" ]] && { echo "missing --id or --state" >&2; exit 1; }
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" --arg state "$state" --arg msg "$msg" \
        '{ts:$ts, id:$id, event:"state", state:$state, msg:$msg}')
    append_event "$ev"
    maybe_ping "$id" "$state" "${msg:-state change}"
    echo "ok"
    ;;
  comment)
    [[ -z "$id" || -z "$msg" ]] && { echo "missing --id or --msg" >&2; exit 1; }
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" --arg msg "$msg" \
        '{ts:$ts, id:$id, event:"comment", msg:$msg}')
    append_event "$ev"
    echo "ok"
    ;;
  list)
    if [[ -n "$all" ]]; then
      cat "$ACTIVE"
    elif [[ -n "$state" ]]; then
      jq --arg s "$state" 'to_entries | map(select(.value.state == $s)) | from_entries' "$ACTIVE"
    else
      # default: not done, not cancelled
      jq 'to_entries | map(select(.value.state != "done" and .value.state != "cancelled")) | from_entries' "$ACTIVE"
    fi
    ;;
  get)
    [[ -z "$id" ]] && { echo "missing --id" >&2; exit 1; }
    jq --arg id "$id" '.[$id] // {error:"not found"}' "$ACTIVE"
    ;;
  rebuild)
    rebuild_active
    echo "ok"
    ;;
  archive)
    # Move done/cancelled tasks older than 7 days from active to archive
    python3 - <<PY
import json, datetime
with open("$ACTIVE") as f: active = json.load(f)
with open("$ARCHIVE") as f: archive = json.load(f)
now = datetime.datetime.utcnow()
moved = 0
keep = {}
for tid, t in active.items():
  if t["state"] in ("done", "cancelled"):
    upd = datetime.datetime.fromisoformat(t["updated_at"].replace("Z",""))
    if (now - upd).days >= 7:
      archive[tid] = t
      moved += 1
      continue
  keep[tid] = t
with open("$ACTIVE","w") as f: json.dump(keep, f, indent=2, sort_keys=True)
with open("$ARCHIVE","w") as f: json.dump(archive, f, indent=2, sort_keys=True)
print(f"archived {moved} tasks")
PY
    ;;
  help|*) usage ;;
esac
