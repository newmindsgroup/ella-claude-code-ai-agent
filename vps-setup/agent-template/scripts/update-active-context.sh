#!/usr/bin/env bash
# update-active-context.sh — refresh active.md with real current state
# Call this any time focus shifts, a task changes state, or from PostToolUse hooks.
# Usage: bash update-active-context.sh [--note "one-line note"]

AGENT_HOME="{{TENANT_AGENT_HOME}}"
ACTIVE="$AGENT_HOME/context/active.md"
NOTE="${2:-}"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# In-progress tasks
in_progress=$(python3 - <<'PYEOF' 2>/dev/null
import json, os
path = '{{TENANT_AGENT_HOME}}/tasks/active.json'
if not os.path.exists(path): exit(0)
with open(path) as f: tasks = json.load(f)
for tid, t in tasks.items():
    if t.get('state') == 'in_progress':
        print(f'- {t.get("summary","?")[:100]} (`{tid}`)')
PYEOF
)

# Awaiting review
awaiting_review=$(python3 - <<'PYEOF' 2>/dev/null
import json, os
path = '{{TENANT_AGENT_HOME}}/tasks/active.json'
if not os.path.exists(path): exit(0)
with open(path) as f: tasks = json.load(f)
for tid, t in tasks.items():
    if t.get('state') == 'awaiting_review':
        msg = t.get('last_message','')
        summary = t.get('summary','?')[:90]
        link = f' — {msg}' if msg else ''
        print(f'- {summary}{link} (`{tid}`)')
PYEOF
)

# Awaiting external
awaiting_external=$(python3 - <<'PYEOF' 2>/dev/null
import json, os
path = '{{TENANT_AGENT_HOME}}/tasks/active.json'
if not os.path.exists(path): exit(0)
with open(path) as f: tasks = json.load(f)
for tid, t in tasks.items():
    if t.get('state') == 'awaiting_external':
        dl = t.get('deadline','')
        due = f' · due {dl}' if dl else ''
        print(f'- {t.get("summary","?")[:90]}{due} (`{tid}`)')
PYEOF
)

# Recent decisions from memory vault
recent_decisions=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, sqlite3, time
db = '{{TENANT_AGENT_HOME}}/memory/vault.db'
if not os.path.exists(db): exit(0)
try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute("""
        SELECT text FROM memories
        WHERE superseded_by IS NULL AND type='decision'
        ORDER BY created_at DESC LIMIT 3
    """)
    for (text,) in cur.fetchall():
        print(f'- {text[:120]}')
    conn.close()
except: pass
PYEOF
)

# Key relationships from memory
relationships=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, sqlite3
db = '{{TENANT_AGENT_HOME}}/memory/vault.db'
if not os.path.exists(db): exit(0)
try:
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    cur.execute("""
        SELECT text FROM memories
        WHERE superseded_by IS NULL AND type='relationship'
        ORDER BY last_accessed DESC LIMIT 4
    """)
    for (text,) in cur.fetchall():
        print(f'- {text[:120]}')
    conn.close()
except: pass
PYEOF
)

{
  echo "# Active context — Daniel Gonell chief-of-staff"
  echo ""
  echo "Last updated: $ts"
  echo ""
  echo "## Current focus"
  if [[ -n "$in_progress" ]]; then
    echo "$in_progress"
  else
    echo "_No tasks in progress_"
  fi
  echo ""
  if [[ -n "$NOTE" ]]; then
    echo "## Note"
    echo "$NOTE"
    echo ""
  fi
  echo "## Pending reviews (needs Daniel's attention)"
  if [[ -n "$awaiting_review" ]]; then
    echo "$awaiting_review"
  else
    echo "_No items awaiting review_"
  fi
  echo ""
  echo "## Waiting on Daniel"
  if [[ -n "$awaiting_external" ]]; then
    echo "$awaiting_external"
  else
    echo "_Nothing awaiting external action_"
  fi
  echo ""
  echo "## Recent decisions"
  if [[ -n "$recent_decisions" ]]; then
    echo "$recent_decisions"
  else
    echo "_No recent decisions in vault_"
  fi
  echo ""
  echo "## Key relationships / active deals"
  if [[ -n "$relationships" ]]; then
    echo "$relationships"
  else
    echo "_No relationship memories yet_"
  fi
  echo ""
  echo "## Notes"
  echo "Update this file when: major decisions are made, new clients onboarded, focus shifts, or Daniel explicitly asks to note something here."
  echo ""
  echo "---"
} > "$ACTIVE"
