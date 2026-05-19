#!/usr/bin/env bash
# Discord memory mirror — posts memory entries to the relevant Discord channel with rich embeds.
# Usage:
#   discord-memory.sh post --type <fact|decision|relationship|pattern|commitment|preference> --text "<text>" [--tags "<tags>"] [--id "<memory-id>"]
#   discord-memory.sh log --channel <agent-log|task-events|intel|ghl-activity|gmail-alerts|daily-brief|commands> --text "<text>"
#   discord-memory.sh search --type <type> --query "<text>"
#   discord-memory.sh notify --channel <name> --title "<title>" --text "<text>" [--color <hex>] [--url "<url>"]
#   discord-memory.sh client-thread --name "<client name>" --company "<company>" --text "<first entry>"

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

API="https://discord.com/api/v10"
AUTH="Authorization: Bot $DISCORD_BOT_TOKEN"

# Embed colors by memory type
_color_for_type() {
  case "$1" in
    fact)         echo "3447003"  ;; # blue
    decision)     echo "10181046" ;; # purple
    relationship) echo "3066993"  ;; # green
    pattern)      echo "15105570" ;; # orange
    commitment)   echo "15158332" ;; # red
    preference)   echo "1752220"  ;; # teal
    *)            echo "9807270"  ;; # grey
  esac
}

_channel_for_type() {
  case "$1" in
    fact)         echo "$DISCORD_CH_FACTS" ;;
    decision)     echo "$DISCORD_CH_DECISIONS" ;;
    relationship) echo "$DISCORD_CH_RELATIONSHIPS" ;;
    pattern)      echo "$DISCORD_CH_PATTERNS" ;;
    commitment)   echo "$DISCORD_CH_COMMITMENTS" ;;
    preference)   echo "$DISCORD_CH_PREFERENCES" ;;
    *)            echo "" ;;
  esac
}

_channel_for_ops() {
  case "$1" in
    agent-log)    echo "$DISCORD_CH_AGENT_LOG" ;;
    task-events)  echo "$DISCORD_CH_TASK_EVENTS" ;;
    intel)        echo "$DISCORD_CH_INTEL" ;;
    commands)     echo "$DISCORD_CH_COMMANDS" ;;
    daily-brief)  echo "$DISCORD_CH_DAILY_BRIEF" ;;
    ghl-activity) echo "$DISCORD_CH_GHL_ACTIVITY" ;;
    gmail-alerts) echo "$DISCORD_CH_GMAIL_ALERTS" ;;
    *)            echo "" ;;
  esac
}

_json_str() {
  python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))"
}

_post_embed() {
  local channel_id=$1
  local payload=$2
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$API/channels/$channel_id/messages" \
    -d "$payload" | jq -r '.id // "error"'
}

_post_message() {
  local channel_id=$1
  local content=$2
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$content")
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$API/channels/$channel_id/messages" \
    -d "$payload" | jq -r '.id // "error"'
}

cmd="${1:-}"
shift || true

