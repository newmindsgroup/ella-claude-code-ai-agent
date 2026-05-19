#!/usr/bin/env bash
# entity-linker.sh — cross-session entity linking
#
# Scans the memory vault for names that appear in 3+ separate memories.
# When found, auto-promotes them to a canonical `relationship` record
# that links all references. This turns scattered mentions into a proper
# entity graph entry.
#
# Usage: entity-linker.sh [--dry-run] [--quiet]
# Runs nightly via cron; also called after memory-vault.sh add.

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
SCRIPTS="$AGENT_HOME/scripts"
MEM_DIR="$AGENT_HOME/memory"
LOG_DIR="$AGENT_HOME/logs"
LINKER_LOG="$LOG_DIR/entity-linker.log"

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
log() { echo "[$(now)] $*" >> "$LINKER_LOG"; }

log "Entity linker run starting"

# Get all active memories
all_memories=$(bash "$SCRIPTS/memory-vault.sh" recall --limit 200 2>/dev/null || echo "[]")
count=$(echo "$all_memories" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$count" -lt 3 ]]; then
  log "Not enough memories to link ($count)"
  exit 0
fi

python3 << PYEOF
import json, subprocess, re, sys, os
from collections import defaultdict

SCRIPTS = "$SCRIPTS"
DRY_RUN = "$dry_run" == "true"

all_memories = json.loads("""$(echo "$all_memories" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)))")""")

# Find existing relationship memories so we don't duplicate
existing_relationships = set()
for m in all_memories:
    if m.get('type') == 'relationship':
        existing_relationships.add(m.get('text', '')[:60].lower())

# Extract proper-noun names from memory texts
# Look for capitalized words/phrases that appear in multiple distinct memories
name_to_memory_ids = defaultdict(list)

for m in all_memories:
    mid = m.get('id', '')
    text = m.get('text', '')
    # Find capitalized names: 2+ words where first letter is cap, or single CamelCase names
    # Exclude common words
    STOP = {'Daniel', 'Gonell', 'GHL', 'LinkedIn', 'Instagram', 'Telegram', 'Claude',
            'AI', 'UX', 'PDF', 'SMS', 'ID', 'OK', 'The', 'A', 'An', 'In', 'On', 'For',
            'To', 'Is', 'Are', 'Was', 'Will', 'When', 'That', 'This', 'With', 'From'}
    # Match: FirstName LastName, or single proper nouns that are company-like
    names = re.findall(r'\b([A-Z][a-z]{2,}(?:\s+[A-Z][a-z]{2,})+)\b', text)
    names += re.findall(r'\b([A-Z][a-z]{2,}(?:[A-Z][a-z]+)+)\b', text)  # CamelCase
    for name in names:
        if name not in STOP and len(name) > 4:
            name_to_memory_ids[name].append(mid)

# Find names appearing in 3+ distinct memories
candidates = {
    name: list(set(ids))
    for name, ids in name_to_memory_ids.items()
    if len(set(ids)) >= 3
}

promoted = 0
for name, mem_ids in candidates.items():
    # Check if already a relationship memory for this entity
    key = name.lower()[:60]
    already_linked = any(key in r for r in existing_relationships)
    if already_linked:
        continue

    # Build summary from the memory texts
    linked_texts = []
    for m in all_memories:
        if m.get('id') in mem_ids:
            linked_texts.append(m.get('text', '')[:120])

    summary = f"{name} — mentioned in {len(mem_ids)} memories: " + " | ".join(linked_texts[:3])

    if DRY_RUN:
        print(f"[DRY RUN] Would promote: {name} ({len(mem_ids)} memories)")
        continue

    result = subprocess.run([
        'bash', f'{SCRIPTS}/memory-vault.sh', 'add',
        '--type', 'relationship',
        '--text', summary[:400],
        '--tags', f'entity-link,{name.lower().replace(" ", "-")}',
        '--source', 'entity-linker',
        '--confidence', '0.8'
    ], capture_output=True, text=True)

    if result.returncode == 0:
        promoted += 1
        print(f"Promoted: {name} → relationship ({len(mem_ids)} sources)")

print(f"Entity linker complete: {promoted} entities promoted, {len(candidates)} candidates found")
PYEOF

log "Entity linker run complete"
