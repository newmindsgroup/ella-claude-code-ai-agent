# Deploying a Fresh Agent for a New Client

This is the master runbook for the local-Claude-orchestrated deployment of a fresh agent on a new VPS for a new client. It's referenced by [`NEW-CLIENT-CLAUDE.md`](../NEW-CLIENT-CLAUDE.md) which is the actual file the local Claude reads at the start of a deploy.

**Read this end-to-end before starting your first deploy.** Subsequent deploys will go fast.

---

## Pre-flight (human-only work — Claude cannot do these)

Complete the checklist at the bottom of [`examples/client-credentials.template.md`](../examples/client-credentials.template.md). The most-forgotten items:

1. **Telegram bot via @BotFather** — Claude can configure the bot (commands, description, menu button), but only YOU can create it via the Telegram app. 60 seconds.
2. **Your Telegram user_id from @userinfobot** — Claude needs this to allowlist you.
3. **Cloudflare Origin Cert generated + saved** — Cloudflare's free PKI. Lasts 15 years. Generate per-domain (or per-wildcard). Claude can paste it onto the VPS, but can't generate it for you.
4. **VPS provisioned with root SSH access** — Vultr/DO/Hetzner. Note the IP. Confirm `ssh root@<ip> 'whoami'` returns `root` from your Mac.

If you skip any of these, the pre-flight script fails fast.

---

## Workspace layout

Your local workspace should look like this BEFORE starting the deploy:

```
~/code/<client>-workspace/
├── client-credentials.md      ← copied from examples/client-credentials.template.md, all slots filled in
├── client-context.md          ← what you know about the client + brand + business
├── memory/                    ← (optional) prior memory accumulated for this client
│   └── *.md
├── NEW-CLIENT-CLAUDE.md       ← orchestrator instructions, will be created in step 1
└── <client>-agent/            ← will be created in step 2 (cloned Ella template)
```

The `client-credentials.md` lives OUTSIDE the cloned repo so it's never accidentally committed.

---

## Phase 1 — Local prep (5 min)

### 1.1 Create workspace

```bash
mkdir -p ~/code/<client>-workspace
cd ~/code/<client>-workspace
```

### 1.2 Copy templates

```bash
# Get the latest Ella template
git clone --depth=1 https://github.com/newmindsgroup/ella-claude-code-ai-agent /tmp/ella-tmp
cp /tmp/ella-tmp/examples/client-credentials.template.md client-credentials.md
cp /tmp/ella-tmp/NEW-CLIENT-CLAUDE.md NEW-CLIENT-CLAUDE.md
rm -rf /tmp/ella-tmp
```

### 1.3 Fill in client-credentials.md

Open `client-credentials.md` and fill in every `REQUIRED` slot. The file has comments explaining where each value comes from. Tick the checklist at the bottom.

### 1.4 Write client-context.md

A few paragraphs (or pages) about the client + brand + business. The local Claude reads this to generate `vps-setup/tenants/<client-id>.yml` content (brand voice, services, banned phrases, entity separation, etc.). If you're keeping a brand canon repo elsewhere, you can mostly delegate the voice + visual content to that repo and just give Claude a one-paragraph summary here.

---

## Phase 2 — Deploy orchestration (local Claude does the rest)

Open Claude Code in `~/code/<client>-workspace/`:

```bash
cd ~/code/<client>-workspace
claude
```

Then say:

> *"Deploy a fresh agent for this client following NEW-CLIENT-CLAUDE.md"*

The local Claude reads `NEW-CLIENT-CLAUDE.md` + `client-credentials.md` + `client-context.md` and runs the rest of this runbook automatically. Each phase below is something the local Claude executes; the human (you) only intervenes when explicitly asked.

---

## Phase 3 — Clone + sanitize Ella (the local Claude does this)

```bash
# Clone Ella into the client repo
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent <client>-agent
cd <client>-agent

# Reset git history so the client's repo starts clean
rm -rf .git
git init -b main

# Generate the per-client tenant.yml from the credentials + context files
# (the local Claude does this — handcrafting YAML from context+credentials)
cp vps-setup/tenants/EXAMPLE_TENANT.yml vps-setup/tenants/<client-id>.yml
# Then edit <client-id>.yml inline with all the per-client values
```

The local Claude generates the tenant.yml programmatically from `client-credentials.md` + `client-context.md`. Every `{{TENANT_*}}` placeholder in the template gets a real value.

---

## Phase 4 — Pre-flight check (validates every credential works)

```bash
bash vps-setup/scripts/preflight-new-client.sh ~/code/<client>-workspace/client-credentials.md
```

The pre-flight script tests EVERY external dependency before any state is mutated:

