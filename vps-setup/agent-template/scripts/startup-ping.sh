#!/usr/bin/env bash
# startup-ping.sh — "I'm back" Telegram card on agent restart.
# Called from ExecStartPost in claude-agent.service (=-prefix so failures don't block start).
# Also safe to call via @reboot cron.
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"
TASKS="$AGENT_HOME/tasks/active.json"

# Wait for Telegram bridge to be ready (tmux session must be up)
sleep 8

[[ ! -x "$TG_SEND" ]] && exit 0

# Count open tasks by state
if [[ -f "$TASKS" ]]; then
  OPEN=$(python3 -c "
import json,sys
from pathlib import Path
d = json.loads(Path('$TASKS').read_text())
active = [v for v in d.values() if v.get('state') not in ('done','cancelled','stale')]
blocking = [v for v in active if v.get('state') in ('awaiting_review','blocked')]
top = next((v['summary'][:60] for v in active if v.get('state') == 'awaiting_review'), '')
if not top:
    top = next((v['summary'][:60] for v in active if v.get('state') == 'in_progress'), '')
if not top:
    top = next((v['summary'][:60] for v in active), '')
print(f'{len(active)}|{len(blocking)}|{top}')
" 2>/dev/null || echo "0|0|")
  TOTAL=$(echo "$OPEN" | cut -d'|' -f1)
  NEEDS_ATTN=$(echo "$OPEN" | cut -d'|' -f2)
  TOP=$(echo "$OPEN" | cut -d'|' -f3-)
else
  TOTAL=0; NEEDS_ATTN=0; TOP=""
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MSG="🟢 Agent back online — ${TS}
${TOTAL} task(s) open · ${NEEDS_ATTN} need attention"
[[ -n "$TOP" ]] && MSG="${MSG}
Top priority: ${TOP}"

"$TG_SEND" send --text "$MSG" >/dev/null 2>&1 || true
