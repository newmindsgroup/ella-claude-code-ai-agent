#!/usr/bin/env bash
# memory-extract.sh — post-session memory extraction
#
# Reads the recent conversation log and extracts memorable events
# (decisions, commitments, preferences, relationships, facts, goals)
# that should survive across sessions.
#
# Usage:
#   memory-extract.sh [--input FILE] [--since "2026-05-05T10:00:00Z"] [--dry-run]
#
# Designed to run: (a) at end of each non-trivial session, (b) via nightly cron
# as a safety net for anything missed during the session.

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
SCRIPTS="$AGENT_HOME/scripts"
LOG_DIR="$AGENT_HOME/logs"
EXTRACT_LOG="$LOG_DIR/memory-extract.log"

mkdir -p "$LOG_DIR"

input_file=""
since=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)   input_file="$2"; shift 2 ;;
    --since)   since="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) shift ;;
  esac
done

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(now)] $*" >> "$EXTRACT_LOG"; }

# Gather conversation context
# Pull from dashboard chat history and recent task ledger events
context_parts=()

if [[ -n "$input_file" && -f "$input_file" ]]; then
  context_parts+=("$(cat "$input_file")")
fi

# Pull recent dashboard chat history (last 50 messages)
CHAT_HISTORY="$AGENT_HOME/dashboard-chat/history.jsonl"
if [[ -f "$CHAT_HISTORY" ]]; then
  recent_chat=$(tail -50 "$CHAT_HISTORY" 2>/dev/null | python3 -c "
import sys, json
lines = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        role = d.get('role', 'unknown')
        content = d.get('content', '')[:500]
        ts = d.get('ts', '')[:16]
        lines.append(f'[{ts}] {role}: {content}')
    except: pass
print('\n'.join(lines[-30:]))
" 2>/dev/null || true)
  [[ -n "$recent_chat" ]] && context_parts+=("$recent_chat")
fi

# Pull recent task events (committed tasks = implicit decisions/commitments)
TASKS_DIR="$AGENT_HOME/tasks"
if [[ -d "$TASKS_DIR" ]]; then
  recent_tasks=$(find "$TASKS_DIR" -name "*.json" -newer "$TASKS_DIR" -mmin -1440 2>/dev/null | head -20 | xargs -I{} python3 -c "
import json, sys
try:
    d = json.load(open('{}'))
    s = d.get('summary', '')
    state = d.get('state', '')
    owner = d.get('owner', '')
    print(f'Task [{state}]: {s} (owner: {owner})')
except: pass
" 2>/dev/null || true)
  [[ -n "$recent_tasks" ]] && context_parts+=("Recent tasks:\n$recent_tasks")
fi

if [[ ${#context_parts[@]} -eq 0 ]]; then
  log "No context to extract from — skipping"
  exit 0
fi

full_context=$(printf '%s\n\n' "${context_parts[@]}")

if [[ ${#full_context} -lt 100 ]]; then
  log "Context too short (${#full_context} chars) — skipping"
  exit 0
fi

# Get already-known memory IDs to avoid re-saving duplicates
existing_memories=$(bash "$SCRIPTS/memory-vault.sh" recall --limit 50 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); [print(m['text'][:120]) for m in d]" 2>/dev/null || true)

log "Extracting from ${#full_context} chars of context"

# Run extraction via Claude
PROMPT="You are a memory extraction system for Daniel Gonell's AI chief-of-staff agent.

Analyze this recent conversation/activity log and extract ONLY items that:
1. Are NEW facts not already known (check existing memories list)
2. Have lasting value beyond this session
3. Fall into these types: fact, decision, relationship, preference, commitment, goal, context, pattern

EXISTING MEMORIES (do not re-extract these):
${existing_memories:-none}

CONVERSATION/ACTIVITY LOG:
${full_context:0:6000}

OUTPUT: Return a JSON array. Each item must have:
- type: one of fact|decision|relationship|preference|commitment|goal|context|pattern
- text: the memory text (complete, self-contained sentence, ≤200 chars)
- tags: array of 2-5 lowercase tags
- confidence: 0.0-1.0
- source: \"session-extraction\"

Rules:
- Only extract if confidence ≥ 0.80
- Skip operational noise (\"user asked for X\", \"agent ran Y\")
- Focus on: people met, decisions made, preferences expressed, commitments given, goals stated, durable facts
- Return [] if nothing extractable
- Return ONLY valid JSON array, no prose

Example: [{\"type\":\"preference\",\"text\":\"Daniel prefers PDF deliverables over Word docs for client proposals.\",\"tags\":[\"client\",\"deliverables\",\"preference\"],\"confidence\":0.92,\"source\":\"session-extraction\"}]"

extracted=$(echo "$PROMPT" | claude --print --model claude-haiku-4-5-20251001 2>/dev/null | \
  python3 -c "
import sys, json, re
raw = sys.stdin.read()
# Find JSON array in output
m = re.search(r'\[.*\]', raw, re.DOTALL)
if not m:
    print('[]')
    sys.exit(0)
try:
    arr = json.loads(m.group())
    print(json.dumps(arr))
except:
    print('[]')
" 2>/dev/null || echo "[]")

count=$(echo "$extracted" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)

if [[ "$count" -eq 0 ]]; then
  log "No new memories extracted"
  exit 0
fi

log "Extracted $count candidate memories"

if [[ "$dry_run" == "true" ]]; then
  echo "DRY RUN — would save $count memories:"
  echo "$extracted" | python3 -c "
import json, sys
for m in json.load(sys.stdin):
    print(f'  [{m[\"type\"]}] {m[\"text\"][:100]} (conf={m[\"confidence\"]})')
"
  exit 0
fi

# Save each extracted memory
saved=0
echo "$extracted" | python3 -c "
import json, sys
for m in json.load(sys.stdin):
    print(json.dumps(m))
" | while read -r mem_json; do
  type_=$(echo "$mem_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")
  text_=$(echo "$mem_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['text'])")
  tags_=$(echo "$mem_json" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(','.join(d.get('tags',[])))")
  conf_=$(echo "$mem_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('confidence',0.9))")

  mid=$(bash "$SCRIPTS/memory-vault.sh" add \
    --type "$type_" \
    --text "$text_" \
    --tags "$tags_" \
    --confidence "$conf_" \
    --source "session-extraction" 2>/dev/null)

  log "Saved $mid [$type_]: ${text_:0:80}"
  saved=$((saved + 1))
done

log "Session extraction complete — $count candidates processed"