- `ssh -o ConnectTimeout=5 <vps_root_user>@<vps_ip> 'whoami'` — VPS reachable + auth works
- `dig <agent_subdomain> @1.1.1.1` — DNS resolves (OR you'll create the record in Phase 6)
- `curl -H "Authorization: Bearer <github_pat>" https://api.github.com/user` — PAT valid
- `curl -H "Authorization: Bearer <cloudflare_api_token>" https://api.cloudflare.com/client/v4/user/tokens/verify` — CF token valid
- `curl https://api.telegram.org/bot<telegram_bot_token>/getMe` — bot token valid + bot exists
- `curl -H "Authorization: Bearer <ghl_pit_token>" https://services.leadconnectorhq.com/locations/<ghl_location_id>` — GHL creds (if crm: ghl)
- `gh auth status` — local gh CLI is auth'd (matches github_pat OR has equivalent scope)

If any check fails, the deploy STOPS HERE. Fix the credential, re-run pre-flight.

---

## Phase 5 — VPS bootstrap (the local Claude SSH's in)

The local Claude SSH'es into the VPS as root and runs the agent stack installers:

### 5.1 Install Claude Code + dependencies

```bash
# On VPS as root:
apt-get update && apt-get install -y curl git jq nginx python3-pip python3-yaml ffmpeg
curl -fsSL https://get.docker.com | sh   # only if docker is needed
# Install Node.js 20+ (for npm + bun)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g @anthropic-ai/claude-code
```

### 5.2 Create tenant user

```bash
useradd -m -s /bin/bash <linux_user>
usermod -aG sudo <linux_user>  # for the targeted sudoers grant below
mkdir -p /opt/<linux_user>
chown <linux_user>:<linux_user> /opt/<linux_user>
```

### 5.3 Render tenant locally + scp to VPS

```bash
# On local Mac:
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<client-id>.yml
# scp the rendered tree to the VPS
rsync -av vps-setup/agents-config/<client-id>/ root@<vps_ip>:/tmp/<client-id>-rendered/
```

### 5.4 Bootstrap on VPS

```bash
# On VPS as root:
bash /tmp/<client-id>-rendered/scripts/install-all.sh   # if this script exists in the template
# OR run the manual steps that bootstrap-tenant.sh would do:
# - copy CLAUDE.md, .claude/settings.json, agents, scripts
# - install systemd units (.service + .timer files)
# - install nginx vhost
# - generate htpasswd for dashboard basic-auth
# - install sudoers entry
# - generate SSH key for the agent user
```

The Ella template includes a `bootstrap-tenant.sh` (or equivalent) that wraps all of this — see `vps-setup/scripts/`.

### 5.5 Authenticate Claude Code on the VPS

```bash
# On VPS, as the tenant user:
sudo -u <linux_user> -H claude login
# This opens a browser link on your LOCAL Mac (since the VPS is headless).
# Visit it in your browser, sign in with the client's Anthropic account, paste the code back.
```

This is the ONE interactive step the human can't skip — Anthropic OAuth requires a browser. ~30 seconds.

---

## Phase 6 — DNS + TLS (Cloudflare)

The local Claude creates the DNS records via Cloudflare API:

```bash
# Add A records for each subdomain → vps_ip
for sub in ella blueprint new; do
  curl -X POST "https://api.cloudflare.com/client/v4/zones/<cloudflare_zone_id>/dns_records" \
    -H "Authorization: Bearer <cloudflare_api_token>" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"$sub\",\"content\":\"<vps_ip>\",\"ttl\":120,\"proxied\":true}"
done
```

Then installs the Cloudflare Origin Cert on the VPS:

```bash
# On VPS as root:
echo "<tls_cert_content>" > /etc/ssl/certs/<root_domain>-origin.crt
echo "<tls_key_content>"  > /etc/ssl/private/<root_domain>-origin.key
chmod 644 /etc/ssl/certs/<root_domain>-origin.crt
chmod 600 /etc/ssl/private/<root_domain>-origin.key
```

Tests nginx config + reloads:

```bash
nginx -t && systemctl reload nginx
```

---

## Phase 7 — Telegram bot finalization

The local Claude:

1. Writes `/opt/<linux_user>/.claude/channels/telegram/.env` with the bot token
2. Writes `/opt/<linux_user>/.claude/channels/telegram/access.json` with the user_id allowlist + ackReaction emoji
3. Runs `bash {agent_home}/scripts/setup-bot-identity.sh` to set bot commands menu + description
4. Sends a test message to the bot's chat: `bash {agent_home}/scripts/tg-send.sh send --text "🚀 Agent online. Send /brief to fire your morning brief."`

The user (you) receives the test message in Telegram. **Reply with anything** to confirm two-way communication.

---

## Phase 8 — Apply channels-plugin patches + restart agent

```bash
# On VPS as root:
bash /opt/<linux_user>/agents/scripts/patch-channels-plugin.sh   # 5 passes
systemctl restart claude-agent.service                            # ExecStartPre re-applies patches
sleep 5
systemctl is-active claude-agent.service                          # must return 'active'
```

---

## Phase 9 — Enable all timers + verify

```bash
# On VPS as root:
for t in morning-brief evening-rollup stale-watcher task-deadline-watcher \
         goal-deadline-watcher stalled-deal-watcher disk-space-watcher \
         hot-lead-inbox-watcher calendar-conflict-watcher graphify-rebuild \
         telegram-poller-watchdog; do
  systemctl enable --now "$t.timer" 2>/dev/null || echo "  skip $t (no .timer)"
done
```

---

## Phase 10 — Smoke test (the gate)

```bash
# On VPS as the tenant user:
sudo -u <linux_user> bash /opt/<linux_user>/agents/scripts/smoke-test.sh
```

Expected: **all PASS, 0 FAIL**. Some sections may WARN at certain times of day (e.g. "today's proposals not yet generated" at 06:00). Hard fails block "deployment done."

If smoke test passes:

```bash
# Ping you on Telegram:
sudo -u <linux_user> bash /opt/<linux_user>/agents/scripts/tg-send.sh send --text \
  "✅ Deployment complete for <client_brand_name>.
   Dashboard: https://<agent_subdomain>/
   Bot: @<telegram_bot_username>
   Smoke test: PASS"
```

---

## Phase 11 — Push the client repo to GitHub

```bash
# On local Mac:
cd ~/code/<client>-workspace/<client>-agent
git add .
git commit -m "feat: initial client deployment for <client_brand_name>"
gh repo create <github_repo_owner>/<github_repo_name> --<github_repo_visibility> --source=. --remote=origin --push
```

The client now has their own GitHub repo (private by default), cloned from Ella, with their tenant config committed. Future updates flow Mac → GitHub → VPS via the same deploy pipeline.

---

## Phase 12 — Archive client-credentials.md

After successful deploy, the `client-credentials.md` file on your local Mac is no longer NEEDED for the agent to run (the VPS has its own copies of what it requires).

Recommended:
1. Encrypt + archive to your password manager OR a 1Password vault
2. Remove from `~/code/<client>-workspace/`
3. Keep `client-context.md` and `memory/` — those ARE needed for ongoing work

---

## Rollback strategy (if a phase fails mid-deploy)

| Phase | If it fails | How to recover |
|---|---|---|
| 1–4 (local) | Pre-flight catches it | Fix the credential, re-run preflight |
| 5 (VPS bootstrap) | claude-agent.service won't start | `journalctl -u claude-agent.service -n 50` — almost always a missing dependency or bad CLAUDE.md syntax |
| 6 (DNS) | Cloudflare API rejects | Verify zone_id matches the domain in question; verify token scope includes Zone:DNS:Edit |
| 7 (Telegram) | Bot doesn't reply | Check access.json — `allowFrom` must include YOUR user_id; restart agent |
| 8 (patches) | TS compile fails after patch | Restore from `/opt/<linux_user>/.claude/plugins/cache/.../server.ts.bak-*`, investigate which pass broke |
| 9 (timers) | Timer enable fails | Check unit syntax via `systemd-analyze verify /etc/systemd/system/<name>.timer` |
| 10 (smoke test) | One check fails | Read the failure message; the smoke test names the issue |

**No phase mutates external state irreversibly.** A failed deploy leaves: a VPS with some services running, a Cloudflare zone with some DNS records, a GitHub repo (if you got to phase 11). All cleanable. None destroy data.

---

## What about clients without GHL?

Set `crm: none` in client-credentials.md and `ghl_enabled: false` in the rendered tenant.yml. Three watchers (stalled-deal, hot-lead-inbox) won't fire, and the pipeline sub-agent won't have a backend — but the rest of the stack (morning brief, voice, dashboard, ops wrappers) still works.

To add HubSpot / Pipedrive / Salesforce: add a new MCP under `.mcp.json` + write a `hubspot-pipeline-watcher.sh` modeled on `stalled-deal-watcher.sh` (same pattern, different REST endpoint). The runbook recipe is in [ai-agent-skills-library/runbooks/proactive-watcher-pattern.md](https://github.com/newmindsgroup/ai-agent-skills-library/blob/main/runbooks/proactive-watcher-pattern.md).
