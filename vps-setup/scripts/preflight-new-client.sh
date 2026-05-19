#!/usr/bin/env bash
# preflight-new-client.sh — validate every external dependency works
# BEFORE starting a fresh-client deploy. If anything fails here, fix it
# and re-run. Nothing in this script mutates state.
#
# USAGE:
#   bash preflight-new-client.sh <path-to-client-credentials.md>
#
# READS the YAML blocks inside the markdown file (each block fenced with
# ```yaml) and tests each external service for reachability + auth.
#
# Exit code:
#   0 = all checks passed, safe to start deploy
#   1 = at least one check failed, deploy must NOT proceed
set -uo pipefail

CREDS="${1:-}"
[[ -z "$CREDS" ]] && { echo "usage: $0 <path-to-client-credentials.md>" >&2; exit 1; }
[[ ! -f "$CREDS" ]] && { echo "ERROR: $CREDS not found" >&2; exit 1; }

PASS=0
FAIL=0
WARN=0
ISSUES=()
ok()    { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); ISSUES+=("FAIL: $1"); }
warn()  { echo "  ⚠ $1"; WARN=$((WARN+1)); ISSUES+=("WARN: $1"); }
section() { echo; echo "═══ $1 ═══"; }

# ── Extract YAML values from the markdown via a tiny Python helper ─────────
yget() {
  python3 - "$CREDS" "$1" <<'PYEOF'
import sys, re, yaml
md = open(sys.argv[1]).read()
key = sys.argv[2]
# Collect content of every ```yaml ... ``` block
blocks = re.findall(r'```yaml\n(.*?)```', md, re.DOTALL)
for block in blocks:
    # strip inline comments + trailing whitespace
    cleaned = re.sub(r'(?m)#.*$', '', block)
    try:
        d = yaml.safe_load(cleaned) or {}
        if key in d and d[key] not in (None, ""):
            v = d[key]
            print(v if not isinstance(v, str) else v.strip())
            sys.exit(0)
    except yaml.YAMLError:
        continue
sys.exit(0)
PYEOF
}

# ── 1. VPS reachability + root SSH auth ────────────────────────────────────
section "1. VPS — root SSH auth"
VPS_IP=$(yget vps_ip)
VPS_ROOT_USER=$(yget vps_root_user)
VPS_KEY=$(yget vps_root_ssh_key)
[[ -z "$VPS_IP" ]]        && { fail "vps_ip missing in credentials"; }
[[ -z "$VPS_ROOT_USER" ]] && VPS_ROOT_USER="root"
[[ -z "$VPS_KEY" ]]       && warn "vps_root_ssh_key path missing — using default ssh-agent identities"

# Expand ~ in the key path
VPS_KEY="${VPS_KEY/#\~/$HOME}"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
[[ -n "$VPS_KEY" && -f "$VPS_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $VPS_KEY"

if [[ -n "$VPS_IP" ]]; then
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "whoami" >/dev/null 2>&1; then
    REMOTE_USER=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "whoami" 2>/dev/null)
    ok "ssh $VPS_ROOT_USER@$VPS_IP works (remote user: $REMOTE_USER)"
  else
    fail "ssh $VPS_ROOT_USER@$VPS_IP failed — fix SSH key or add it to authorized_keys"
  fi

  # OS check
  OS=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "lsb_release -d 2>/dev/null | cut -f2" 2>/dev/null || echo "")
  if [[ "$OS" =~ Ubuntu|Debian ]]; then
    ok "VPS OS: $OS"
  else
    warn "VPS OS '$OS' may not be Debian-family — stack expects Ubuntu 22.04+ or Debian 12+"
  fi
fi

# ── 2. GitHub PAT ───────────────────────────────────────────────────────────
section "2. GitHub PAT — repo create + push scope"
GH_PAT=$(yget github_pat)
GH_OWNER=$(yget github_repo_owner)
if [[ -z "$GH_PAT" ]]; then
  fail "github_pat missing in credentials"
