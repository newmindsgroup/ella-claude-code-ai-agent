# Porting playbook — spinning up the chief-of-staff stack for a new business

This doc walks you through deploying the same agent stack you have for the personal brand to a different business. End-to-end target: under one hour, from "I want this for company X" to "the agent replied to my first Telegram message."

The stack is multi-tenant by design. Every business-specific value lives in `tenants/{tenant_id}.yml`. The engine — sub-agents, scripts, systemd units, Telegram tooling, task ledger — is identical across tenants.

---

## Prerequisites (one-time, before your first port)

Before bootstrapping any new tenant, the target VPS needs:

1. A reachable Vultr (or other) box with sudo. Recommended: Ubuntu 24.04 LTS, 1 GB RAM minimum.
2. SSH access for you, ideally key-based.
3. Outbound HTTPS to:
   - `api.telegram.org` (Telegram bot)
   - `services.leadconnectorhq.com` (GHL)
   - `claude.com`, `api.anthropic.com` (Claude auth + MCPs)
   - `github.com` (brand canon clone)
4. A separate Vultr box per tenant is recommended for clean isolation. Multi-tenant on one box works but the deny lists in `protected_paths` need to cover all tenants.

If you're using the **same box** that already runs Daniel's stack, that's fine — each tenant gets its own Linux user, its own `/opt/{user}/agents/`, and its own systemd units. They don't interfere.

---

## Step 1 — Per-tenant prep (you, on your laptop, ~15 min)

Each new business needs three external things created before bootstrap:

### 1a. Brand canon repo

The agent reads from this. It needs at minimum:
- A voice playbook (markdown file) with a "voice DNA" section the agent can paste as system context for content drafts.
- A response playbook with email templates.
- A services / offers doc.
- A content strategy doc.
- A narrative core doc.

You can copy Daniel's brand-repo structure as a template, then rewrite the contents for the new business. Push to a private git repo. Note the clone URL.

### 1b. Telegram bot

On Telegram, message `@BotFather`:
- `/newbot`
- Bot display name (e.g. "Acme Agent")
- Bot username — must end in `bot` (e.g. `acme_chief_bot`)

BotFather replies with an **HTTP API token** like `8507169705:AAH...`. Save it.

Also message `@userinfobot` and send `/start` — it replies with **your Telegram user ID** (numeric). Save it. This is what locks the bot to only respond to you.

### 1c. GoHighLevel credentials

In the GHL sub-account for this business:
- Settings → Integrations → Private Integrations → Create New Integration.
- Name: "Personal Brand Agent" (or similar).
- **Scopes**: select all read + write scopes you want the agent to use. Minimum: contacts, conversations, opportunities, calendars, locations, blogs, social, email templates, custom objects.
- Save. **Copy the token once it's shown — you can't view it again.**

Also grab the **Location ID** from Settings → Company → Locations.

---

## Step 2 — Create the tenant config (~10 min)

On your laptop, in your local clone of the brand-repo:

```bash
cp vps-setup/tenants/EXAMPLE_TENANT.yml vps-setup/tenants/acme.yml
```

Edit `vps-setup/tenants/acme.yml`. Required fields:

```yaml
tenant_id: acme                            # short slug — drives Linux user, paths, etc
person_full_name: "Acme Founder Name"
person_first_name: "Founder"
person_role_description: "founder of Acme, a B2B SaaS for X"
contact_email: "founder@acme.com"
website_url: "https://acme.com"
timezone: "America/New_York"

linux_user: acme                           # OPTIONAL — defaults to tenant_id

brand_repo_url: "git@github.com:acme/brand-canon.git"
brand_repo_branch: "main"
brand_repo_name: "acme-brand-canon"

# Brand canon paths (relative to brand_repo root)
voice_playbook_path: "voice/playbook.md"
response_playbook_path: "voice/responses.md"
services_doc_path: "services.md"
content_strategy_path: "content/strategy.md"
narrative_core_path: "narrative.md"
email_templates_path: "voice/email-templates.md"
rss_sources_path: "content/rss.md"

# Hard banlist — never appear in client-facing output
entity_separation_terms:
  - "ParentCo Inc."
  - "OtherBrand"

voice_archetype_primary: "Sage"
voice_archetype_secondary: "Hero"
voice_descriptors: ["concise", "confident", "no fluff"]
voice_emoji_policy: "no emojis ever in client copy"

ghl_enabled: true
ghl_location_id_env: "GHL_LOCATION_ID"
ghl_pit_env: "GHL_API_KEY"

telegram_enabled: true
telegram_bot_username: "acme_chief_bot"

morning_brief_time: "08:00:00"
evening_rollup_time: "17:30:00"

# Tenant-specific sub-agent personas (these get appended to base prompts)
comms_agent_role: "drafts founder-led B2B outreach for Acme."
pipeline_agent_role: "summarizes Acme's GHL pipeline, focused on enterprise deals."
content_agent_role: "drafts thought-leadership for Acme's blog and LinkedIn."
research_agent_role: "researches enterprise prospects before founder-led calls."
drift_scanner_role: "audits Acme's published content for off-brand language."

protected_paths:
  - "/opt/acme/source/"
  - "/etc/"
  - "/var/www/"

agent_git_email: "agent@acme.com"

features:
  morning_brief: true
  evening_rollup: true
  stale_watcher: true
  task_ledger: true
  markdownv2_default: true
  gh_repo_commits: true

created_at: "2026-04-30"
version: "1.0.0"
owner: "founder@acme.com"
```