case "$cmd" in
  post)
    TYPE="" TEXT="" TAGS="" ID=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --text) TEXT="$2"; shift 2 ;;
        --tags) TAGS="$2"; shift 2 ;;
        --id)   ID="$2";   shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$(_channel_for_type "$TYPE")
    [[ -z "$CHANNEL" ]] && { echo "Unknown type: $TYPE"; exit 1; }
    COLOR=$(_color_for_type "$TYPE")
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TITLE=$(echo "$TYPE" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
    # Build embed payload
    PAYLOAD=$(python3 - <<PYEOF
import json
title = "$TITLE"
desc = """$TEXT"""
color = $COLOR
ts = "$TIMESTAMP"
mem_id = "$ID"
tags = "$TAGS"
fields = []
if mem_id:
    fields.append({"name": "ID", "value": f"\`{mem_id}\`", "inline": True})
if tags:
    fields.append({"name": "Tags", "value": tags, "inline": True})
embed = {"title": title, "description": desc, "color": color, "timestamp": ts, "fields": fields}
print(json.dumps({"embeds": [embed]}))
PYEOF
)
    MSG_ID=$(_post_embed "$CHANNEL" "$PAYLOAD")
    echo "posted:$MSG_ID"
    ;;

  log)
    CHANNEL_NAME="" TEXT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --channel) CHANNEL_NAME="$2"; shift 2 ;;
        --text)    TEXT="$2";         shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$(_channel_for_ops "$CHANNEL_NAME")
    [[ -z "$CHANNEL" ]] && { echo "Unknown channel: $CHANNEL_NAME"; exit 1; }
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    MSG="**[$TIMESTAMP]** $TEXT"
    MSG_ID=$(_post_message "$CHANNEL" "$MSG")
    echo "posted:$MSG_ID"
    ;;

  notify)
    # Rich notification embed — for GHL/Gmail/external service alerts
    CHANNEL_NAME="" TITLE="" TEXT="" COLOR="9807270" URL=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --channel) CHANNEL_NAME="$2"; shift 2 ;;
        --title)   TITLE="$2";        shift 2 ;;
        --text)    TEXT="$2";         shift 2 ;;
        --color)   COLOR="$2";        shift 2 ;;
        --url)     URL="$2";          shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$(_channel_for_ops "$CHANNEL_NAME")
    [[ -z "$CHANNEL" ]] && CHANNEL=$(_channel_for_type "$CHANNEL_NAME")
    [[ -z "$CHANNEL" ]] && { echo "Unknown channel: $CHANNEL_NAME"; exit 1; }
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    PAYLOAD=$(python3 - <<PYEOF
import json
title = """$TITLE"""
desc = """$TEXT"""
color = $COLOR
ts = "$TIMESTAMP"
url = "$URL"
embed = {"title": title, "description": desc, "color": color, "timestamp": ts}
if url:
    embed["url"] = url
print(json.dumps({"embeds": [embed]}))
PYEOF
)
    MSG_ID=$(_post_embed "$CHANNEL" "$PAYLOAD")
    echo "posted:$MSG_ID"
    ;;

  client-thread)
    # Create or find a thread in #memory-relationships for a specific client
    NAME="" COMPANY="" TEXT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)    NAME="$2";    shift 2 ;;
        --company) COMPANY="$2"; shift 2 ;;
        --text)    TEXT="$2";    shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$DISCORD_CH_RELATIONSHIPS
    THREAD_NAME="${NAME}$([ -n "$COMPANY" ] && echo " — $COMPANY" || echo "")"
    # Check for existing thread
    EXISTING=$(curl -s -H "$AUTH" \
      "$API/channels/$CHANNEL/threads/search?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$THREAD_NAME'))")" \
      2>/dev/null | jq -r '.threads[0].id // ""' 2>/dev/null || echo "")
    if [[ -n "$EXISTING" ]]; then
      THREAD_ID="$EXISTING"
    else
      # Create new thread from a starter message
      STARTER_MSG_ID=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
        "$API/channels/$CHANNEL/messages" \
        -d "$(python3 -c "import json; print(json.dumps({'content': '📁 **' + '$THREAD_NAME' + '**'}))")" \
        | jq -r '.id')
      THREAD_ID=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
        "$API/channels/$CHANNEL/messages/$STARTER_MSG_ID/threads" \
        -d "$(python3 -c "import json; print(json.dumps({'name': '$THREAD_NAME', 'auto_archive_duration': 10080}))")" \
        | jq -r '.id')
    fi
    # Post entry into the thread
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    _post_message "$THREAD_ID" "[$TIMESTAMP] $TEXT" >/dev/null
    echo "thread:$THREAD_ID"
    ;;

  search)
    TYPE="" QUERY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type)  TYPE="$2";  shift 2 ;;
        --query) QUERY="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$(_channel_for_type "$TYPE")
    [[ -z "$CHANNEL" ]] && { echo "Unknown type: $TYPE"; exit 1; }
    curl -s -H "$AUTH" \
      "$API/channels/$CHANNEL/messages?limit=100" \
      | jq -r '.[].embeds[0].description // .[].content' | grep -i "$QUERY" | head -20 || echo "(no matches)"
    ;;

  draft-ready)
    # Mirror draft-ready notification to #commands so Daniel can approve from Discord too.
    # Usage: draft-ready --task-id t-XXXX --platform "LinkedIn" --topic "AI topic"
    TASK_ID="" PLATFORM="" TOPIC=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --task-id)  TASK_ID="$2";   shift 2 ;;
        --platform) PLATFORM="$2";  shift 2 ;;
        --topic)    TOPIC="$2";     shift 2 ;;
        *) shift ;;
      esac
    done
    CHANNEL=$DISCORD_CH_COMMANDS
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    PAYLOAD=$(python3 - <<PYEOF
import json
task_id = "$TASK_ID"
platform = "$PLATFORM"
topic = "$TOPIC"
desc = f"**Platform:** {platform}\n**Topic:** {topic}\n\nTo approve from Discord, type:\n\`ship {task_id}\` — approve and ship\n\`hold {task_id}\` — hold for later\n\`revise {task_id} <feedback>\` — send back with notes"
embed = {"title": f"📝 Draft ready — {platform}", "description": desc, "color": 3447003, "timestamp": "$TIMESTAMP",
         "fields": [{"name": "Task ID", "value": f"\`{task_id}\`", "inline": True}]}
print(json.dumps({"embeds": [embed]}))
PYEOF
)
    MSG_ID=$(_post_embed "$CHANNEL" "$PAYLOAD")
    echo "posted:$MSG_ID"
    ;;

  *)
    echo "Usage: discord-memory.sh <post|log|notify|client-thread|draft-ready|search> [options]"
    exit 1
    ;;
esac