else
  RESP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $GH_PAT" https://api.github.com/user)
  if [[ "$RESP" == "200" ]]; then
    LOGIN=$(curl -sS --max-time 10 -H "Authorization: Bearer $GH_PAT" https://api.github.com/user | jq -r '.login // "?"')
    ok "github_pat valid (login: $LOGIN)"
  else
    fail "github_pat invalid (HTTP $RESP)"
  fi
fi
[[ -z "$GH_OWNER" ]] && warn "github_repo_owner not set — defaults to PAT's user, may not be desired"

# ── 3. Cloudflare API token + zone access ──────────────────────────────────
section "3. Cloudflare — API token + zone access"
CF_TOKEN=$(yget cloudflare_api_token)
CF_ZONE=$(yget cloudflare_zone_id)
ROOT_DOMAIN=$(yget client_root_domain)

if [[ -z "$CF_TOKEN" ]]; then
  warn "cloudflare_api_token missing — DNS will need manual creation"
else
  RESP=$(curl -sS --max-time 10 -H "Authorization: Bearer $CF_TOKEN" \
    https://api.cloudflare.com/client/v4/user/tokens/verify)
  if echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1; then
    ok "cloudflare_api_token valid"
  else
    fail "cloudflare_api_token invalid: $(echo "$RESP" | jq -r '.errors[0].message // .')"
  fi

  if [[ -n "$CF_ZONE" ]]; then
    ZONE_RESP=$(curl -sS --max-time 10 -H "Authorization: Bearer $CF_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE")
    if echo "$ZONE_RESP" | jq -e '.success == true' >/dev/null 2>&1; then
      ZONE_NAME=$(echo "$ZONE_RESP" | jq -r '.result.name')
      if [[ "$ZONE_NAME" == "$ROOT_DOMAIN" ]]; then
        ok "cloudflare_zone_id matches client_root_domain ($ZONE_NAME)"
      else
        fail "cloudflare_zone_id points to '$ZONE_NAME', expected '$ROOT_DOMAIN'"
      fi
    else
      fail "cloudflare_zone_id rejected by API"
    fi
  else
    warn "cloudflare_zone_id missing — can't validate zone match"
  fi
fi

# ── 4. Telegram bot token + bot identity ───────────────────────────────────
section "4. Telegram — bot token + identity"
TG_TOKEN=$(yget telegram_bot_token)
TG_USER_ID=$(yget telegram_owner_user_id)
TG_BOT_USERNAME=$(yget telegram_bot_username)

if [[ -z "$TG_TOKEN" ]]; then
  fail "telegram_bot_token missing"
else
  ME_RESP=$(curl -sS --max-time 10 "https://api.telegram.org/bot$TG_TOKEN/getMe")
  if echo "$ME_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
    USERNAME=$(echo "$ME_RESP" | jq -r '.result.username')
    ok "telegram_bot_token valid (bot: @$USERNAME)"
    if [[ -n "$TG_BOT_USERNAME" && "$TG_BOT_USERNAME" != "$USERNAME" && "$TG_BOT_USERNAME" != "@$USERNAME" ]]; then
      warn "telegram_bot_username='$TG_BOT_USERNAME' but token belongs to @$USERNAME"
    fi
  else
    fail "telegram_bot_token invalid"
  fi
fi
[[ -z "$TG_USER_ID" ]] && fail "telegram_owner_user_id missing — bot won't have anyone on the allowlist"
if [[ -n "$TG_USER_ID" ]]; then
  if [[ "$TG_USER_ID" =~ ^[0-9]+$ ]]; then
    ok "telegram_owner_user_id is numeric ($TG_USER_ID)"
  else
    fail "telegram_owner_user_id must be numeric (got: $TG_USER_ID) — get yours from @userinfobot"
  fi
fi

# ── 5. CRM credentials (GHL only for now) ──────────────────────────────────
section "5. CRM — credentials (if applicable)"
CRM=$(yget crm)
case "$CRM" in
  ghl)
    GHL_LOC=$(yget ghl_location_id)
    GHL_TOK=$(yget ghl_pit_token)
    GHL_BASE=$(yget ghl_base_url)
    [[ -z "$GHL_BASE" ]] && GHL_BASE="https://services.leadconnectorhq.com"
    if [[ -z "$GHL_LOC" || -z "$GHL_TOK" ]]; then
      fail "crm: ghl but missing ghl_location_id or ghl_pit_token"
    else
      RESP=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer $GHL_TOK" -H "Version: 2021-07-28" \
        "$GHL_BASE/locations/$GHL_LOC")
      if [[ "$RESP" == "200" ]]; then
        ok "GHL credentials valid (location $GHL_LOC reachable)"
      else
        fail "GHL API rejected credentials (HTTP $RESP)"
      fi
    fi
    ;;
  none|"")
    warn "crm: none — pipeline + stalled-deal + hot-lead watchers will not fire"
    ;;
  *)
    warn "crm: '$CRM' — only ghl|none are wired in the current template"
    ;;
esac

# ── 6. TLS cert presence (paths OR pasted content) ─────────────────────────
section "6. TLS — Cloudflare Origin Cert"
TLS_CERT_PATH=$(yget tls_cert_path)
TLS_CERT_CONTENT=$(yget tls_cert_content)
TLS_KEY_PATH=$(yget tls_key_path)
TLS_KEY_CONTENT=$(yget tls_key_content)

