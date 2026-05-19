#!/usr/bin/env bash
# context-refresh.sh — auto-refresh active.md on task state changes
#
# Reads the task ledger and memory vault and rewrites context/active.md
# with current focus, recent decisions, pending reviews, active deals.
#
# Called by: task-update.sh (on every state transition)
# Also callable manually: context-refresh.sh

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
SCRIPTS="$AGENT_HOME/scripts"
CONTEXT="$AGENT_HOME/context/active.md"
TASKS_DIR="$AGENT_HOME/tasks"
LOG_DIR="$AGENT_HOME/logs"

mkdir -p "$LOG_DIR" "$(dirname "$CONTEXT")"

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Get awaiting_review tasks
awaiting_review=$(find "$TASKS_DIR" -name "*.json" -newer /dev/null 2>/dev/null | \
  xargs grep -l '"state": "awaiting_review"' 2>/dev/null | \
  xargs -I{} python3 -c "
import json,sys
try:
    t = json.load(open('{}'))
    if t.get('state') == 'awaiting_review':
        print('- ' + t.get('summary','?')[:80] + ' (' + t.get('id','') + ')')
except: pass
" 2>/dev/null | head -10)

# Get in_progress tasks
in_progress=$(find "$TASKS_DIR" -name "*.json" 2>/dev/null | \
  xargs grep -l '"state": "in_progress"' 2>/dev/null | \
  xargs -I{} python3 -c "
import json,sys
try:
    t = json.load(open('{}'))
    if t.get('state') == 'in_progress':
        print('- ' + t.get('summary','?')[:80] + ' (' + t.get('id','') + ')')
except: pass
" 2>/dev/null | head -5)

# Get awaiting_external tasks
awaiting_external=$(find "$TASKS_DIR" -name "*.json" 2>/dev/null | \
  xargs grep -l '"state": "awaiting_external"' 2>/dev/null | \
  xargs -I{} python3 -c "
import json,sys
try:
    t = json.load(open('{}'))
    if t.get('state') == 'awaiting_external':
        print('- ' + t.get('summary','?')[:80] + ' (' + t.get('id','') + ')')
except: pass
" 2>/dev/null | head -5)

# Get recent decisions from memory vault
recent_decisions=$(bash "$SCRIPTS/memory-vault.sh" recall --type decision --limit 3 2>/dev/null | \
  python3 -c "
import json,sys
try:
    mems = json.load(sys.stdin)
    for m in mems[:3]:
        print('- ' + m.get('text','')[:100])
except: pass
" 2>/dev/null || echo "")

# Get active deals/clients from relationship memories
active_relationships=$(bash "$SCRIPTS/memory-vault.sh" recall --type relationship --limit 4 2>/dev/null | \
  python3 -c "
import json,sys
try:
    mems = json.load(sys.stdin)
    for m in mems[:4]:
        print('- ' + m.get('text','')[:100])
except: pass
" 2>/dev/null || echo "")

cat > "$CONTEXT" << CONTEXT_EOF
# Active context — Daniel Gonell chief-of-staff

Last updated: $(now)

## Current focus
${in_progress:-_No tasks in progress_}

## Pending reviews (needs Daniel's attention)
${awaiting_review:-_No items awaiting review_}

## Waiting on Daniel
${awaiting_external:-_Nothing awaiting external action_}

## Recent decisions
${recent_decisions:-_No recent decisions in vault_}

## Key relationships / active deals
${active_relationships:-_No relationship memories yet_}

## Notes
Update this file when: major decisions are made, new clients onboarded, focus shifts, or Daniel explicitly asks to note something here.
CONTEXT_EOF

echo "context refreshed at $(now)"
