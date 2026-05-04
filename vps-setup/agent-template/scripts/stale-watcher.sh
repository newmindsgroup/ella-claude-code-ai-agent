#!/usr/bin/env bash
# stale-watcher.sh — flag in_progress tasks that haven't moved in 48h. Fires hourly during business hours.
set -euo pipefail
ACTIVE="{{TENANT_AGENT_HOME}}/tasks/active.json"
TG="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"
LEDGER="{{TENANT_AGENT_HOME}}/scripts/task-ledger.sh"

[[ ! -f "$ACTIVE" ]] && exit 0

# Find tasks in_progress with updated_at older than 48h
python3 - <<'PY'
import json, datetime, subprocess, sys
with open("{{TENANT_AGENT_HOME}}/tasks/active.json") as f: active = json.load(f)
now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
stale = []
for tid, t in active.items():
    if t.get("state") not in ("in_progress", "awaiting_review"): continue
    upd_str = t.get("updated_at", "").replace("Z","")
    if not upd_str: continue
    try:
        upd = datetime.datetime.fromisoformat(upd_str)
    except ValueError:
        continue
    age_hours = (now - upd).total_seconds() / 3600
    if age_hours >= 48 and "stale-flagged" not in [c.get("msg","") for c in t.get("events",[])]:
        stale.append((tid, t, age_hours))

# Mark each stale and ping
for tid, t, age in stale:
    age_d = int(age // 24)
    msg = f"No movement in {age_d}+ days — discuss or extend?"
    subprocess.run([
        "{{TENANT_AGENT_HOME}}/scripts/task-ledger.sh", "state",
        "--id", tid, "--state", "stale", "--msg", msg
    ], check=False)
print(f"flagged {len(stale)} stale tasks")
PY
