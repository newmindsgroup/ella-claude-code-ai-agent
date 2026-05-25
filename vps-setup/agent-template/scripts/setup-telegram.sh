#!/usr/bin/env bash
# setup-telegram.sh — one command that applies the ENTIRE Telegram configuration
# from the only two things the user has to provide: the BotFather token and their
# own Telegram user_id. Everything else (command menu, description, allowlist,
# callback-routing patches, voice, Mini App) is already in the template.
#
# What it does (all idempotent):
#   1. Writes {{TENANT_USER_HOME}}/.claude/channels/telegram/.env (mode 600) with
#      the bot token — only if missing (never clobbers an existing token).
#   2. Writes .../access.json (mode 600) with your user_id on the allowlist —
#      only if missing (access.json accumulates paired users + is runtime state;
#      we never overwrite it).
#   3. Runs setup-bot-identity.sh → sets the / command menu (31 commands),
#      the About text, the description, and the chat menu button.
#   4. Verifies the token with getMe.
#   5. Prints the ONE step that genuinely needs a human (the pairing handshake).
#
# The callback-routing patches (deploy/draft/prop/forward/email/chat-parity) are
# applied automatically by claude-agent.service ExecStartPre — nothing to do here.
#
# Usage (on the VPS, as {{TENANT_LINUX_USER}}):
#   bash {{TENANT_AGENT_HOME}}/scripts/setup-telegram.sh --token <BOTFATHER_TOKEN> --owner-id <YOUR_USER_ID>
#   bash {{TENANT_AGENT_HOME}}/scripts/setup-telegram.sh    # reuses values already in .env / access.json
set -uo pipefail

USER_HOME="{{TENANT_USER_HOME}}"
AGENT_HOME="{{TENANT_AGENT_HOME}}"
BOT_USERNAME="{{TENANT_TELEGRAM_BOT_USERNAME}}"
TG_DIR="$USER_HOME/.claude/channels/telegram"
ENV_FILE="$TG_DIR/.env"
ACCESS_JSON="$TG_DIR/access.json"

TOKEN=""; OWNER_ID=""; ACK="👀"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)    TOKEN="$2"; shift 2 ;;
    --owner-id) OWNER_ID="$2"; shift 2 ;;
    --ack)      ACK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$TG_DIR"

# ── 1. Token → .env (don't clobber an existing one) ─────────────────────────
if [[ -z "$TOKEN" && -f "$ENV_FILE" ]]; then
  TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi
[[ -z "$TOKEN" ]] && TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  echo "⏳ Telegram NOT configured yet — awaiting the bot token from @BotFather."
  echo "   When you have it, run:"
  echo "     bash $AGENT_HOME/scripts/setup-telegram.sh --token <TOKEN> --owner-id <YOUR_USER_ID>"
  exit 0
fi
if [[ ! -f "$ENV_FILE" ]]; then
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  ✓ wrote $ENV_FILE (mode 600)"
else
  echo "  - $ENV_FILE already exists — left as-is"
fi

API="https://api.telegram.org/bot${TOKEN}"

# ── 2. Owner allowlist → access.json (create only; never overwrite pairings) ─
if [[ -f "$ACCESS_JSON" ]]; then
  echo "  - $ACCESS_JSON already exists — preserved (holds paired users)"
else
  [[ -z "$OWNER_ID" ]] && OWNER_ID="${TELEGRAM_OWNER_USER_ID:-${TELEGRAM_CHAT_ID:-}}"
  if [[ -z "$OWNER_ID" ]]; then
    echo "  ⚠ no --owner-id given and none in env — creating an empty allowlist."
    echo "    You'll pair interactively (step below) or re-run with --owner-id <id>."
    ALLOW="[]"
  else
    ALLOW="[\"$OWNER_ID\"]"
  fi
  cat > "$ACCESS_JSON" <<JSON
{
  "dmPolicy": "allowlist",
  "allowFrom": $ALLOW,
  "groups": {},
  "pending": {},
  "ackReaction": "$ACK"
}
JSON
  chmod 600 "$ACCESS_JSON"
  echo "  ✓ wrote $ACCESS_JSON (mode 600, allowFrom=$ALLOW)"
fi

# ── 3. Verify token ─────────────────────────────────────────────────────────
ME=$(curl -sS --max-time 10 "$API/getMe" 2>/dev/null)
if echo "$ME" | jq -e '.ok' >/dev/null 2>&1; then
  echo "  ✓ token valid — bot is @$(echo "$ME" | jq -r '.result.username')"
else
  echo "  ✗ token rejected by Telegram: $(echo "$ME" | jq -r '.description // .' 2>/dev/null)"
  echo "    Fix the token in $ENV_FILE and re-run."
  exit 1
fi

# ── 4. Apply the bot's public identity (commands / description / menu) ───────
if [[ -x "$AGENT_HOME/scripts/setup-bot-identity.sh" ]]; then
  echo "  applying command menu + description (setup-bot-identity.sh)…"
  bash "$AGENT_HOME/scripts/setup-bot-identity.sh" 2>&1 | sed 's/^/    /'
else
  echo "  ⚠ setup-bot-identity.sh not found — command menu not set"
fi

# ── 5. The one genuinely-manual step ────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " Telegram is configured. ONE interactive step remains (needs a human):"
echo "════════════════════════════════════════════════════════════════════"
echo " 1. Make sure claude-agent is running:  systemctl start claude-agent.service"
echo " 2. In the agent's Claude Code session, install + configure the plugin:"
echo "      /plugin install telegram@claude-plugins-official"
echo "      /telegram:configure $TOKEN"
echo " 3. DM @${BOT_USERNAME} anything → you'll get a 6-char pairing code."
echo " 4. Approve it:  /telegram:access pair <code>   then   /telegram:access policy allowlist"
echo ""
echo " After that, DM the bot — it should reply within ~30s. Everything else"
echo " (commands, voice, callback buttons, Mini App dashboard) already works."
