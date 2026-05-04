#!/usr/bin/env bash
# tg-send.sh — direct Telegram Bot API wrapper
set -euo pipefail

ENV_FILE="{{TENANT_USER_HOME}}/.claude/channels/telegram/.env"
ACCESS_JSON="{{TENANT_USER_HOME}}/.claude/channels/telegram/access.json"
DEFAULT_CHAT="$(jq -r '.allowFrom[0] // empty' "$ACCESS_JSON" 2>/dev/null)"

# shellcheck disable=SC1090
source "$ENV_FILE"
TOKEN="${TELEGRAM_BOT_TOKEN:?token missing}"
API="https://api.telegram.org/bot${TOKEN}"

usage() {
  cat <<EOF
tg-send.sh — Telegram Bot API helper
Default chat: $DEFAULT_CHAT

Subcommands:
  send         --text TEXT [--chat ID] [--md] [--reply-to MSGID]
               [--buttons "L1|URL1,L2|URL2"]                       # url buttons (open externally)
               [--callback-buttons "L1|CB1,L2|CB2"]                # callback_data buttons (in-app)
               [--webapp-buttons "L1|URL1,L2|URL2"]                # web_app buttons (Mini Apps inline)
  send-file    --file PATH [--caption TEXT] [--chat ID] [--md]
  send-voice   --file PATH [--caption TEXT] [--chat ID] [--md] [--reply-to MSGID]
                                                                    # OGG/Opus voice note
                                                                    # (waveform UI on mobile)
  react        --message MSGID --emoji EMOJI [--chat ID]
  edit         --message MSGID --text TEXT [--chat ID] [--md]
  set-commands --commands JSON_ARRAY
  raw          METHOD [--data JSON]

Note: --buttons / --callback-buttons / --webapp-buttons are mutually exclusive.
  url buttons        — open externally (forward dialog on mobile for tg:// scheme).
  callback buttons   — stay in-app, route through server.ts callback_query handler
                       (see v2.22.2 'deploy:' for the established pattern).
  webapp buttons     — open the URL as a Telegram Mini App inline sheet, no
                       browser switch. Telegram WebApp init data is signed by
                       Telegram with the bot token. Server-side validation is
                       optional but recommended for write operations.
EOF
}

cmd="${1:-help}"; shift || true
chat="$DEFAULT_CHAT"; text=""; md=""; reply_to=""; buttons=""; cb_buttons=""; wa_buttons=""; file=""
caption=""; message=""; emoji=""; commands_json=""; data=""; method=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat) chat="$2"; shift 2 ;;
    --text) text="$2"; shift 2 ;;
    --md) md="MarkdownV2"; shift ;;
    --reply-to) reply_to="$2"; shift 2 ;;
    --buttons) buttons="$2"; shift 2 ;;
    --callback-buttons) cb_buttons="$2"; shift 2 ;;
    --webapp-buttons) wa_buttons="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --caption) caption="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --emoji) emoji="$2"; shift 2 ;;
    --commands) commands_json="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    *) method="${method:-$1}"; shift ;;
  esac
done

build_send_payload() {
  local body
  body=$(jq -nc --arg c "$chat" --arg t "$text" '{chat_id:$c, text:$t}')
  [[ -n "$md" ]]       && body=$(echo "$body" | jq -c --arg p "$md" '. + {parse_mode:$p}')
  [[ -n "$reply_to" ]] && body=$(echo "$body" | jq -c --arg r "$reply_to" '. + {reply_to_message_id:($r|tonumber)}')

  # Reject conflicting flags — fail loudly rather than silently picking one.
  local set_count=0
  [[ -n "$buttons" ]]    && set_count=$((set_count+1))
  [[ -n "$cb_buttons" ]] && set_count=$((set_count+1))
  [[ -n "$wa_buttons" ]] && set_count=$((set_count+1))
  if [[ $set_count -gt 1 ]]; then
    echo "ERROR: --buttons, --callback-buttons, --webapp-buttons are mutually exclusive" >&2
    exit 1
  fi

  if [[ -n "$buttons" ]]; then
    # URL buttons. Each button becomes its own row (legacy single-column layout).
    local rows="["; IFS=',' read -ra btns <<< "$buttons"
    for b in "${btns[@]}"; do
      local label="${b%%|*}"; local url="${b#*|}"
      rows+=$(jq -nc --arg l "$label" --arg u "$url" '[{text:$l, url:$u}]')","
    done
    rows="${rows%,}]"
    body=$(echo "$body" | jq -c --argjson kb "{\"inline_keyboard\":$rows}" '. + {reply_markup:$kb}')
  elif [[ -n "$cb_buttons" ]]; then
    # callback_data buttons — pack into ONE row (horizontal pair) for compactness;
    # each button label gets its own callback_data string. Telegram caps each
    # callback_data at 64 bytes (we don't enforce; rely on caller).
    local cells=""; IFS=',' read -ra cbs <<< "$cb_buttons"
    for b in "${cbs[@]}"; do
      local label="${b%%|*}"; local cd="${b#*|}"
      cells+=$(jq -nc --arg l "$label" --arg c "$cd" '{text:$l, callback_data:$c}')","
    done
    cells="${cells%,}"
    body=$(echo "$body" | jq -c --argjson kb "{\"inline_keyboard\":[[$cells]]}" '. + {reply_markup:$kb}')
  elif [[ -n "$wa_buttons" ]]; then
    # web_app buttons — open as Telegram Mini App inline sheet (no browser
    # switch). Each button is one row (full-width). Requires HTTPS URL.
    local rows="["; IFS=',' read -ra wabs <<< "$wa_buttons"
    for b in "${wabs[@]}"; do
      local label="${b%%|*}"; local url="${b#*|}"
      rows+=$(jq -nc --arg l "$label" --arg u "$url" '[{text:$l, web_app:{url:$u}}]')","
    done
    rows="${rows%,}]"
    body=$(echo "$body" | jq -c --argjson kb "{\"inline_keyboard\":$rows}" '. + {reply_markup:$kb}')
  fi
  echo "$body"
}

