#!/usr/bin/env bash
# session-summary.sh — Stop hook
# Writes a rich session snapshot so the next session wakes up with full context.
# Called by: settings.json Stop hook

AGENT_HOME="{{TENANT_AGENT_HOME}}"
HISTORY="$AGENT_HOME/telegram-history.jsonl"
SUMMARY="$AGENT_HOME/context/session-summary.md"

mkdir -p "$AGENT_HOME/context"

# Refresh active.md first so the summary can read current state
bash "$AGENT_HOME/scripts/update-active-context.sh" 2>/dev/null || true

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 1. Recent Telegram history
recent=""
if [[ -f "$HISTORY" ]]; then
  recent=$(bash "$AGENT_HOME/scripts/tg-history-log.sh" tail 20 2>/dev/null)
fi

# 2. Open tasks with details
open_tasks=$(python3 - <<'PYEOF' 2>/dev/null
import json, os
path = '{{TENANT_AGENT_HOME}}/tasks/active.json'
if not os.path.exists(path):
    exit(0)
with open(path) as f:
    tasks = json.load(f)
active_states = {'committed','in_progress','awaiting_review','awaiting_external','blocked'}
lines = []
for tid, t in tasks.items():
    if t.get('state') in active_states:
        state = t.get('state','?')
        summary = t.get('summary','?')[:100]
        deadline = t.get('deadline','')
        owner = t.get('owner','')
        dl = f' · due {deadline}' if deadline else ''
        ow = f' · owner={owner}' if owner else ''
        lines.append(f'  [{state}] {summary}{dl}{ow} ({tid})')
if lines:
    print('\n'.join(lines))
PYEOF
)
open_count=$(echo "$open_tasks" | grep -c '\[' 2>/dev/null || echo 0)

# 3. Recently completed tasks (last 5 done in this session)
recent_done=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, time
path = '{{TENANT_AGENT_HOME}}/tasks/active.json'
if not os.path.exists(path):
    exit(0)
with open(path) as f:
    tasks = json.load(f)
cutoff = time.time() - 86400  # last 24h
done = []
for tid, t in tasks.items():
    if t.get('state') == 'done':
        updated = t.get('updated_at','')
        # include if updated recently (approximate)
        done.append(f'  ✅ {t.get("summary","?")[:100]} ({tid})')
for d in done[-5:]:
    print(d)
PYEOF
)

# 4. Recent memories created this session (last 24h)
recent_memories=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, time
from datetime import datetime, timezone

path = '{{TENANT_AGENT_HOME}}/memory/vault.jsonl'
if not os.path.exists(path):
    exit(0)

cutoff = time.time() - 86400
entries = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
            if m.get('deleted'):
                continue
            created = m.get('created_at','')
            if created:
                ts = datetime.fromisoformat(created.replace('Z','+00:00')).timestamp()
                if ts > cutoff:
                    mtype = m.get('type','?')
                    text = m.get('text','')[:120]
                    entries.append(f'  [{mtype}] {text}')
        except:
            pass
for e in entries[-8:]:
    print(e)
PYEOF
)

# 5. Active goals summary
goals_summary=$(bash "$AGENT_HOME/scripts/goal-tracker.sh" render 2>/dev/null | head -15 || true)

# 6. Key preferences/facts worth surfacing always
top_memories=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, sqlite3

db_path = '{{TENANT_AGENT_HOME}}/memory/vault.db'
if not os.path.exists(db_path):
    exit(0)

try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    # High-confidence preferences and decisions, most recently accessed
    cur.execute("""
        SELECT type, text FROM memories
        WHERE superseded_by IS NULL AND type IN ('preference','decision','fact')
        ORDER BY last_accessed DESC, access_count DESC
        LIMIT 6
    """)
    rows = cur.fetchall()
    conn.close()
    for mtype, text in rows:
        print(f'  [{mtype}] {text[:130]}')
except:
    pass
PYEOF
)

cat > "$SUMMARY" <<EOF
# Session summary — written $ts

## Recent Telegram activity (last 20 messages)
${recent:-_No history_}

## Open tasks ($open_count)
${open_tasks:-_None_}

## Recently completed
${recent_done:-_None in last 24h_}

## Memories logged this session
${recent_memories:-_None_}

## Top memories (always-relevant)
${top_memories:-_None_}

## Active goals
${goals_summary:-_None_}

## State at stop
- Stopped at: $ts
- Run /tasks for full ledger · /queue for pending reviews · /goals for goal state
EOF

exit 0
