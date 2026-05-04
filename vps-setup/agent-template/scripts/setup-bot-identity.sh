#!/usr/bin/env bash
# setup-bot-identity.sh — idempotently configures the Telegram bot's
# public identity: command menu, description, short description, and
# chat menu button.
#
# Run any time to refresh. Safe to re-run — every call sets state to
# what's defined here. There's no incremental mode; this is the source
# of truth for the bot's public presentation.
#
# Usage:
#   bash {{TENANT_AGENT_HOME}}/scripts/setup-bot-identity.sh
#
# Adds new fields the agent already supports but Telegram doesn't know
# about yet:
#   - /voice command (voice mode preference, off|reply|always)
#   - /status command (stack health snapshot, was already wired in CLAUDE.md)
#   - /diag command (diagnostic dump, was already wired in CLAUDE.md)
#
# Sets the About text + Description so anyone opening the bot for the
# first time sees a clear "what is this" instead of a blank profile.
set -euo pipefail

ENV_FILE="{{TENANT_USER_HOME}}/.claude/channels/telegram/.env"
# shellcheck disable=SC1090
source "$ENV_FILE"
TOKEN="${TELEGRAM_BOT_TOKEN:?token missing}"
API="https://api.telegram.org/bot${TOKEN}"

# About text (≤120 chars) — shown on the bot's profile page
SHORT_DESC="{{TENANT_PERSON_FIRST_NAME}}'s personal chief-of-staff. Voice + text. Pipeline, calendar, drafts, daily brief."

# Description (≤512 chars) — shown when opening a new chat with the bot
DESC=$(cat <<EOF
Direct line to {{TENANT_PERSON_FIRST_NAME}}'s autonomous AI agent stack.

I run the morning brief, route inbound, draft replies and posts, scan the pipeline, and surface stalled deals. Send a voice note in English or Spanish — I'll transcribe, reply in text, and reply in voice.

Tap the menu icon (left of the input field) for the full command list.
EOF
)

# Commands shown in the / menu. Order matters: most-used first.
COMMANDS=$(cat <<'JSON'
[
  {"command":"brief",         "description":"Morning brief — fire it now"},
  {"command":"dashboard",     "description":"Mission Control — opens inline as Mini App"},
  {"command":"queue",         "description":"Drafts + proposals awaiting your tap"},
  {"command":"tasks",         "description":"Open tasks by state"},
  {"command":"goals",         "description":"Goals + progress bars"},
  {"command":"calendar",      "description":"Today and tomorrow"},
  {"command":"pipeline",      "description":"Pipeline state and stalled deals"},
  {"command":"inbox",         "description":"High-priority inbound"},
  {"command":"drafts",        "description":"Pending drafts ready to ship"},
  {"command":"voice",         "description":"Voice mode — off | reply | always"},
  {"command":"status",        "description":"Stack health + today's spend + savings"},
  {"command":"diag",          "description":"Diagnostic dump (heavy — use when stuck)"},
  {"command":"goal_add",      "description":"Add a goal — /goal_add <summary> by <date>"},
  {"command":"goal_progress", "description":"Update progress — /goal_progress g-XXXX <value>"},
  {"command":"done",          "description":"Mark task done — /done t-XXXX"},
  {"command":"cancel",        "description":"Cancel task — /cancel t-XXXX"},
  {"command":"extend",        "description":"Push deadline — /extend t-XXXX 2026-05-15"},
  {"command":"draft",         "description":"Quick draft — /draft [linkedin|email|sms] <topic>"},
  {"command":"research",      "description":"Research a person or company"},
  {"command":"find_time",     "description":"Find calendar slots — /find_time <duration> <description>"},
  {"command":"book",          "description":"Book a proposed slot — /book <slot number>"},
  {"command":"memories",      "description":"What I remember about you"},
  {"command":"remember",      "description":"Save next message as a memory"},
  {"command":"forget",        "description":"Forget a memory — /forget m-XXXX"},
  {"command":"who",           "description":"Knowledge graph — /who <name or topic>"},
  {"command":"improve",       "description":"Self-improvement — /improve list | apply <id>"},
  {"command":"scan",          "description":"Brand drift scan"},
  {"command":"deploy",        "description":"Deploy a release — /deploy v2.X.Y"}
]
JSON
)

curl_check() {
  local resp="$1"
  local label="$2"
  if echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label — $(echo "$resp" | jq -r '.description // .')"
    return 1
  fi
}

echo "Setting bot identity for $({ curl -s "$API/getMe" | jq -r '.result.username'; })..."

# 1. Commands
RESP=$(curl -sS -X POST "$API/setMyCommands" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson c "$COMMANDS" '{commands:$c}')")
curl_check "$RESP" "setMyCommands (${COUNT:-$(echo "$COMMANDS" | jq 'length')} commands)"

# 2. Short description (the "about" line on the bot's profile)
RESP=$(curl -sS -X POST "$API/setMyShortDescription" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg d "$SHORT_DESC" '{short_description:$d}')")
curl_check "$RESP" "setMyShortDescription"

# 3. Description (full intro shown in empty chats)
RESP=$(curl -sS -X POST "$API/setMyDescription" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg d "$DESC" '{description:$d}')")
curl_check "$RESP" "setMyDescription"

# 4. Chat menu button — ensure it's set to "commands" so tapping the
#    menu icon next to the input field shows the / menu. Telegram's
#    default for new bots can be empty; explicit set is idempotent.
RESP=$(curl -sS -X POST "$API/setChatMenuButton" \
  -H 'Content-Type: application/json' \
  -d '{"menu_button":{"type":"commands"}}')
curl_check "$RESP" "setChatMenuButton (type=commands)"

echo ""
echo "Done. Verify by closing + reopening the chat with @{{TENANT_TELEGRAM_BOT_USERNAME}}."