if [[ -n "$TLS_CERT_PATH" && -n "$TLS_KEY_PATH" ]]; then
  # paths variant — assume they're on the VPS, test there
  if [[ -n "$VPS_IP" ]] && ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "test -f $TLS_CERT_PATH && test -f $TLS_KEY_PATH" 2>/dev/null; then
    ok "TLS cert + key both exist on VPS at configured paths"
  else
    fail "TLS cert or key not found at configured paths on VPS"
  fi
elif [[ -n "$TLS_CERT_CONTENT" && -n "$TLS_KEY_CONTENT" ]]; then
  # content variant — sanity check it looks like PEM
  if echo "$TLS_CERT_CONTENT" | grep -q 'BEGIN CERTIFICATE'; then
    ok "TLS cert content looks like PEM"
  else
    fail "TLS cert content doesn't look like PEM (missing BEGIN CERTIFICATE)"
  fi
  if echo "$TLS_KEY_CONTENT" | grep -qE 'BEGIN (RSA |EC )?PRIVATE KEY'; then
    ok "TLS key content looks like PEM"
  else
    fail "TLS key content doesn't look like PEM"
  fi
else
  fail "No TLS cert provided — need either *_path OR *_content (set in client-credentials.md)"
fi

# ── 7. Anthropic subscription account (informational) ──────────────────────
section "7. Anthropic — subscription account"
ANTHROPIC_ACCOUNT=$(yget anthropic_account)
if [[ -z "$ANTHROPIC_ACCOUNT" ]]; then
  warn "anthropic_account missing — note which Anthropic-subscribed account to log into during VPS install"
else
  ok "anthropic_account: $ANTHROPIC_ACCOUNT (you'll log into this on the VPS interactively)"
fi

# ── 8. DNS resolution (optional — pre-Phase-6 check) ───────────────────────
section "8. DNS — pre-deploy resolution check"
AGENT_SUB=$(yget agent_subdomain)
if [[ -n "$AGENT_SUB" ]]; then
  RESOLVED=$(dig +short "$AGENT_SUB" @1.1.1.1 2>/dev/null | tail -1)
  if [[ -z "$RESOLVED" ]]; then
    warn "$AGENT_SUB not yet resolving — will be created during deploy via Cloudflare API"
  elif [[ "$RESOLVED" == "$VPS_IP" ]]; then
    ok "$AGENT_SUB → $RESOLVED (matches vps_ip — DNS pre-existed)"
  else
    warn "$AGENT_SUB → $RESOLVED but vps_ip = $VPS_IP (will be UPDATED via Cloudflare API)"
  fi
fi

