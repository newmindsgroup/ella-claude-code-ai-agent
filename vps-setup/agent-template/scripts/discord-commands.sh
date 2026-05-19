#!/usr/bin/env bash
# Discord command poller — reads #commands channel, routes to agent CLI, posts result back.
# Run as a cron job every 60 seconds.
# Tracks last-processed message ID in /tmp/discord-cmd-last.txt to avoid reprocessing.
# Also polls watched channels for edits and logs pattern memories.

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

API="https://discord.com/api/v10"
AUTH="Authorization: Bot $DISCORD_BOT_TOKEN"
CHANNEL="$DISCORD_CH_COMMANDS"
STATE_FILE="/tmp/discord-cmd-last.txt"
AGENT_DIR="{{TENANT_AGENT_HOME}}"
SCRIPTS="$AGENT_DIR/scripts"

_post() {
  local ch=$1 body=$2
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$API/channels/$ch/messages" -d "$body" >/dev/null
}

_post_text() {
  local ch=$1 text=$2
  _post "$ch" "$(python3 -c "import json,sys; print(json.dumps({'content':sys.argv[1]}))" "$text")"
}

# ── Load last processed message ID ───────────────────────────────────────────

LAST_ID=""
[[ -f "$STATE_FILE" ]] && LAST_ID=$(cat "$STATE_FILE")

# ── Fetch new messages ────────────────────────────────────────────────────────

if [[ -n "$LAST_ID" ]]; then
  MESSAGES=$(curl -s -H "$AUTH" \
    "$API/channels/$CHANNEL/messages?after=$LAST_ID&limit=10")
else
  LATEST=$(curl -s -H "$AUTH" "$API/channels/$CHANNEL/messages?limit=1")
  LATEST_ID=$(echo "$LATEST" | jq -r '.[0].id // ""')
  [[ -n "$LATEST_ID" ]] && echo "$LATEST_ID" > "$STATE_FILE"
  exit 0
fi

# ── Edit detection — watch #commands for changed messages ────────────────────
# Cache recent bot-sent message content; when a human edits their own message,
# the diff is logged as a pattern memory via signal-edit.sh.

EDIT_CACHE="/tmp/discord-edit-cache.json"
[[ -f "$EDIT_CACHE" ]] || echo '{}' > "$EDIT_CACHE"

RECENT_MSGS=$(curl -s -H "$AUTH" "$API/channels/$CHANNEL/messages?limit=20")
echo "$RECENT_MSGS" | jq -c '.[] | select(.author.bot == false and .edited_timestamp != null)' | while read -r emsg; do
  EMSG_ID=$(echo "$emsg" | jq -r '.id')
  EMSG_CONTENT=$(echo "$emsg" | jq -r '.content')
  EMSG_EDITED=$(echo "$emsg" | jq -r '.edited_timestamp')
  CACHED=$(jq -r --arg id "$EMSG_ID" '.[$id].content // ""' "$EDIT_CACHE")
  CACHED_TS=$(jq -r --arg id "$EMSG_ID" '.[$id].edited // ""' "$EDIT_CACHE")

  # New edit we haven't seen yet
  if [[ "$EMSG_EDITED" != "$CACHED_TS" && -n "$EMSG_CONTENT" ]]; then
    if [[ -n "$CACHED" && "$CACHED" != "$EMSG_CONTENT" ]]; then
      # Log as pattern memory — the diff is the signal
      SIGNAL_TEXT="Discord edit detected: was \"${CACHED:0:200}\" → now \"${EMSG_CONTENT:0:200}\""
      bash "$SCRIPTS/signal-edit.sh" --text "$SIGNAL_TEXT" &>/dev/null &
      _post_text "$CHANNEL" "🧠 *Pattern logged* — edit on your message treated as a learning signal." &
    fi
    # Update cache
    TMP=$(mktemp)
    jq --arg id "$EMSG_ID" --arg c "$EMSG_CONTENT" --arg ts "$EMSG_EDITED" \
      '.[$id] = {content: $c, edited: $ts}' "$EDIT_CACHE" > "$TMP" && mv "$TMP" "$EDIT_CACHE"
  fi
done

# ── Process each new message ─────────────────────────────────────────────────

