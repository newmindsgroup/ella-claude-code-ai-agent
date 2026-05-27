#!/usr/bin/env bash
# bootstrap-tenant.sh — provision a tenant on the current VPS.
#
# Idempotent. Run as root on the target Vultr box.
# Reads vps-setup/tenants/{tenant_id}.yml, ensures the rendered files exist,
# creates the Linux user, copies files into /opt/{user}/agents/, installs
# systemd units. Walks {{TENANT_PERSON_FIRST_NAME}} through the manual steps that need a browser
# (Claude login, BotFather, GHL PIT) at the right time.
#
# Usage (on a Vultr root shell):
#   git clone <repo> /tmp/{tenant}-stack
#   cd /tmp/{tenant}-stack
#   sudo bash vps-setup/scripts/bootstrap-tenant.sh tenants/{tenant_id}.yml

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TENANT_FILE="${1:-}"

if [[ -z "$TENANT_FILE" ]]; then
  echo "usage: $0 <path-to-tenant.yml>"
  echo "example: $0 vps-setup/tenants/example.yml"
  exit 1
fi
[[ ! -f "$TENANT_FILE" ]] && { echo "tenant file not found: $TENANT_FILE" >&2; exit 1; }

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: bootstrap-tenant.sh must run as root (creates system users + systemd units)" >&2
  exit 1
fi

# ---- read tenant config ----
python3 -c "import yaml" 2>/dev/null || pip install pyyaml --break-system-packages --quiet

read_yaml() { python3 -c "import yaml,sys; print(yaml.safe_load(open('$TENANT_FILE')).get('$1','') or '')"; }

TENANT_ID=$(read_yaml tenant_id)
LINUX_USER=$(read_yaml linux_user); LINUX_USER="${LINUX_USER:-$TENANT_ID}"
USER_HOME=$(read_yaml user_home);   USER_HOME="${USER_HOME:-/opt/$LINUX_USER}"
AGENT_HOME=$(read_yaml agent_home); AGENT_HOME="${AGENT_HOME:-$USER_HOME/agents}"
BRAND_REPO_URL=$(read_yaml brand_repo_url)
BRAND_REPO_BRANCH=$(read_yaml brand_repo_branch); BRAND_REPO_BRANCH="${BRAND_REPO_BRANCH:-main}"
BRAND_REPO_NAME=$(read_yaml brand_repo_name);     BRAND_REPO_NAME="${BRAND_REPO_NAME:-$TENANT_ID}"
CLIENT_REPO_URL=$(read_yaml client_repo_url)   # optional: a client codebase to fold into the knowledge graph
PERSON_FULL_NAME=$(read_yaml person_full_name)
TELEGRAM_BOT_USERNAME=$(read_yaml telegram_bot_username)

echo "=== bootstrapping tenant: $TENANT_ID ==="
echo "  linux_user:      $LINUX_USER"
echo "  agent_home:      $AGENT_HOME"
echo "  brand_repo:      $BRAND_REPO_URL ($BRAND_REPO_BRANCH)"
echo "  person:          $PERSON_FULL_NAME"
echo "  telegram_bot:    @$TELEGRAM_BOT_USERNAME"
echo

