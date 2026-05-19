#!/usr/bin/env bash
# Appends a message to the Telegram conversation history log.
# Usage:
#   tg-history-log.sh inbound  <chat_id> <message_id> <user> <text>
#   tg-history-log.sh outbound <chat_id> <message_id> <text>
#   tg-history-log.sh hook     (reads CLAUDE_TOOL_INPUT env var — called from PostToolUse)

LOG="{{TENANT_AGENT_HOME}}/telegram-history.jsonl"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

_append() {
  local json="$1"
  echo "$json" >> "$LOG"
}

case "${1:-}" in
  inbound)
    chat_id="${2:-}"
    message_id="${3:-}"
    user="${4:-}"
    text="${5:-}"
    _append "$(python3 -c "
import json, sys
print(json.dumps({
  'ts': '$TS',
  'dir': 'inbound',
  'chat_id': '$chat_id',
  'message_id': '$message_id',
  'user': '$user',
  'text': sys.argv[1]
}))" "$text")"
    ;;

  outbound)
    chat_id="${2:-}"
    message_id="${3:-}"
    text="${4:-}"
    _append "$(python3 -c "
import json, sys
print(json.dumps({
  'ts': '$TS',
  'dir': 'outbound',
  'chat_id': '$chat_id',
  'message_id': '$message_id',
  'text': sys.argv[1]
}))" "$text")"
    ;;

  hook)
    # Called from PostToolUse hook — Claude Code delivers data via stdin as JSON:
    # {"tool_name": "...", "tool_input": {...}, "tool_response": {...}}
    input="$(cat -)"
    if [ -z "$input" ]; then exit 0; fi
    _append "$(python3 -c "
import json, sys, os
payload = json.loads(sys.argv[1])
inp = payload.get('tool_input', payload)  # fallback: maybe raw input
ts = '$TS'
text = inp.get('text', '')
if not text: exit(0)
print(json.dumps({
  'ts': ts,
  'dir': 'outbound',
  'chat_id': str(inp.get('chat_id', '')),
  'message_id': '',
  'text': text
}))" "$input" 2>/dev/null || true)"
    ;;

  tail)
    # Print last N entries as human-readable recap
    n="${2:-20}"
    if [ ! -f "$LOG" ]; then echo "No history yet."; exit 0; fi
    tail -n "$n" "$LOG" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        arrow = '→' if e['dir'] == 'outbound' else '←'
        print(f\"[{e['ts']}] {arrow} {e.get('user','me') if e['dir']=='inbound' else 'me'}: {e['text'][:200]}\")
    except: pass
"
    ;;

  *)
    echo "Usage: tg-history-log.sh <inbound|outbound|hook|tail> [args...]"
    exit 1
    ;;
esac