# ── 9. Discord credentials (v0.5+, optional) ───────────────────────────────
section "9. Discord — bot + channels (if discord_enabled)"
DISCORD_ENABLED=$(yget discord_enabled)
if [[ "$DISCORD_ENABLED" == "true" ]]; then
  DISCORD_TOKEN=$(yget discord_bot_token)
  DISCORD_GUILD=$(yget discord_guild_id)
  DISCORD_OWNER=$(yget discord_owner_user_id)

  if [[ -z "$DISCORD_TOKEN" ]]; then
    fail "discord_enabled: true but discord_bot_token missing"
  else
    DRESP=$(curl -sS --max-time 10 \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      https://discord.com/api/v10/users/@me)
    if echo "$DRESP" | jq -e '.id != null' >/dev/null 2>&1; then
      BOT_USER=$(echo "$DRESP" | jq -r '.username')
      ok "discord_bot_token valid (bot: $BOT_USER)"
    else
      fail "discord_bot_token rejected by Discord API"
    fi
  fi

  if [[ -z "$DISCORD_GUILD" ]]; then
    fail "discord_enabled: true but discord_guild_id missing — right-click server → Copy Server ID"
  else
    GRESP=$(curl -sS --max-time 10 \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      "https://discord.com/api/v10/guilds/$DISCORD_GUILD")
    if echo "$GRESP" | jq -e '.id != null' >/dev/null 2>&1; then
      GUILD_NAME=$(echo "$GRESP" | jq -r '.name')
      ok "discord_guild_id valid (server: $GUILD_NAME)"
    else
      fail "Bot can't see guild $DISCORD_GUILD — invite the bot to the server first"
    fi
  fi

  if [[ -z "$DISCORD_OWNER" ]]; then
    fail "discord_enabled: true but discord_owner_user_id missing — Discord user → ... → Copy User ID"
  elif [[ "$DISCORD_OWNER" =~ ^[0-9]+$ ]]; then
    ok "discord_owner_user_id is numeric ($DISCORD_OWNER)"
  else
    fail "discord_owner_user_id must be numeric snowflake (got: $DISCORD_OWNER)"
  fi
else
  ok "discord_enabled: false — skipping Discord checks"
fi

# ── 10. Mission Control deps (v0.7.0) — Python 3.11+ + FastAPI + sqlite3 ──
# These are needed by the Phase 1-4 components (dashboard-chat backend,
# rules-engine, anomaly-detect, session-parser, _spans, _roi, _budget). If
# any of these are missing on the VPS, the installer will install them; we
# just warn here so the operator knows what to expect.
section "10. Mission Control deps — Python 3.11+ + FastAPI + sqlite3"
if [[ -n "${VPS_IP:-}" ]]; then
  REMOTE_PY=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "python3 --version 2>&1 | awk '{print \$2}'" 2>/dev/null)
  if [[ -n "$REMOTE_PY" ]]; then
    PY_MAJOR=$(echo "$REMOTE_PY" | cut -d. -f1)
    PY_MINOR=$(echo "$REMOTE_PY" | cut -d. -f2)
    if [[ "$PY_MAJOR" -ge 3 && "$PY_MINOR" -ge 11 ]]; then
      ok "VPS Python: $REMOTE_PY (3.11+ required for Mission Control)"
    elif [[ "$PY_MAJOR" -ge 3 && "$PY_MINOR" -ge 10 ]]; then
      warn "VPS Python: $REMOTE_PY — 3.11+ recommended (3.10 may work but isn't tested)"
    else
      fail "VPS Python: $REMOTE_PY — too old for Mission Control (needs 3.11+)"
    fi
  else
    warn "VPS Python3 not detected — installer will apt-get install python3"
  fi
  # sqlite3 (stdlib) — used by _spans.py
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "python3 -c 'import sqlite3' 2>/dev/null"; then
    ok "VPS python3 sqlite3 module available (for spans store)"
  else
    fail "VPS python3 sqlite3 NOT available — spans store will not work"
  fi
  # pyyaml — used by rules-engine
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "python3 -c 'import yaml' 2>/dev/null"; then
    ok "VPS python3 yaml module available (for rules engine)"
  else
    warn "VPS python3-yaml missing — bootstrap-mission-control.sh will apt install it"
  fi
  # FastAPI — used by dashboard-chat
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "python3 -c 'import fastapi' 2>/dev/null"; then
    ok "VPS python3 fastapi module available (dashboard-chat backend)"
  else
    warn "VPS fastapi missing — bootstrap-mission-control.sh will pip install it"
  fi
  # uvicorn — used by dashboard-chat
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "command -v uvicorn >/dev/null 2>&1 || python3 -c 'import uvicorn' 2>/dev/null"; then
    ok "VPS uvicorn available (dashboard-chat runtime)"
  else
    warn "VPS uvicorn missing — bootstrap-mission-control.sh will pip install it"
  fi
  # nginx — required for the dashboard + SSE
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "command -v nginx >/dev/null 2>&1"; then
    NGINX_V=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "nginx -v 2>&1 | awk -F/ '{print \$2}'" 2>/dev/null)
    ok "VPS nginx installed: $NGINX_V"
  else
    warn "VPS nginx not installed — installer will apt install nginx"
  fi
else
  warn "VPS_IP unset — skipping Mission Control dep checks"
fi

# ── 11. Multi-agent swarms (v0.6+, optional) ───────────────────────────────
section "11. OpenSwarm — Node 20+ + Python 3.10+ (if multi_agent_swarms)"
SWARMS_ENABLED=$(yget multi_agent_swarms)
if [[ "$SWARMS_ENABLED" == "true" && -n "$VPS_IP" ]]; then
  REMOTE_NODE=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1" 2>/dev/null)
  REMOTE_PY=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "python3 --version 2>&1 | awk '{print \$2}'" 2>/dev/null)
  if [[ -n "$REMOTE_NODE" && "$REMOTE_NODE" -ge 20 ]]; then
    ok "VPS Node major version: $REMOTE_NODE (≥20 required for OpenSwarm)"
  else
    warn "VPS Node version is '$REMOTE_NODE' — installer will install Node 20+ if missing"
  fi
  if [[ -n "$REMOTE_PY" ]]; then
    ok "VPS Python: $REMOTE_PY (3.10+ required)"
  else
    warn "VPS Python3 not detected — installer will install"
  fi
else
  ok "multi_agent_swarms: false — skipping OpenSwarm checks"
fi

# ── FINAL ──────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
echo " PRE-FLIGHT RESULT: $PASS PASS · $FAIL FAIL · $WARN WARN"
echo "═══════════════════════════════════════════════════════════════════"
if [[ $FAIL -gt 0 || $WARN -gt 0 ]]; then
  echo
  echo "Issues:"
  for i in "${ISSUES[@]}"; do echo "  - $i"; done
fi
echo
if [[ $FAIL -eq 0 ]]; then
  echo "✅ Safe to proceed with deploy."
  exit 0
else
  echo "❌ FIX FAILURES BEFORE STARTING DEPLOY. Re-run this script when ready."
  exit 1
fi
