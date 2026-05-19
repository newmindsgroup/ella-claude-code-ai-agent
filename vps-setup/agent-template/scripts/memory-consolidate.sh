#!/usr/bin/env bash
# memory-consolidate.sh — nightly memory deduplication and contradiction check
#
# Reads all active memories, checks for:
#   1. Near-duplicate text (same fact stored twice with different wording)
#   2. Contradicting memories (conflicting facts about the same topic)
#   3. Stale time-bound facts that should be archived
#
# Sends a Telegram summary of anything found. Does NOT auto-merge — surfaces for review.
#
# Usage:
#   memory-consolidate.sh [--dry-run] [--quiet]

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
SCRIPTS="$AGENT_HOME/scripts"
MEM_DIR="$AGENT_HOME/memory"
LOG_DIR="$AGENT_HOME/logs"
CONSOLIDATE_LOG="$LOG_DIR/memory-consolidate.log"
CHAT_ID="${TG_CHAT_ID:-1439634560}"

mkdir -p "$LOG_DIR"

dry_run=false
quiet=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --quiet)   quiet=true; shift ;;
    *) shift ;;
  esac
done

now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(now)] $*" >> "$CONSOLIDATE_LOG"; }

log "Starting consolidation run"

# Get all active memories
all_memories=$(bash "$SCRIPTS/memory-vault.sh" recall --limit 200 2>/dev/null)
count=$(echo "$all_memories" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$count" -lt 3 ]]; then
  log "Fewer than 3 memories — nothing to consolidate"
  exit 0
fi

log "Checking $count memories for duplicates and contradictions"

# Run consolidation check via Claude
PROMPT="You are a memory consolidation system. Review this list of AI agent memories for duplicates and contradictions.

MEMORIES:
$(echo "$all_memories" | python3 -c "
import json, sys
mems = json.load(sys.stdin)
for m in mems:
    print(f'ID: {m[\"id\"]} | TYPE: {m[\"type\"]} | TEXT: {m[\"text\"][:200]}')
")

Find and return a JSON object with:
{
  \"duplicates\": [
    {\"ids\": [\"m-xx\", \"m-yy\"], \"reason\": \"same fact, different wording\", \"keep\": \"m-xx\", \"forget\": \"m-yy\"}
  ],
  \"contradictions\": [
    {\"ids\": [\"m-xx\", \"m-yy\"], \"reason\": \"m-xx says X but m-yy says Y about topic Z\", \"note\": \"which is likely current?\"}
  ],
  \"stale\": [
    {\"id\": \"m-xx\", \"reason\": \"references a past date/event that is now over\"}
  ]
}

Rules:
- Only flag CLEAR duplicates or contradictions (confidence ≥ 0.85)
- Stale: only flag time-bound facts with past dates (e.g., 'meeting on April 5' when it's May)
- Preferences and relationships never go stale automatically
- Return empty arrays if nothing found
- Return ONLY valid JSON, no prose"

issues=$(echo "$PROMPT" | claude --print --model claude-haiku-4-5-20251001 2>/dev/null | \
  python3 -c "
import sys, json, re
raw = sys.stdin.read()
m = re.search(r'\{.*\}', raw, re.DOTALL)
if not m:
    print('{\"duplicates\":[],\"contradictions\":[],\"stale\":[]}')
    sys.exit(0)
try:
    obj = json.loads(m.group())
    print(json.dumps(obj))
except:
    print('{\"duplicates\":[],\"contradictions\":[],\"stale\":[]}')
" 2>/dev/null || echo '{"duplicates":[],"contradictions":[],"stale":[]}')

dup_count=$(echo "$issues" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('duplicates',[])))" 2>/dev/null || echo 0)
con_count=$(echo "$issues" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('contradictions',[])))" 2>/dev/null || echo 0)
stale_count=$(echo "$issues" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('stale',[])))" 2>/dev/null || echo 0)
total_issues=$((dup_count + con_count + stale_count))

log "Found: $dup_count duplicates, $con_count contradictions, $stale_count stale"

if [[ "$total_issues" -eq 0 ]]; then
  log "Memory vault is clean — no issues found"
  [[ "$quiet" == "false" ]] && log "Clean run — no Telegram ping needed"
  exit 0
fi

# Build report
report=$(echo "$issues" | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = ['*🧠 Memory consolidation — action needed*', '']

dups = d.get('duplicates', [])
if dups:
    lines.append(f'*Duplicates \({len(dups)}\):*')
    for item in dups:
        lines.append(f'  • Keep \`{item[\"keep\"]}\`, forget \`{item[\"forget\"]}\` — {item[\"reason\"][:80]}')
    lines.append('')

cons = d.get('contradictions', [])
if cons:
    lines.append(f'*Contradictions \({len(cons)}\):*')
    for item in cons:
        ids = ', '.join([f'\`{i}\`' for i in item['ids']])
        lines.append(f'  • {ids} — {item[\"reason\"][:100]}')
    lines.append('')

stale = d.get('stale', [])
if stale:
    lines.append(f'*Stale memories \({len(stale)}\):*')
    for item in stale:
        lines.append(f'  • \`{item[\"id\"]}\` — {item[\"reason\"][:80]}')
    lines.append('')

lines.append('_Reply_ \`/forget <id>\` _to remove, or ignore to keep all\._')
print('\n'.join(lines))
" 2>/dev/null || echo "*Memory consolidation* — $total_issues issues found\. Run \`/memories\` to review\.")

log "Issues found: $dup_count dup, $con_count contradiction, $stale_count stale"

if [[ "$dry_run" == "true" ]]; then
  echo "DRY RUN consolidation report:"
  echo "$report"
  exit 0
fi

# If contradictions found, flag immediately regardless of quiet mode
if [[ "$con_count" -gt 0 || "$dup_count" -gt 2 ]]; then
  bash "$SCRIPTS/tg-send.sh" send --md --text "$report" 2>/dev/null || log "Telegram send failed"
elif [[ "$quiet" == "false" ]]; then
  bash "$SCRIPTS/tg-send.sh" send --md --text "$report" 2>/dev/null || log "Telegram send failed"
fi

log "Consolidation run complete"