read -rp "Continue with this configuration? [y/N] " yn
[[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "aborted"; exit 0; }

# ---- step 1: render template ----
echo
echo "[1/8] Rendering template from tenant config…"
bash "$REPO_ROOT/vps-setup/scripts/render-tenant.sh" "$TENANT_FILE"
RENDERED_DIR="$REPO_ROOT/vps-setup/agents-config/$TENANT_ID"
[[ ! -d "$RENDERED_DIR" ]] && { echo "render failed: no $RENDERED_DIR"; exit 1; }

# ---- step 2: create Linux user if missing ----
echo
echo "[2/8] Ensuring Linux user '$LINUX_USER' exists…"
if id "$LINUX_USER" &>/dev/null; then
  echo "  user exists — skipping"
else
  adduser "$LINUX_USER" --disabled-password --gecos "" --home "$USER_HOME"
  echo "  created"
fi

# ---- step 3: ensure agent_home + agent_skills_dir ----
echo
echo "[3/8] Ensuring directories…"
mkdir -p "$AGENT_HOME" "$AGENT_HOME/scripts" "$AGENT_HOME/.claude/agents" \
         "$AGENT_HOME/tasks" "$AGENT_HOME/drafts" "$AGENT_HOME/logs" "$AGENT_HOME/reports"
chown -R "$LINUX_USER:$LINUX_USER" "$USER_HOME"

# ---- step 4: install Node 20, Bun, Claude Code, jq if missing ----
echo
echo "[4/8] Ensuring base tooling…"
if ! command -v node >/dev/null 2>&1; then
  echo "  installing Node 20…"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "  installing Claude Code…"
  npm install -g @anthropic-ai/claude-code
fi
if ! command -v bun >/dev/null 2>&1; then
  echo "  installing bun (as $LINUX_USER)…"
  sudo -u "$LINUX_USER" -H bash -c 'curl -fsSL https://bun.sh/install | bash'
  ln -sf "$USER_HOME/.bun/bin/bun" /usr/local/bin/bun
  ln -sf "$USER_HOME/.bun/bin/bunx" /usr/local/bin/bunx
fi
command -v jq    >/dev/null 2>&1 || apt install -y jq
command -v tmux  >/dev/null 2>&1 || apt install -y tmux

# ---- step 5: clone brand canon ----
echo
echo "[5/8] Cloning brand canon…"
if [[ -d "$AGENT_HOME/$BRAND_REPO_NAME" ]]; then
  echo "  exists — pulling latest"
  sudo -u "$LINUX_USER" -H bash -c "cd '$AGENT_HOME/$BRAND_REPO_NAME' && git pull --ff-only"
else
  sudo -u "$LINUX_USER" -H git clone -b "$BRAND_REPO_BRANCH" "$BRAND_REPO_URL" "$AGENT_HOME/$BRAND_REPO_NAME"
fi

# ---- step 6: copy rendered config into agent_home ----
echo
echo "[6/8] Placing rendered files into $AGENT_HOME…"
sudo -u "$LINUX_USER" cp "$RENDERED_DIR/CLAUDE.md" "$AGENT_HOME/CLAUDE.md"
sudo -u "$LINUX_USER" cp "$RENDERED_DIR/.claude/settings.json" "$AGENT_HOME/.claude/settings.json"
sudo -u "$LINUX_USER" cp "$RENDERED_DIR"/.claude/agents/*.md "$AGENT_HOME/.claude/agents/"
sudo -u "$LINUX_USER" cp "$RENDERED_DIR"/scripts/*.sh "$RENDERED_DIR"/scripts/*.py "$AGENT_HOME/scripts/" 2>/dev/null || true
sudo -u "$LINUX_USER" chmod +x "$AGENT_HOME"/scripts/*.sh
[[ -f "$AGENT_HOME/tasks/README.md" ]] || sudo -u "$LINUX_USER" cp "$RENDERED_DIR/tasks/README.md" "$AGENT_HOME/tasks/README.md"

# ---- step 6b: ACTIVATE self-service ops (sudoers + root-owned wrappers + SSH key) ----
# This is what turns the inert ops/ templates into a working capability. The
# agent gets passwordless sudo to ONLY the wrapper scripts in scripts/ops/,
# which must be root-owned (so the agent can't edit a script it runs as root).
echo
echo "[6b/8] Activating self-service ops…"
if [[ -d "$RENDERED_DIR/scripts/ops" ]]; then
  # Wrappers live root:root 755 — CRITICAL: if the agent (LINUX_USER) owned
  # these, it could rewrite a script that sudo then runs as root = full
  # privilege escalation. Root ownership is the security boundary.
  mkdir -p "$AGENT_HOME/scripts/ops"
  cp "$RENDERED_DIR"/scripts/ops/*.sh "$AGENT_HOME/scripts/ops/"
  chown root:root "$AGENT_HOME"/scripts/ops/*.sh
  chmod 755 "$AGENT_HOME"/scripts/ops/*.sh
  echo "  ✓ $(ls "$AGENT_HOME"/scripts/ops/*.sh | wc -l | tr -d ' ') ops wrappers installed (root:root 755)"

  # Install sudoers entry — validate with visudo -c BEFORE moving into place.
  if [[ -f "$RENDERED_DIR/sudoers/agent-ops.sudoers" ]]; then
    SUDOERS_DST="/etc/sudoers.d/${LINUX_USER}-agent-ops"
    cp "$RENDERED_DIR/sudoers/agent-ops.sudoers" "/tmp/agent-ops.sudoers.staging"
    chmod 440 "/tmp/agent-ops.sudoers.staging"
    chown root:root "/tmp/agent-ops.sudoers.staging"
    if visudo -c -f "/tmp/agent-ops.sudoers.staging" >/dev/null 2>&1; then
      mv "/tmp/agent-ops.sudoers.staging" "$SUDOERS_DST"
      echo "  ✓ sudoers installed + validated → $SUDOERS_DST"
    else
      rm -f "/tmp/agent-ops.sudoers.staging"
      echo "  ✗ sudoers FAILED visudo validation — NOT installed. Self-service ops disabled."
    fi
  else
    echo "  - no sudoers/agent-ops.sudoers in render — skipping (ops will need a password)"
  fi

  # Audit log for every privileged op
  touch "/var/log/${LINUX_USER}-agent-ops.log"
  chmod 644 "/var/log/${LINUX_USER}-agent-ops.log"
else
  echo "  - no scripts/ops/ in render — skipping self-service ops activation"
fi

# SSH key for the agent (self-update, self-ssh for PTY tools, future external SSH).
# Idempotent — only generates if missing.
SSH_DIR="$USER_HOME/.ssh"
if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
  sudo -u "$LINUX_USER" mkdir -p "$SSH_DIR"
  sudo -u "$LINUX_USER" chmod 700 "$SSH_DIR"
  sudo -u "$LINUX_USER" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N '' -C "${LINUX_USER}-agent@$(hostname)"
  # Self-authorize so the agent can `ssh LINUX_USER@localhost` for PTY tools
  sudo -u "$LINUX_USER" cp "$SSH_DIR/id_ed25519.pub" "$SSH_DIR/authorized_keys"
  sudo -u "$LINUX_USER" chmod 600 "$SSH_DIR/authorized_keys" "$SSH_DIR/id_ed25519"
  echo "  ✓ ed25519 keypair generated + self-authorized"
else
  echo "  - SSH key already exists — skipping"
fi

# ---- step 7: install systemd units ----
echo
echo "[7/8] Installing systemd units…"
for f in "$RENDERED_DIR"/systemd/*; do
  base=$(basename "$f")
  cp "$f" "/etc/systemd/system/$base"
done
systemctl daemon-reload

# enable timers (services they trigger don't need to be enabled)
TIMERS=(claude-agent.service)
[[ -f "/etc/systemd/system/morning-brief.timer" ]]   && TIMERS+=(morning-brief.timer)
[[ -f "/etc/systemd/system/evening-rollup.timer" ]]  && TIMERS+=(evening-rollup.timer)
[[ -f "/etc/systemd/system/stale-watcher.timer" ]]   && TIMERS+=(stale-watcher.timer)
[[ -f "/etc/systemd/system/website-uptime-watcher.timer" ]] && TIMERS+=(website-uptime-watcher.timer)
systemctl enable "${TIMERS[@]}"

# ---- step 7c: fold the client's codebase into the knowledge graph ----
# Optional cross-repo traversal: if client_repo_url is set, clone it and add it
# to the unified Graphify graph so /graph + /who span the client's code too.
if [[ -n "$CLIENT_REPO_URL" ]]; then
  echo "[7c/8] Graphing client repo: $CLIENT_REPO_URL"
  GRAPHIFY_BIN="$(sudo -u "$LINUX_USER" -H bash -lc 'command -v graphify || echo "$HOME/.local/bin/graphify"')"
  sudo -u "$LINUX_USER" -H bash -lc "
    set -e
    CDIR=\$('$GRAPHIFY_BIN' clone '$CLIENT_REPO_URL' 2>/dev/null | tail -1)
    [[ -d \"\$CDIR\" ]] && '$GRAPHIFY_BIN' update \"\$CDIR\" >/dev/null 2>&1 || true
    mapfile -t G < <(find '$AGENT_HOME' -name graph.json -path '*graphify-out*' | grep -v merged-graph.json)
    [[ \${#G[@]} -ge 2 ]] && '$GRAPHIFY_BIN' merge-graphs \"\${G[@]}\" --out '$AGENT_HOME/graphify-out/merged-graph.json' >/dev/null 2>&1 || true
  " && echo "      client repo folded into merged graph" || echo "      (client repo graphing skipped/failed — non-fatal)"
fi

# ---- step 7d: install ALL capabilities (Graphify, MCPs, agency-agents, memory v2, Obsidian, Mission Control, timers) ----
# This is the step that turns "files copied" into "fully working agent."
# Idempotent + re-runnable. Auth-dependent bits (Superpowers, some MCPs) finish
# on a re-run after `claude login` — the manual steps below cover that.
echo
echo "[7d/8] Installing all agent capabilities…"
bash "$REPO_ROOT/vps-setup/scripts/install-capabilities.sh" "$TENANT_FILE" || \
  echo "  ⚠ some capabilities warned — re-run install-capabilities.sh after Claude login (see below)"

# ---- step 8: print remaining manual steps ----
echo
echo "[8/8] ============================================================"
echo "      Tenant '$TENANT_ID' bootstrapped on this VPS."
echo "      ============================================================"
echo
echo "  Three manual steps remain that need a browser / phone:"
echo
echo "  A) AUTHENTICATE CLAUDE CODE WITH MAX SUBSCRIPTION"
echo "     sudo -u $LINUX_USER -H tmux new -s claude-setup"
echo "     # inside tmux:"
echo "     claude --dangerously-skip-permissions"
echo "     # → choose 'Login with subscription', browser auth, paste code"
echo "     # → exit (Ctrl-D), then: tmux kill-session -t claude-setup"
echo
echo "  B) CREATE TELEGRAM BOT WITH BOTFATHER"
echo "     # On Telegram, message @BotFather:  /newbot  →  name + username"
echo "     # Save the HTTP API token. Then create:"
echo "     mkdir -p $USER_HOME/.claude/channels/telegram"
echo "     echo 'TELEGRAM_BOT_TOKEN=<paste-token-here>' > $USER_HOME/.claude/channels/telegram/.env"
echo "     chown -R $LINUX_USER:$LINUX_USER $USER_HOME/.claude"
echo "     chmod 600 $USER_HOME/.claude/channels/telegram/.env"
echo "     # Get your Telegram chat ID via @userinfobot, then:"
echo "     systemctl start claude-agent.service"
echo "     # In Claude Code: /plugin install telegram@claude-plugins-official → /telegram:configure <token>"
echo "     # DM your bot anything → get a 6-char pairing code → /telegram:access pair <code>"
echo "     # then: /telegram:access policy allowlist"
echo
echo "  C) CONFIGURE GHL CREDENTIALS"
echo "     # Render your .mcp.json from the example:"
echo "     cat $RENDERED_DIR/.mcp.json.example"
echo "     # Replace \${GHL_PRIVATE_INTEGRATIONS_TOKEN} and \${GHL_LOCATION_ID} with actuals,"
echo "     # then save to $AGENT_HOME/.mcp.json (chmod 600)."
echo "     chmod 600 $AGENT_HOME/.mcp.json"
echo "     # Optional: clone the GHL MCP server (mastanley13/GoHighLevel-MCP) at $AGENT_HOME/ghl-mcp"
echo "     # and npm install + build."
echo
echo "  Once those three are done:"
echo "     systemctl restart claude-agent.service"
echo "     systemctl start morning-brief.timer evening-rollup.timer stale-watcher.timer"
echo
echo "  Test by DMing the Telegram bot anything. Should respond in under 30s."
echo
