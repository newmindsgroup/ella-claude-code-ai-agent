#!/usr/bin/env bash
# memory-auto-extract.sh — background memory extraction after each reply
# Reads the last exchange from telegram-history.jsonl, sends to Claude (haiku)
# to extract memorable facts/decisions/preferences, saves to memory vault.
#
# Called by: settings.json PostToolUse hook on mcp__plugin_telegram_telegram__reply
# Runs async — never blocks the main reply.

set -euo pipefail

AGENT_HOME="{{TENANT_AGENT_HOME}}"
HISTORY="$AGENT_HOME/telegram-history.jsonl"
EXTRACT_LOG="$AGENT_HOME/logs/memory-auto-extract.log"
LOCK="$AGENT_HOME/logs/memory-auto-extract.lock"

mkdir -p "$AGENT_HOME/logs"

# Debounce: only run if last run was >60s ago
if [[ -f "$LOCK" ]]; then
  last=$(cat "$LOCK" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - last < 60 )); then
    exit 0
  fi
fi
date +%s > "$LOCK"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$EXTRACT_LOG"; }

# Get the last 6 messages (both inbound and outbound) for extraction
if [[ ! -f "$HISTORY" ]]; then
  exit 0
fi

recent_exchange=$(python3 -c "
import json, sys
entries = []
with open('$HISTORY') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            label = 'Daniel' if e.get('dir') == 'inbound' else 'Agent'
            entries.append((label, e.get('text','')))
        except: pass
# last 6 entries (full exchange)
for label, text in entries[-6:]:
    print(f'{label}: {text[:400]}')
" 2>/dev/null)

if [[ -z "$recent_exchange" ]]; then
  exit 0
fi

# Ask claude haiku to extract memorable content from the full exchange
# Extract from Daniel's messages: facts, decisions, preferences, relationships, goals
# Extract from Agent's messages: key recommendations and plans (as context memories)
extraction=$(claude --model claude-haiku-4-5-20251001 --print --max-tokens 500 \
  "You are a memory extraction assistant for a chief-of-staff AI. Read this recent exchange and extract ONLY clearly memorable content.

FROM DANIEL'S MESSAGES: facts about pricing/clients/services, explicit decisions, preferences ('I prefer...', 'I never...', 'I always...'), named people + their roles, stated goals.
FROM AGENT'S MESSAGES: extract significant recommendations, plans, or conclusions the agent stated — save as type='context' with tags including 'agent-recommendation'. Only extract if the agent gave a clear recommendation or plan Daniel might want to reference later.

Exchange:
$recent_exchange

Output ONLY a JSON array of objects, each with: {\"type\": \"fact|decision|preference|relationship|goal|context\", \"text\": \"...\", \"tags\": [\"...\"], \"confidence\": 0.0-1.0}. If nothing is clearly memorable, output []. No explanation." 2>/dev/null || echo "[]")

# Parse and save each extracted memory
python3 - "$extraction" <<'PYEOF'
import json, sys, subprocess, os

raw = sys.argv[1].strip()
if not raw or raw == '[]':
    sys.exit(0)

# Strip markdown fences if present
if raw.startswith('```'):
    raw = '\n'.join(raw.split('\n')[1:])
    raw = raw.rstrip('`').strip()

try:
    items = json.loads(raw)
except:
    sys.exit(0)

if not isinstance(items, list):
    sys.exit(0)

for item in items[:5]:  # max 5 per pass
    if not isinstance(item, dict):
        continue
    mtype = item.get('type', 'fact')
    text = item.get('text', '').strip()
    tags = item.get('tags', [])
    confidence = float(item.get('confidence', 0.7))

    if not text or confidence < 0.6:
        continue
    if len(text) < 10 or len(text) > 500:
        continue

    valid_types = {'fact','decision','preference','relationship','goal','commitment','pattern','context'}
    if mtype not in valid_types:
        mtype = 'fact'

    tags_str = ','.join(tags[:5]) if tags else 'auto-extracted'

    result = subprocess.run([
        'bash', '{{TENANT_AGENT_HOME}}/scripts/memory-vault.sh', 'add',
        '--type', mtype,
        '--text', text,
        '--tags', tags_str,
        '--source', 'auto-extract-hook',
        '--confidence', str(confidence)
    ], capture_output=True, text=True)

    if result.returncode == 0:
        print(f"Saved {mtype}: {text[:60]}...")
PYEOF

log "Auto-extract run complete"
exit 0