case "$cmd" in
  send)
    [[ -z "$text" ]] && { echo "missing --text" >&2; exit 1; }
    payload=$(build_send_payload)
    response=$(curl -sS -X POST "$API/sendMessage" -H 'Content-Type: application/json' -d "$payload")
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
      echo "$response" | jq -r '.result.message_id'
    else
      echo "$response" | jq -r '.description // .' >&2; exit 1
    fi
    ;;
  send-file)
    [[ -z "$file" ]] && { echo "missing --file" >&2; exit 1; }
    [[ ! -f "$file" ]] && { echo "file not found: $file" >&2; exit 1; }
    case "$file" in
      *.png|*.jpg|*.jpeg|*.webp|*.gif) endpoint="sendPhoto"; field="photo" ;;
      *.mp4|*.mov|*.webm) endpoint="sendVideo"; field="video" ;;
      *.mp3|*.ogg|*.wav|*.m4a) endpoint="sendAudio"; field="audio" ;;
      *) endpoint="sendDocument"; field="document" ;;
    esac
    extra=(-F "chat_id=$chat" -F "$field=@$file")
    [[ -n "$caption" ]] && extra+=(-F "caption=$caption")
    [[ -n "$md" ]]      && extra+=(-F "parse_mode=$md")
    [[ -n "$reply_to" ]]&& extra+=(-F "reply_to_message_id=$reply_to")
    response=$(curl -sS -X POST "$API/$endpoint" "${extra[@]}")
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
      echo "$response" | jq -r '.result.message_id'
    else
      echo "$response" | jq -r '.description // .' >&2; exit 1
    fi
    ;;
  send-voice)
    # Telegram sendVoice — displays waveform UI in mobile clients.
    # Expects OGG/Opus 16kHz mono. Use voice-reply.sh to synthesize.
    [[ -z "$file" ]] && { echo "missing --file" >&2; exit 1; }
    [[ ! -f "$file" ]] && { echo "file not found: $file" >&2; exit 1; }
    case "$file" in
      *.ogg|*.oga|*.opus) ;;
      *) echo "send-voice expects .ogg/.oga/.opus (Telegram requirement). Got: $file" >&2; exit 1 ;;
    esac
    extra=(-F "chat_id=$chat" -F "voice=@$file")
    [[ -n "$caption" ]] && extra+=(-F "caption=$caption")
    [[ -n "$md" ]]      && extra+=(-F "parse_mode=$md")
    [[ -n "$reply_to" ]]&& extra+=(-F "reply_to_message_id=$reply_to")
    response=$(curl -sS -X POST "$API/sendVoice" "${extra[@]}")
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
      echo "$response" | jq -r '.result.message_id'
    else
      echo "$response" | jq -r '.description // .' >&2; exit 1
    fi
    ;;
  react)
    [[ -z "$message" || -z "$emoji" ]] && { echo "missing args" >&2; exit 1; }
    payload=$(jq -nc --arg c "$chat" --arg m "$message" --arg e "$emoji" \
      '{chat_id:$c, message_id:($m|tonumber), reaction:[{type:"emoji", emoji:$e}]}')
    curl -sS -X POST "$API/setMessageReaction" -H 'Content-Type: application/json' -d "$payload" | jq -r '.ok // .description // .'
    ;;
  edit)
    [[ -z "$message" || -z "$text" ]] && { echo "missing args" >&2; exit 1; }
    body=$(jq -nc --arg c "$chat" --arg m "$message" --arg t "$text" '{chat_id:$c, message_id:($m|tonumber), text:$t}')
    [[ -n "$md" ]] && body=$(echo "$body" | jq -c --arg p "$md" '. + {parse_mode:$p}')
    curl -sS -X POST "$API/editMessageText" -H 'Content-Type: application/json' -d "$body" | jq -r '.result.message_id // .description // .'
    ;;
  set-commands)
    [[ -z "$commands_json" ]] && { echo "missing --commands" >&2; exit 1; }
    payload=$(jq -nc --argjson c "$commands_json" '{commands:$c}')
    curl -sS -X POST "$API/setMyCommands" -H 'Content-Type: application/json' -d "$payload" | jq -r '.ok // .description // .'
    ;;
  raw)
    [[ -z "$method" ]] && { echo "missing METHOD" >&2; exit 1; }
    if [[ -n "$data" ]]; then
      curl -sS -X POST "$API/$method" -H 'Content-Type: application/json' -d "$data"
    else
      curl -sS "$API/$method"
    fi
    ;;
  help|*) usage ;;
esac