### Render to verify

```bash
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/acme.yml
```

This produces `vps-setup/agents-config/acme/` — a directory with all the rendered files. Inspect them. If any file has unresolved `{{TENANT_*}}` placeholders, the render script will WARN — fix the missing values in your YAML and re-render.

Commit and push:
```bash
git add vps-setup/tenants/acme.yml vps-setup/agents-config/acme/
git commit -m "Add tenant: acme"
git push
```

---

## Step 3 — Bootstrap the VPS (~20 min, mostly automated)

SSH into the target Vultr box as root. Then:

```bash
git clone https://github.com/newmindsgroup/{{TENANT_BRAND_REPO_NAME}}.git /tmp/agent-stack
cd /tmp/agent-stack
sudo bash vps-setup/scripts/bootstrap-tenant.sh vps-setup/tenants/acme.yml
```

The bootstrap script does **everything that doesn't require a browser**:
- Creates the `acme` Linux user.
- Installs Node 20, Bun, Claude Code, jq, tmux if missing.
- Clones the brand canon repo as the `acme` user.
- Copies the rendered config into `/opt/acme/agents/`.
- Installs systemd units (renamed/scoped per tenant).

It then prints the three remaining manual steps (A, B, C below).

---

## Step 4 — The three manual steps (~15 min)

### A. Claude Code auth (subscription)

```bash
sudo -u acme -H tmux new -s claude-setup
# inside tmux:
claude --dangerously-skip-permissions
```

Choose "Login with subscription." Browser opens, click Authorize, paste the code back into the terminal. Exit Claude Code (`/quit`), then `tmux kill-session -t claude-setup`.

> **Note:** the agent for tenant N runs as the `acme` Linux user. Each Linux user has its own `~/.claude/` so each tenant has its own Claude Code OAuth credential. **You'll be authing with your one Anthropic Max subscription** — that's fine, the credential is per-machine-user, not per-Anthropic-account-per-machine. One Max subscription can power multiple tenants on the same box, each with its own session.

### B. Telegram bot pairing

Place the bot token:

```bash
mkdir -p /opt/acme/.claude/channels/telegram
echo 'TELEGRAM_BOT_TOKEN=<paste-token>' > /opt/acme/.claude/channels/telegram/.env
chown -R acme:acme /opt/acme/.claude
chmod 600 /opt/acme/.claude/channels/telegram/.env
```

Start the agent:

```bash
systemctl start claude-agent.service
```

Now in Claude Code (you can `tmux attach -t claude` to see it), install the Telegram plugin and configure:

```
/plugin install telegram@claude-plugins-official
/reload-plugins
/telegram:configure <paste-bot-token>
```

Then DM your new bot anything (`@acme_chief_bot`) — it replies with a 6-character pairing code. Back in Claude Code:

```
/telegram:access pair <code>
/telegram:access policy allowlist
```

Verify by DMing the bot. It should respond.

### C. GHL credentials

Render the `.mcp.json` from the example:

```bash
cat /tmp/agent-stack/vps-setup/agents-config/acme/.mcp.json.example
```

Substitute:
- `${GHL_PRIVATE_INTEGRATIONS_TOKEN}` → your GHL PIT
- `${GHL_LOCATION_ID}` → your Location ID

Save the rendered file as `/opt/acme/agents/.mcp.json`:

```bash
chmod 600 /opt/acme/agents/.mcp.json
chown acme:acme /opt/acme/agents/.mcp.json
```

