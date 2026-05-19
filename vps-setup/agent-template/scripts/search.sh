#!/usr/bin/env bash
# search.sh — unified search across memory vault + conversation history.
# Usage: search.sh <query> [--limit N]
# Returns combined results as plain text for Telegram or Discord.
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
QUERY="${1:-}"
LIMIT=8
[[ "${2:-}" == "--limit" ]] && LIMIT="${3:-8}"

[[ -z "$QUERY" ]] && { echo "usage: search.sh <query> [--limit N]" >&2; exit 1; }

echo "=== Memory vault ==="
bash "$AGENT_HOME/scripts/memory-vault.sh" recall --query "$QUERY" --limit "$LIMIT" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    items = json.load(sys.stdin)
    if not items:
        print('  (no matches)')
    else:
        for it in items:
            ts = it.get('created_at','')[:10]
            print(f\"  [{it['type']}] {it['text'][:180]}  — {it['id']} · {ts}\")
except:
    print('  (error reading vault)')
"

echo ""
echo "=== Conversation history ==="
HISTORY="$AGENT_HOME/telegram-history.jsonl"
if [[ -f "$HISTORY" ]]; then
  python3 - "$QUERY" <<'PYEOF'
import json, sys, re
query = sys.argv[1].lower()
history_path = "{{TENANT_AGENT_HOME}}/telegram-history.jsonl"
matches = []
with open(history_path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: ev = json.loads(line)
        except: continue
        text = (ev.get("text") or "").lower()
        if query in text:
            ts = ev.get("ts","")[:16]
            direction = "←" if ev.get("direction","") != "out" else "→"
            matches.append(f"  [{ts}] {direction} {ev.get('text','')[:160]}")
if not matches:
    print("  (no matches in history)")
else:
    for m in matches[-8:]:
        print(m)
PYEOF
else
  echo "  (no history file)"
fi