echo "$MESSAGES" | jq -r 'reverse | .[] | @base64' | while read -r encoded; do
  MSG=$(echo "$encoded" | base64 -d)
  MSG_ID=$(echo "$MSG" | jq -r '.id')
  AUTHOR_BOT=$(echo "$MSG" | jq -r '.author.bot // false')
  CONTENT=$(echo "$MSG" | jq -r '.content')

  # Skip bot messages
  [[ "$AUTHOR_BOT" == "true" ]] && { echo "$MSG_ID" > "$STATE_FILE"; continue; }

  # --- Draft approval shortcuts (ship/hold/revise t-XXXX) ---
  if [[ "$CONTENT" =~ ^(ship|hold|revise|cancel)[[:space:]]+(t-[0-9]+-[a-f0-9]+) ]]; then
    ACTION="${BASH_REMATCH[1]}"
    TASK_ID="${BASH_REMATCH[2]}"
    _post_text "$CHANNEL" "⏳ Processing \`$ACTION\` for \`$TASK_ID\`..."
    RESULT=$(cd "$AGENT_DIR" && timeout 60 claude --print "$ACTION $TASK_ID" 2>/dev/null | tail -c 1800 || echo "(timed out)")
    _post_text "$CHANNEL" "✅ **$ACTION** \`$TASK_ID\` — $RESULT"

  # --- !memory <query> — fast vault recall without the agent ---------------
  elif [[ "$CONTENT" =~ ^!memory[[:space:]](.+) ]]; then
    QUERY="${BASH_REMATCH[1]}"
    _post_text "$CHANNEL" "🔍 Searching memory for: *${QUERY}*..."
    RESULT=$(bash "$SCRIPTS/memory-vault.sh" recall --query "$QUERY" --limit 8 2>/dev/null \
      | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin)
    if not items:
        print('(no matches)')
    else:
        for it in items[:6]:
            print(f'**[{it[\"type\"]}]** {it[\"text\"][:200]}')
            print(f'  _ID: {it[\"id\"]} · tags: {it.get(\"tags\",[])}_ ')
            print()
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null || echo "(recall failed)")
    RESULT_TRUNCATED="${RESULT:0:1800}"
    _post_text "$CHANNEL" "**Memory — ${QUERY}**
${RESULT_TRUNCATED}"

  # --- !remind <text> in <N> <unit> — create a timed task reminder ----------
  elif [[ "$CONTENT" =~ ^!remind[[:space:]](.+)[[:space:]]in[[:space:]]([0-9]+)[[:space:]]?(min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days) ]]; then
    REMIND_TEXT="${BASH_REMATCH[1]}"
    REMIND_QTY="${BASH_REMATCH[2]}"
    REMIND_UNIT="${BASH_REMATCH[3]}"
    # Compute deadline
    case "$REMIND_UNIT" in
      min|mins|minute|minutes) DEADLINE=$(date -d "+${REMIND_QTY} minutes" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -v+${REMIND_QTY}M +"%Y-%m-%dT%H:%M:%S") ;;
      h|hr|hrs|hour|hours)     DEADLINE=$(date -d "+${REMIND_QTY} hours"   +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -v+${REMIND_QTY}H +"%Y-%m-%dT%H:%M:%S") ;;
      d|day|days)              DEADLINE=$(date -d "+${REMIND_QTY} days"    +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -v+${REMIND_QTY}d +"%Y-%m-%dT%H:%M:%S") ;;
    esac
    TASK_ID=$(bash "$SCRIPTS/task-ledger.sh" create \
      --summary "REMINDER: $REMIND_TEXT" \
      --deadline "$DEADLINE" \
      --owner "{{TENANT_PERSON_FIRST_NAME}}" \
      --source "discord-remind" \
      --loud true 2>/dev/null | tail -1)
    _post_text "$CHANNEL" "⏰ Reminder set — **$REMIND_TEXT** · due \`$DEADLINE\` · task \`$TASK_ID\`"

  # --- !signal <text> — log a pattern memory directly from Discord ----------
  elif [[ "$CONTENT" =~ ^!signal[[:space:]](.+) ]]; then
    SIGNAL_TEXT="${BASH_REMATCH[1]}"
    MEM_ID=$(bash "$SCRIPTS/signal-edit.sh" --text "$SIGNAL_TEXT" 2>/dev/null | grep -oE 'm-[0-9]+-[a-f0-9]+' | head -1 || echo "")
    _post_text "$CHANNEL" "🧠 Pattern logged${MEM_ID:+ — \`$MEM_ID\`}: $SIGNAL_TEXT"

  # --- /search <term> — fast unified vault + history search ----------------
  elif [[ "$CONTENT" =~ ^/search[[:space:]](.+) ]]; then
    SEARCH_TERM="${BASH_REMATCH[1]}"
    _post_text "$CHANNEL" "🔍 Searching for: **${SEARCH_TERM}**..."
    RESULT=$(bash "$SCRIPTS/search.sh" "$SEARCH_TERM" 2>/dev/null | head -60 || echo "(search failed)")
    RESULT_TRUNCATED="${RESULT:0:1900}"
    _post_text "$CHANNEL" "**Search — ${SEARCH_TERM}**
\`\`\`
$RESULT_TRUNCATED
\`\`\`"

  # --- /slash commands routed to agent -------------------------------------
  elif [[ "$CONTENT" =~ ^/(brief|tasks|queue|goals|pipeline|status|diag|inbox|memories|recall|who|drafts|memory) ]]; then
    CMD="${CONTENT#/}"

    _post_text "$CHANNEL" "⏳ Running \`/${CMD%% *}\`..."

    RESULT=$(cd "$AGENT_DIR" && \
      timeout 60 claude --print "/$CMD" 2>/dev/null | tail -c 1800 || echo "(command timed out or failed)")

    RESULT_TRUNCATED="${RESULT:0:1900}"
    _post_text "$CHANNEL" "**/$CMD**
\`\`\`
$RESULT_TRUNCATED
\`\`\`"
  fi

  echo "$MSG_ID" > "$STATE_FILE"
done