(If you also want a self-hosted GoHighLevel-MCP server alongside the connector, clone `mastanley13/GoHighLevel-MCP` to `/opt/acme/agents/ghl-mcp/` and `npm install --omit=dev && npx tsc`. Otherwise the `.mcp.json.example` registers it as a stdio MCP that Claude Code spawns directly.)

Restart the agent so it picks up the new MCP:

```bash
systemctl restart claude-agent.service
systemctl start morning-brief.timer evening-rollup.timer stale-watcher.timer
```

---

## Step 5 — Smoke test (~5 min)

DM the new bot:

> What do you know about me?

The agent should reply with content pulled from the brand canon — voice DNA, services, narrative core. If it does, the tenant is live.

Try the systemd timers manually:

```bash
systemctl start morning-brief.service        # forces a brief now
journalctl -u morning-brief.service -f       # watch logs
```

The brief should arrive in Telegram within ~2 minutes.

---

## What's the same vs. different across tenants

**Same (engine — `agent-template/`):**
- Sub-agent definitions (with persona placeholders)
- All scripts (`tg-send.sh`, `task-ledger.sh`, `morning-brief.sh`, `evening-rollup.sh`, `stale-watcher.sh`, etc.)
- All systemd units (with user/path placeholders)
- Permission allow/deny structure
- 12-command Telegram slash menu structure
- Task ledger schema and lifecycle states
- MarkdownV2 formatting rules

**Different (per `tenants/{tenant_id}.yml`):**
- Identity, role, contact info, website, timezone
- Brand canon repo URL + paths within it
- Voice archetype, descriptors, banned phrases, emoji policy
- Entity-separation terms (the hard banlist)
- GHL location + token (via env-var name only)
- Telegram bot username + chat-ID env var
- Schedule times (morning, evening, stale watcher window)
- Sub-agent personas (one-line role descriptions)
- Protected paths (per-VPS layout)

---

## When you change the engine (template) for one tenant, propagate to all

If you patch `vps-setup/agent-template/CLAUDE.md.tmpl` (e.g. fix a bug in the slash command routing), every tenant needs to be re-rendered and re-deployed:

```bash
# On your laptop
for t in vps-setup/tenants/*.yml; do
  bash vps-setup/scripts/render-tenant.sh "$t"
done
git add -A && git commit -m "Re-render all tenants after template fix" && git push

# On each VPS
cd /tmp/agent-stack && git pull
sudo cp vps-setup/agents-config/{tenant_id}/CLAUDE.md /opt/{user}/agents/CLAUDE.md
sudo cp vps-setup/agents-config/{tenant_id}/.claude/agents/*.md /opt/{user}/agents/.claude/agents/
sudo systemctl restart claude-agent.service
```

For a clean redeploy, `bootstrap-tenant.sh` is idempotent — re-running it on the VPS will refresh files but won't recreate the user, won't overwrite credentials, and won't restart already-running services unless something changed.

---

## Cost per tenant

| Line item | Per tenant |
|---|---|
| Vultr VPS (1 GB / 1 vCPU) | $6/mo (or share Daniel's box for $0 incremental) |
| Anthropic LLM | $0 — covered by your existing Max subscription |
| Telegram bot | Free |
| GHL Private Integrations Token | Already included in your GHL sub-account |
| **Total** | **$6/mo or less** |

Three tenants on three separate boxes: $18/mo. Three tenants on the same box (recommended): $6/mo.

---

## Common gotchas

1. **`bun` not found** — Bun is per-user. Make sure the symlink at `/usr/local/bin/bun` points to the new tenant's bun, OR install bun system-wide. The bootstrap script handles this for the first tenant; subsequent tenants share `/usr/local/bin/bun`.
2. **Telegram allowlist drops messages silently** — if you forget step B's `/telegram:access policy allowlist`, the bot will respond to anyone who knows the username. Lock it down.
3. **MarkdownV2 escaping** — `+` `-` `.` `(` `)` and a long list of others must be escaped with `\`. The agent's CLAUDE.md has the full list. If a Telegram message fails to send with "Bad Request: can't parse entities," it's an unescaped char.
4. **GHL PIT shown only once** — if you didn't save it, you have to delete the integration in GHL settings and create a new one. There's no "show again."
5. **One Linux user can't access another's `~/.claude/`** — that's correct; each tenant's Claude session is isolated. If you need cross-tenant data, do it through git or an external store, never through the filesystem.

---

*Last updated: 2026-04-30. Companion to `vps-setup/README.md` (single-tenant runbook) and `vps-setup/FEATURE_INVENTORY.md` (capability catalog).*
