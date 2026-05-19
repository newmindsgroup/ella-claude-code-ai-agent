#!/usr/bin/env bash
# context-inject.sh — SessionStart hook
# Outputs JSON with additionalContext so Claude wakes up with full state after any restart.

AGENT_HOME="{{TENANT_AGENT_HOME}}"

# Warm up embedding daemon in the background so first recall is fast
bash "$AGENT_HOME/scripts/start-embedding-daemon.sh" >/dev/null 2>&1 &

HISTORY="$AGENT_HOME/telegram-history.jsonl"
SUMMARY="$AGENT_HOME/context/session-summary.md"
ACTIVE="$AGENT_HOME/context/active.md"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

{
  echo "[AUTO-INJECTED CONTEXT — session resumed]"
  echo ""

  # 1. Last session summary (within 72h)
  if [[ -f "$SUMMARY" ]]; then
    age=$(( $(date +%s) - $(date -r "$SUMMARY" +%s 2>/dev/null || echo 0) ))
    if (( age < 259200 )); then
      echo "## Last session summary"
      cat "$SUMMARY" 2>/dev/null
      echo ""
    fi
  fi

  # 2. Recent Telegram history (last 10)
  if [[ -f "$HISTORY" ]]; then
    history_out=$(bash "$AGENT_HOME/scripts/tg-history-log.sh" tail 10 2>/dev/null)
    if [[ -n "$history_out" ]]; then
      echo "## Recent Telegram history (last 10)"
      echo "$history_out"
      echo ""
    fi
  fi

  # 3. Open tasks (full detail for active ones)
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
    print('\n'.join(lines[:12]))
PYEOF
)
  if [[ -n "$open_tasks" ]]; then
    echo "## Open tasks"
    echo "$open_tasks"
    echo ""
  fi

  # 4. Key memories — preferences, decisions, recent facts (top 8 by recency+access)
  key_memories=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, sqlite3

db_path = '{{TENANT_AGENT_HOME}}/memory/vault.db'
if not os.path.exists(db_path):
    # fallback: read jsonl
    jpath = '{{TENANT_AGENT_HOME}}/memory/vault.jsonl'
    if not os.path.exists(jpath):
        exit(0)
    entries = []
    with open(jpath) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                m = json.loads(line)
                if not m.get('deleted'):
                    entries.append(m)
            except: pass
    entries.sort(key=lambda x: (x.get('access_count',0), x.get('created_at','')), reverse=True)
    for m in entries[:8]:
        print(f'  [{m.get("type","?")}] {m.get("text","")[:140]}')
    exit(0)

try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("""
        SELECT type, text, tags FROM memories
        WHERE superseded_by IS NULL
        ORDER BY last_accessed DESC, access_count DESC, created_at DESC
        LIMIT 10
    """)
    rows = cur.fetchall()
    conn.close()
    for mtype, text, tags in rows:
        tag_str = f' [{tags}]' if tags else ''
        print(f'  [{mtype}]{tag_str} {text[:140]}')
except Exception as e:
    pass
PYEOF
)
  if [[ -n "$key_memories" ]]; then
    echo "## Key memories (top by recency + access)"
    echo "$key_memories"
    echo ""
  fi

  # 5. Active context file
  if [[ -f "$ACTIVE" ]]; then
    content=$(grep -v '^_No' "$ACTIVE" 2>/dev/null | head -40)
    if [[ -n "$content" ]]; then
      echo "## Active context"
      echo "$content"
      echo ""
    fi
  fi

  # 6. Active goals (brief)
  goals=$(bash "$AGENT_HOME/scripts/goal-tracker.sh" render 2>/dev/null | grep -v '^$' | head -10 || true)
  if [[ -n "$goals" ]]; then
    echo "## Active goals"
    echo "$goals"
    echo ""
  fi

  echo "---"
} > "$TMPFILE"

context=$(cat "$TMPFILE")

line_count=$(wc -l < "$TMPFILE")
if (( line_count < 5 )); then
  exit 0
fi

python3 -c "
import json, sys
ctx = open('$TMPFILE').read()
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'SessionStart',
    'additionalContext': ctx
  }
}))
"
