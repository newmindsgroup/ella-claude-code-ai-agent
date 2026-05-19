#!/usr/bin/env bash
# discord-memory-digest.sh — weekly memory summary posted to Discord #daily-brief.
# Run every Friday at 17:00 (tenant timezone) via cron.
# Groups the week's new memories by type and posts a compact digest.

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SCRIPTS="$(dirname "$0")"
API="https://discord.com/api/v10"
AUTH="Authorization: Bot $DISCORD_BOT_TOKEN"
CHANNEL="$DISCORD_CH_DAILY_BRIEF"

SINCE=$(date -d '7 days ago' -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-7d -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_LABEL=$(date +"%Y-%m-%d")

log() { echo "[$(date -u +"%H:%M:%SZ")] $*"; }

log "Building weekly memory digest for #daily-brief..."

# Pull all memory types from the vault for the past 7 days
DIGEST=$(python3 - <<PYEOF
import json, sys, os
from pathlib import Path
from datetime import datetime, timezone, timedelta

vault_path = Path("{{TENANT_AGENT_HOME}}/memory/vault.jsonl")
since_dt = datetime.now(timezone.utc) - timedelta(days=7)
type_buckets: dict[str, list[str]] = {}
seen_ids: set[str] = set()

with vault_path.open() as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except:
            continue
        if ev.get("event") != "add":
            continue
        mid = ev.get("id", "")
        if mid in seen_ids:
            continue
        seen_ids.add(mid)
        ts = ev.get("ts") or ev.get("created_at", "")
        try:
            ev_dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except:
            continue
        if ev_dt < since_dt:
            continue
        t = ev.get("type", "other")
        text = ev.get("text", "")[:160]
        type_buckets.setdefault(t, []).append(f"• {text}")

emoji_map = {
    "fact": "🔵", "decision": "🟣", "relationship": "🟢",
    "pattern": "🟠", "commitment": "🔴", "preference": "🔷",
    "goal": "🎯", "context": "⚪", "other": "⬜",
}
order = ["relationship", "commitment", "decision", "fact", "pattern", "preference", "goal", "context"]
lines = []
total = 0
for t in order:
    items = type_buckets.get(t, [])
    if not items:
        continue
    emoji = emoji_map.get(t, "•")
    lines.append(f"**{emoji} {t.capitalize()} ({len(items)})**")
    lines.extend(items[:5])
    if len(items) > 5:
        lines.append(f"  _...and {len(items)-5} more_")
    lines.append("")
    total += len(items)

if not lines:
    print(f"No new memories this week.")
else:
    print(f"**Weekly Memory Digest — {os.environ.get('DATE_LABEL', '')}**")
    print(f"_{total} new memories logged this week_\n")
    print("\n".join(lines))
PYEOF
)

DATE_LABEL="$DATE_LABEL" python3 /dev/stdin <<'PYEOF'
import os
print(os.environ.get("DATE_LABEL", ""))
PYEOF

if [[ -z "$DIGEST" || "$DIGEST" == "No new memories this week." ]]; then
  log "No new memories — posting quiet digest"
  DIGEST="**Weekly Memory Digest — ${DATE_LABEL}**
_No new memories logged this week._"
fi

# Truncate to Discord's 2000 char limit
DIGEST="${DIGEST:0:1950}"

curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$API/channels/$CHANNEL/messages" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$DIGEST")" \
  >/dev/null

log "Digest posted to #daily-brief"
