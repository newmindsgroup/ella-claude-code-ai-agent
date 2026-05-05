# VPS install — production always-on agent

Stand up the full Ella stack on a Linux VPS. End-to-end: from blank Ubuntu to "the agent replied to my first Telegram message" in **under 60 minutes**.

This is what you run when you want a chief-of-staff agent for a business — not a laptop dev workflow. The agent runs continuously inside a tmux session managed by systemd, reachable via Telegram 24/7, with a public dashboard at `dashboard.{your-tld}`.

---

## Prerequisites

### VPS
- **Ubuntu 22.04+ or Debian 12+**, 2 GB RAM minimum (4 GB recommended), 30 GB disk
- Tested on Vultr, DigitalOcean, Hetzner. Anything that runs Ubuntu cleanly works.
- A **non-root user** with `sudo` access (we'll create one in step 1 if needed)
- Outbound HTTPS to `github.com`, `registry.npmjs.org`, `pypi.org`, `anthropic.com`

### Domain
- A domain or subdomain pointed at the VPS IP via DNS A record (e.g. `dashboard.yourbusiness.com`)
- (Recommended) Cloudflare in front for TLS + WAF + edge caching. The dashboard requires `Cache-Control: private, no-store, must-revalidate` to work behind CF basic-auth — this is configured automatically by `bootstrap-tenant.sh`.

### Telegram bot
- A Telegram bot from [@BotFather](https://t.me/BotFather) — you'll get a token like `1234567890:AABBccDDeeFFggHHiiJJkkLLmm`
- The numeric chat ID for your personal Telegram account (your account talking to your bot). Get it from [@userinfobot](https://t.me/userinfobot).

### Anthropic
- A Claude Code Max, Pro, or Team subscription — **NOT an API key**. The agent will run `claude login` and authenticate via the browser flow.

### Other API keys (optional but recommended)
- **Firecrawl** API key from [firecrawl.dev/app/api-keys](https://firecrawl.dev/app/api-keys) — free tier is sufficient to start
- **Cloudflare** API token (DNS edit permissions) — for automated cert renewal
- **Your CRM's MCP credentials** — example uses GoHighLevel; substitute HubSpot / Salesforce / Pipedrive as needed
- **GitHub PAT** — for the agent to push commits to your business repo (the auto-deploy pattern)

---

## Step 1 — Prep the VPS

SSH in as root, create a non-root user with sudo:

```bash
ssh root@<vps-ip>
adduser <tenant-id>          # e.g. "yourbusiness" — used as Linux username + paths slug
usermod -aG sudo <tenant-id>
mkdir -p /home/<tenant-id>/.ssh
cp ~/.ssh/authorized_keys /home/<tenant-id>/.ssh/
chown -R <tenant-id>:<tenant-id> /home/<tenant-id>/.ssh
chmod 700 /home/<tenant-id>/.ssh
chmod 600 /home/<tenant-id>/.ssh/authorized_keys
```

Then SSH back in as the non-root user (or `sudo -u <tenant-id> -H bash`) and continue.

Update + install base prerequisites:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git python3 python3-pip nodejs npm tmux nginx curl jq
node --version    # 18+ required — install from NodeSource if too old
```

---

## Step 2 — Install Claude Code

```bash
sudo npm install -g @anthropic-ai/claude-code
claude --version
claude login            # complete the browser flow against your Anthropic subscription
```

---

## Step 3 — Clone this repo

```bash
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent.git ~/ella
cd ~/ella
```

---

## Step 4 — Install the agent-stack baseline

```bash
cp agent-stack/config/client.example.env agent-stack/config/client.env
$EDITOR agent-stack/config/client.env
```

Set values for the VPS. Example:

```bash
CLIENT_NAME="<tenant-id>"
CLAUDE_PROJECT_ROOT="/opt/<tenant-id>/agents/<your-business-repo>"
KNOWLEDGE_LIBRARY_ROOTS="/opt/<tenant-id>/agents/<your-business-repo>"
MEMORY_STORE_PATH="/opt/<tenant-id>/.agent-stack/memory.json"
CHROMA_DB_PATH="/opt/<tenant-id>/.agent-stack/chroma_db"

AGENCY_AGENTS_CACHE_DIR="/opt/<tenant-id>/.local/share/agency-agents"
CLAUDE_AGENTS_DIR="/opt/<tenant-id>/.claude/agents"
BRAND_VOICE_PATHS_FILE="/opt/<tenant-id>/agents/<your-business-repo>/agent-stack/agency-agents-installer/voice-paths.json"

FIRECRAWL_API_KEY="fc-<your-key>"
AGENT_MCP_JSON_PATH="/opt/<tenant-id>/agents/.mcp.json"

INSTALL_LOG_PATH="/opt/<tenant-id>/.agent-stack/install.log"
```

> **Why `AGENT_MCP_JSON_PATH` matters on the VPS** — the always-on agent runs from `/opt/<tenant-id>/agents/` (its working directory), and reads MCP servers from `.mcp.json` in that dir. `claude mcp add` writes to local-scope which is invisible to the always-on agent. Setting `AGENT_MCP_JSON_PATH` makes script 08 edit the right file directly.

Run install:

```bash
chmod 600 agent-stack/config/client.env
bash agent-stack/scripts/install-all.sh
```

This installs Superpowers, the 5 official MCPs, the agency-agents cherry-pick, Firecrawl, and Graphify. ~10–15 min.

---

## Step 5 — Configure your tenant

```bash
cp vps-setup/tenants/EXAMPLE_TENANT.yml vps-setup/tenants/<tenant-id>.yml
$EDITOR vps-setup/tenants/<tenant-id>.yml
```

The example file is heavily commented — read it top to bottom and fill in real values. Highlights:

```yaml
tenant_id: <tenant-id>                  # slug, drives Linux user / paths
person_full_name: "Jane Doe"            # used in agent prompts
person_first_name: "Jane"
person_role_description: "independent fractional CMO"
contact_email: "jane@example.com"
website_url: "https://example.com"
timezone: "America/New_York"

linux_user: <tenant-id>
agent_home: /opt/<tenant-id>/agents
brand_repo_name: <your-business-repo>

telegram_bot_token: "1234567890:AABBccDDeeFF..."
telegram_chat_id: 12345678

dashboard_subdomain: dashboard           # → dashboard.{your-tld}
dashboard_basic_auth_user: <username>
dashboard_basic_auth_password_hint: "set via htpasswd; never commit"

voice_archetype_primary: "Sage"
voice_archetype_secondary: "Creator"
voice_playbook_path: <path-to-your-voice-playbook.md>

# ... ~150 lines total — see the file for the full schema
```

---

## Step 6 — Render the tenant template

```bash
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<tenant-id>.yml
```

This walks `vps-setup/agent-template/` and substitutes every `{{TENANT_*}}` token, writing the rendered output to `vps-setup/agents-config/<tenant-id>/`. Re-runnable.

Inspect the rendered files (especially `CLAUDE.md`) to verify substitutions look correct before deploying.

---

## Step 7 — Bootstrap the tenant on the VPS

```bash
sudo bash vps-setup/scripts/bootstrap-tenant.sh vps-setup/tenants/<tenant-id>.yml
```

This:
1. Creates the Linux user and home directory layout under `/opt/<tenant-id>/`
2. Copies the rendered `CLAUDE.md`, scripts, dashboard, nginx config to the right places
3. Installs the systemd units (`claude-agent.service`, `dashboard-chat.service`, `telemetry-calc.timer`, `telegram-poller-watchdog.timer`, `deploy-timeout-sweep.timer`)
4. Sets up nginx with TLS (assumes Cloudflare Origin cert; substitute your own if not using CF)
5. Sets up basic-auth for the dashboard
6. Initializes the task ledger, goals vault, memory store
7. Patches the Telegram channels plugin in-place (idempotent — re-applied on every agent restart)

Total: ~5–10 min.

---

## Step 8 — Set up brand canon + voice paths

The agent expects a brand canon repo at `/opt/<tenant-id>/agents/<your-business-repo>/`. This is YOUR business's repo — pages, drafts, design tokens, brand voice.

Clone or initialize it:

```bash
sudo -u <tenant-id> -H bash -lc "
  cd /opt/<tenant-id>/agents
  git clone <your-business-repo-git-url> <your-business-repo>
"
```

Drop in the brand templates from `examples/` and customize:

```bash
sudo -u <tenant-id> -H bash -lc "
  cd /opt/<tenant-id>/agents/<your-business-repo>
  cp ~/ella/examples/AGENTS.md .
  cp ~/ella/examples/DESIGN.md .
  cp ~/ella/examples/voice-playbook.example.md ./brand-voice-playbook.md
  # then edit each with your real values
"
```

Create the voice-paths file referenced in `client.env`:

```bash
sudo -u <tenant-id> -H bash -lc "
  cat > /opt/<tenant-id>/agents/<your-business-repo>/agent-stack/agency-agents-installer/voice-paths.json <<'EOF'
{
  \"voice_dna_paths\": [
    \"/opt/<tenant-id>/agents/<your-business-repo>/brand-voice-playbook.md\",
    \"/opt/<tenant-id>/agents/<your-business-repo>/AGENTS.md\"
  ]
}
EOF
"
```

Re-run script 07 so voice-aware sub-agents pick up the brand-voice block:

```bash
sudo -u <tenant-id> -H bash agent-stack/scripts/07-install-agency-agents.sh
```

---

## Step 9 — Start the agent

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now claude-agent.service dashboard-chat.service \
                            telemetry-calc.timer telegram-poller-watchdog.timer \
                            deploy-timeout-sweep.timer
```

Verify:

```bash
sudo systemctl status claude-agent.service
sudo journalctl -u claude-agent.service -n 30 --no-pager
```

You should see "Started claude-agent.service" and a clean tmux session.

---

## Step 10 — Smoke test

Open Telegram, find your bot, and send: **`hello`**

The agent should reply within 5–10 seconds with a brief acknowledgment. If it does, you're live.

Try a more substantial prompt:

> *"Draft a LinkedIn post about <something on-brand for your business>."*

The agent should:
1. React with 👀 immediately
2. Identify it as specialized work
3. Read your brand voice playbook
4. Delegate to `linkedin-content-creator`
5. Return a draft preview with inline approval buttons (✅ Ship / ❌ Hold / ✏️ Revise)

If it does that — the autonomy loop is closed. You're ready to use the bot daily.

---

## Step 11 — Verify the dashboard

Open `https://dashboard.<your-tld>/` in a browser. You should see the basic-auth prompt (use the credentials from your tenant.yml). After authenticating, the dashboard renders KPI cards, the task ledger, telemetry, and a Chat tab.

Health check from the VPS:

```bash
bash vps-setup/scripts/health.sh vps-setup/tenants/<tenant-id>.yml
```

All five services + the timer should report healthy.

---

## Step 12 — (Recommended) Set up auto-pull from main

If you want changes to your business repo to auto-deploy to the VPS within ~60 seconds (this powers the blueprint.{your-tld} site if you publish one):

```bash
sudo systemctl enable --now blueprint-pull.timer
sudo systemctl enable --now blueprint-watch.path
```

These are configured by `bootstrap-tenant.sh` if your `tenant.yml` declares `blueprint_publish_subdomain` and a publish webroot.

---

## Operational discipline (read before you ship)

[`vps-setup/runbooks/operating-principles.md`](../vps-setup/runbooks/operating-principles.md) is non-negotiable for production:

1. **Idempotent installs.** Re-running any script is safe.
2. **Dry-run before production changes.** Especially anything touching systemd, nginx, or the agent service.
3. **Append-only audit logs.** `implementation-log.md`, task ledger, goal vault.
4. **No force-push to main.** Ever.
5. **Don't batch-restart the agent.** 2+ manual restarts within 30 min trip the watchdog circuit breaker. Pre-prune `/var/lib/<tenant-id>/watchdog-restart-history.txt` if you must restart twice in quick succession.
6. **CDN + basic-auth cache rule.** Internal vhosts behind Cloudflare need `Cache-Control: private, no-store, must-revalidate, always` or auth leaks via edge cache.
7. **Memory entries for every meaningful change.**

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `claude-agent.service` won't start | `journalctl -u claude-agent.service -n 100 --no-pager` — usually a missing path or `claude login` not run as the right user |
| Agent doesn't respond to Telegram | Check `journalctl -u claude-agent.service -f` for telegram poller errors; verify bot token is correct in tenant.yml; verify chat_id matches |
| Dashboard 401 even with right credentials | Check `/etc/nginx/.htpasswd-<tenant-id>` is mode 640, owned `root:www-data` |
| Dashboard auth leaking via CF | Check nginx config has `add_header Cache-Control "private, no-store, must-revalidate" always;` (the `always` flag is critical — without it, 401 responses get edge-cached) |
| Watchdog keeps restarting the agent | Likely bun-death — check `/var/log/<tenant-id>-bun-death-diagnostics.log`. Common cause: telegram poller hangs on a malformed message |
| MCP servers not visible to the agent | Verify `AGENT_MCP_JSON_PATH` was set in `client.env` AND the file at that path actually contains the entry. `claude mcp list` from `/opt/<tenant-id>/agents/` should show all servers as `✓ Connected` |

For deeper issues see [`agent-stack/docs/troubleshooting.md`](../agent-stack/docs/troubleshooting.md).
