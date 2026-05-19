#!/usr/bin/env bash
# Community-Corpus Bridge — reads messages in Discord memory channels that were
# typed manually by humans (not posted by the bot), and saves them to memory-vault.
#
# This makes Discord a memory INPUT, not just output. Daniel can type a fact,
# relationship note, or decision directly in any #memory-* channel and the agent
# will learn it on the next sync (runs every 10 minutes via cron).
#
# Usage: discord-corpus-sync.sh [--dry-run]

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

API="https://discord.com/api/v10"
AUTH="Authorization: Bot $DISCORD_BOT_TOKEN"
STATE_FILE="{{TENANT_AGENT_HOME}}/data/discord-corpus-last.json"
DRY_RUN="${1:-}"
LOG_PREFIX="[discord-corpus-sync]"

mkdir -p "$(dirname "$STATE_FILE")"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

# Channel → memory type mapping
declare -A CHANNEL_MAP=(
  ["$DISCORD_CH_FACTS"]="fact"
  ["$DISCORD_CH_DECISIONS"]="decision"
  ["$DISCORD_CH_RELATIONSHIPS"]="relationship"
  ["$DISCORD_CH_PATTERNS"]="pattern"
  ["$DISCORD_CH_COMMITMENTS"]="commitment"
  ["$DISCORD_CH_PREFERENCES"]="preference"
)

BOT_ID=$(curl -s -H "$AUTH" "$API/users/@me" | jq -r '.id')
NEW_COUNT=0

for CHANNEL_ID in "${!CHANNEL_MAP[@]}"; do
  MEM_TYPE="${CHANNEL_MAP[$CHANNEL_ID]}"
  LAST_ID=$(jq -r --arg ch "$CHANNEL_ID" '.[$ch] // ""' "$STATE_FILE")

  # Fetch new messages since last sync
  if [[ -n "$LAST_ID" ]]; then
    MESSAGES=$(curl -s -H "$AUTH" "$API/channels/$CHANNEL_ID/messages?after=$LAST_ID&limit=50")
  else
    # First run — fetch last 50, don't import them (just set the cursor)
    MESSAGES=$(curl -s -H "$AUTH" "$API/channels/$CHANNEL_ID/messages?limit=50")
    LATEST_ID=$(echo "$MESSAGES" | jq -r 'if length > 0 then .[0].id else "" end')
    if [[ -n "$LATEST_ID" ]]; then
      TMP=$(mktemp); jq --arg ch "$CHANNEL_ID" --arg id "$LATEST_ID" '.[$ch] = $id' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
    fi
    echo "$LOG_PREFIX initialized cursor for $MEM_TYPE channel ($CHANNEL_ID)"
    continue
  fi

  # Process messages oldest-first; skip bot messages and embed-only messages
  echo "$MESSAGES" | jq -r 'reverse | .[] | @base64' | while read -r encoded; do
    MSG=$(echo "$encoded" | base64 -d)
    MSG_ID=$(echo "$MSG" | jq -r '.id')
    AUTHOR_ID=$(echo "$MSG" | jq -r '.author.id')
    CONTENT=$(echo "$MSG" | jq -r '.content // ""')

    # Update cursor regardless
    TMP=$(mktemp); jq --arg ch "$CHANNEL_ID" --arg id "$MSG_ID" '.[$ch] = $id' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"

    # Skip bot's own messages
    [[ "$AUTHOR_ID" == "$BOT_ID" ]] && continue
    # Skip empty or very short messages
    [[ ${#CONTENT} -lt 10 ]] && continue

    echo "$LOG_PREFIX new human message in $MEM_TYPE: ${CONTENT:0:80}..."

    if [[ "$DRY_RUN" != "--dry-run" ]]; then
      bash {{TENANT_AGENT_HOME}}/scripts/memory-vault.sh add \
        --type "$MEM_TYPE" \
        --text "$CONTENT" \
        --tags "discord-input,human" \
        --source "discord-corpus" \
        --confidence 0.9 >/dev/null
      NEW_COUNT=$((NEW_COUNT + 1))
    fi
  done
done

if [[ $NEW_COUNT -gt 0 ]]; then
  bash {{TENANT_AGENT_HOME}}/scripts/discord-memory.sh log \
    --channel agent-log \
    --text "Corpus sync: imported $NEW_COUNT new human messages from Discord memory channels → memory-vault" &>/dev/null
fi

echo "$LOG_PREFIX done. $NEW_COUNT new memories imported."
