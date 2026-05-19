#!/usr/bin/env bash
# commitment-deadline-watcher.sh — proactive Telegram nudge when a commitment
# to a client/person is approaching its deadline.
# Architecture mirrors task-deadline-watcher.sh. Reads commitment memories
# from the vault, extracts deadlines from memory text, pings at 24h / 4h / now.
# Run hourly via cron (same schedule as task-deadline-watcher).

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
VAULT="$AGENT_HOME/memory/vault.jsonl"
NUDGE_LOG="$AGENT_HOME/notifications/commitment-nudges.jsonl"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$NUDGE_LOG")"
touch "$NUDGE_LOG"

[[ ! -f "$VAULT" ]] && { echo "no vault at $VAULT"; exit 0; }
[[ ! -x "$TG_SEND" ]] && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

now_epoch=$(date -u +%s)
nudged=0

# Extract commitment memories that have a deadline field in the text
# Format logged by commitment-log.sh: "To Name: text (deadline: YYYY-MM-DD)"
python3 - <<PYEOF | while IFS=$'\t' read -r mem_id to_name text deadline; do
import json, re, sys
from pathlib import Path

vault = Path("$VAULT")
seen = set()
with vault.open() as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: ev = json.loads(line)
        except: continue
        if ev.get("event") == "forget":
            seen.discard(ev.get("id",""))
            continue
        if ev.get("event") != "add" or ev.get("type") != "commitment":
            continue
        mid = ev.get("id","")
        if mid in seen: continue
        seen.add(mid)
        text = ev.get("text","")
        # Extract deadline: "(deadline: YYYY-MM-DD)"
        m = re.search(r'deadline:\s*(\d{4}-\d{2}-\d{2})', text)
        if not m: continue
        deadline = m.group(1)
        # Extract "To Name:" prefix
        to_m = re.match(r'^To ([^:]+):', text)
        to_name = to_m.group(1) if to_m else ""
        print(f"{mid}\t{to_name}\t{text[:200]}\t{deadline}")
PYEOF

  [[ -z "$mem_id" || -z "$deadline" ]] && continue

  dl_epoch=$(date -d "$deadline" +%s 2>/dev/null || echo "")
  [[ -z "$dl_epoch" ]] && continue

  diff_sec=$((dl_epoch - now_epoch))

  if   [[ $diff_sec -le 1800  && $diff_sec -gt -3600 ]]; then  window="due_now"; label="due NOW"
  elif [[ $diff_sec -le 14400 && $diff_sec -gt 1800 ]]; then   window="4h";      label="due in ~4h"
  elif [[ $diff_sec -le 86400 && $diff_sec -gt 14400 ]]; then  window="24h";     label="due in ~24h"
  else continue
  fi

  nudge_key="$mem_id:$window"
  grep -q "\"$nudge_key\"" "$NUDGE_LOG" 2>/dev/null && continue

  emoji="⏰"; [[ "$window" == "due_now" ]] && emoji="🚨"
  to_label="${to_name:+to ${to_name}: }"
  msg=$(printf "%s Commitment %s\n%s%s\n\nID: %s" \
    "$emoji" "$label" "$to_label" "${text:0:180}" "$mem_id")

  if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
    printf '{"key":"%s","sent_at":"%s","mem_id":"%s","window":"%s"}\n' \
      "$nudge_key" "$(date -u +%FT%TZ)" "$mem_id" "$window" >> "$NUDGE_LOG"
    nudged=$((nudged + 1))
  fi
done

echo "commitment-deadline-watcher: $nudged nudges sent at $(date -u +%FT%TZ)"
