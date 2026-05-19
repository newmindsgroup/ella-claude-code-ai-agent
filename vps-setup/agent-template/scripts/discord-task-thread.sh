#!/usr/bin/env bash
# Creates and updates per-task Discord threads in #task-events.
# Usage:
#   discord-task-thread.sh create --id t-XXXX --summary "text" [--owner "name"] [--deadline "date"]
#   discord-task-thread.sh update --id t-XXXX --state "in_progress" --msg "note"
#   discord-task-thread.sh get-thread --id t-XXXX   (returns Discord thread ID or empty)

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

API="https://discord.com/api/v10"
AUTH="Authorization: Bot $DISCORD_BOT_TOKEN"
CHANNEL="$DISCORD_CH_TASK_EVENTS"
THREAD_MAP="{{TENANT_AGENT_HOME}}/data/discord-task-threads.json"

# Ensure thread map exists
mkdir -p "$(dirname "$THREAD_MAP")"
[[ -f "$THREAD_MAP" ]] || echo '{}' > "$THREAD_MAP"

STATE_EMOJI() {
  case "$1" in
    proposed)          echo "✏️" ;;
    committed)         echo "📌" ;;
    in_progress)       echo "🔧" ;;
    awaiting_review)   echo "👀" ;;
    awaiting_external) echo "⏳" ;;
    blocked)           echo "🚧" ;;
    done)              echo "✅" ;;
    cancelled)         echo "✖️" ;;
    stale)             echo "🕐" ;;
    *)                 echo "•"  ;;
  esac
}

_post_message() {
  local channel_id=$1 content=$2
  curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$API/channels/$channel_id/messages" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$content")" \
    | jq -r '.id // ""'
}

_get_thread_id() {
  local task_id=$1
  jq -r --arg id "$task_id" '.[$id] // ""' "$THREAD_MAP"
}

_save_thread_id() {
  local task_id=$1 thread_id=$2
  local tmp; tmp=$(mktemp)
  jq --arg k "$task_id" --arg v "$thread_id" '.[$k] = $v' "$THREAD_MAP" > "$tmp" && mv "$tmp" "$THREAD_MAP"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  create)
    TASK_ID="" SUMMARY="" OWNER="" DEADLINE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id)       TASK_ID="$2";  shift 2 ;;
        --summary)  SUMMARY="$2";  shift 2 ;;
        --owner)    OWNER="$2";    shift 2 ;;
        --deadline) DEADLINE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -z "$TASK_ID" ]] && { echo "missing --id"; exit 1; }

    # Check if thread already exists
    EXISTING=$(_get_thread_id "$TASK_ID")
    [[ -n "$EXISTING" ]] && { echo "thread:$EXISTING"; exit 0; }

    # Post starter message and create thread
    STARTER_TEXT="📌 **$TASK_ID** — $SUMMARY"
    STARTER_MSG_ID=$(_post_message "$CHANNEL" "$STARTER_TEXT")
    [[ -z "$STARTER_MSG_ID" ]] && { echo "error: could not post starter message"; exit 1; }

    # Create thread from the message
    THREAD_BODY=$(python3 -c "import json; print(json.dumps({'name': '$TASK_ID — ${SUMMARY:0:50}', 'auto_archive_duration': 10080}))")
    THREAD_ID=$(curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
      "$API/channels/$CHANNEL/messages/$STARTER_MSG_ID/threads" \
      -d "$THREAD_BODY" | jq -r '.id // ""')

    [[ -z "$THREAD_ID" ]] && { echo "error: could not create thread"; exit 1; }
    _save_thread_id "$TASK_ID" "$THREAD_ID"

    # Post details into thread
    DETAILS="**Owner:** ${OWNER:-agent}"
    [[ -n "$DEADLINE" ]] && DETAILS="$DETAILS\n**Due:** $DEADLINE"
    _post_message "$THREAD_ID" "$DETAILS" >/dev/null

    echo "thread:$THREAD_ID"
    ;;

  update)
    TASK_ID="" STATE="" MSG=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id)    TASK_ID="$2"; shift 2 ;;
        --state) STATE="$2";   shift 2 ;;
        --msg)   MSG="$2";     shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -z "$TASK_ID" ]] && { echo "missing --id"; exit 1; }

    THREAD_ID=$(_get_thread_id "$TASK_ID")
    [[ -z "$THREAD_ID" ]] && { echo "no thread for $TASK_ID"; exit 0; }

    EMOJI=$(STATE_EMOJI "$STATE")
    TIMESTAMP=$(date -u +"%H:%M UTC")
    TEXT="$EMOJI **$STATE** at $TIMESTAMP"
    [[ -n "$MSG" ]] && TEXT="$TEXT — $MSG"
    _post_message "$THREAD_ID" "$TEXT" >/dev/null
    echo "ok"
    ;;

  get-thread)
    TASK_ID=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --id) TASK_ID="$2"; shift 2 ;; *) shift ;; esac
    done
    _get_thread_id "$TASK_ID"
    ;;

  *)
    echo "Usage: discord-task-thread.sh <create|update|get-thread> [options]"
    exit 1
    ;;
esac
