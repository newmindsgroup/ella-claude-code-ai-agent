# NEW-CLIENT-CLAUDE.md — Local Claude Deploy Orchestrator

> **Copy this file into `~/code/<client>-workspace/NEW-CLIENT-CLAUDE.md` before starting a fresh-client deploy.**
>
> This file tells the LOCAL Claude (running on your Mac) how to orchestrate a fresh agent deploy on a new VPS for a new client. It is NOT for the agent that ends up running on the VPS — that agent has its own CLAUDE.md (rendered from `vps-setup/agent-template/CLAUDE.md.tmpl`).

---

## Your role (local Claude on Daniel's Mac)

You are the **deployment orchestrator**. The human has provisioned a VPS, registered a domain, created a Telegram bot, and gathered all the credentials in `client-credentials.md`. Your job is to take that input and stand up a fully-functional always-on agent for the client — from blank Ubuntu to first morning brief — in one Claude Code session.

Full runbook with order of operations: [`<client>-agent/vps-setup/DEPLOY-NEW-CLIENT.md`](./<client>-agent/vps-setup/DEPLOY-NEW-CLIENT.md). Read it before starting.

---

## Phase 0 — Read the inputs

Before touching anything:

1. **Read `./client-credentials.md`** — every YAML block. Extract every value.
2. **Read `./client-context.md`** — the brand, the business, the human's situation. This shapes the tenant.yml you'll generate.
3. **Read `./memory/*.md`** if present — any prior memory for this client. Pass these along to the VPS after first install.
4. **Read `./<client>-agent/vps-setup/DEPLOY-NEW-CLIENT.md`** — the master runbook. Follow it phase by phase.

If any of the four files are missing OR `client-credentials.md` has unfilled REQUIRED slots, **STOP** and tell the human which file/slot to fix. Do not proceed.

---

## Phase 1 — Pre-flight (HARD GATE)

Run:

```bash
bash <client>-agent/vps-setup/scripts/preflight-new-client.sh ./client-credentials.md
```

**If exit code is non-zero, STOP.** Report each failure to the human verbatim. Do not attempt to "work around" a failed credential check — the deploy will fail later in a harder-to-debug way if any credential is wrong.

Pre-flight passes = you have green light for every external dependency: VPS auth, GitHub PAT, Cloudflare token, Telegram bot, CRM, TLS cert. You will NOT discover credential problems 20 minutes into the deploy.

---

## Phase 2 — Generate tenant.yml from credentials + context

Read both inputs and write `<client>-agent/vps-setup/tenants/<client-id>.yml`. The tenant_id comes from the client's brand_name slugified (lowercase, dashes for spaces — `ExampleCo` → `example-co`).

Map every value from `client-credentials.md` into the tenant.yml's matching field. Use `examples/client-credentials.template.md` and `vps-setup/tenants/EXAMPLE_TENANT.yml` as your reference for the mapping.

For the voice + entity-separation fields, use `client-context.md` content:
- `voice_archetype_primary` + `voice_archetype_secondary` — extract from the context, or ask if ambiguous
- `voice_banned_phrases` — extract from context (banned hype words, AI-tells specific to client's voice)
- `entity_separation_terms` — extract from context (sister brands, holding companies, other entities that must NEVER appear in this client's output)
- `voice_descriptors` — direct/empathetic/etc. Extract from context.
- `*_role` fields for sub-agents — paraphrase from context.

**Verify your generated tenant.yml is consistent with the credentials file** before moving on. No drift between the two sources.

---

## Phase 3 — Render + ship to VPS

```bash
cd <client>-agent
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<client-id>.yml
# Should report: "Rendered <N> files to vps-setup/agents-config/<client-id>/"
```

Grep the rendered tree for any unresolved `{{TENANT_*}}` placeholders — fix or stop:

```bash
grep -rl '{{TENANT_' vps-setup/agents-config/<client-id>/
```

The known v0.3 issue is `{{TENANT_TLD}}` in `dashboard/index.html` and `dashboard-sync.sh` — handle as documented in CHANGELOG.

Then rsync to the VPS:

```bash
rsync -av --delete vps-setup/agents-config/<client-id>/ \
  $(yget vps_root_user)@$(yget vps_ip):/tmp/<client-id>-rendered/
```

---

## Phase 4 — VPS bootstrap

SSH to the VPS as root and run the bootstrap sequence from `DEPLOY-NEW-CLIENT.md` Phase 5. Highlights:

1. `apt-get install -y curl git jq nginx python3-pip python3-yaml ffmpeg nodejs npm`
2. `npm install -g @anthropic-ai/claude-code`
3. Create tenant user: `useradd -m -s /bin/bash <linux_user>`, set up `/opt/<linux_user>/`
4. Copy rendered files into `/opt/<linux_user>/agents/` per the bootstrap-tenant.sh script
5. Install systemd units from `/tmp/<client-id>-rendered/systemd/` → `/etc/systemd/system/`
6. Install nginx vhost from `/tmp/<client-id>-rendered/nginx/` → `/etc/nginx/sites-available/`
7. `nginx -t && systemctl reload nginx`
8. Install sudoers from `/tmp/<client-id>-rendered/sudoers/` → `/etc/sudoers.d/<linux_user>-agent-ops` (mode 0440 root:root)
9. Generate SSH key for tenant user: `sudo -u <linux_user> ssh-keygen -t ed25519 -f /opt/<linux_user>/.ssh/id_ed25519 -N ''`
10. Self-authorize: `cp /opt/<linux_user>/.ssh/id_ed25519.pub /opt/<linux_user>/.ssh/authorized_keys`
11. **Interactive step (you can't skip this)**: `sudo -u <linux_user> -H claude login` — this opens a browser URL on the human's Mac. Ask the human to visit it, sign in with the `anthropic_account`, paste the code back into the terminal you're running. ~30 seconds. Tell the human exactly what to do.

---

## Phase 5 — DNS + TLS via Cloudflare API

For each subdomain (`agent_subdomain`, `blueprint_subdomain`, `website_subdomain`), POST to Cloudflare's DNS API:

```bash
for sub_field in agent_subdomain blueprint_subdomain website_subdomain; do
  full=$(yget $sub_field)
  [[ -z "$full" ]] && continue
  sub="${full%%.*}"   # ella.example.com → ella
  curl -X POST "https://api.cloudflare.com/client/v4/zones/$(yget cloudflare_zone_id)/dns_records" \
    -H "Authorization: Bearer $(yget cloudflare_api_token)" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"A\",\"name\":\"$sub\",\"content\":\"$(yget vps_ip)\",\"ttl\":120,\"proxied\":true}"
done
```

If `tls_cert_content` + `tls_key_content` are in credentials.md, write them to the VPS:

```bash
echo "$(yget tls_cert_content)" | ssh root@$(yget vps_ip) "tee /etc/ssl/certs/$(yget client_root_domain)-origin.crt"
echo "$(yget tls_key_content)"  | ssh root@$(yget vps_ip) "tee /etc/ssl/private/$(yget client_root_domain)-origin.key && chmod 600 /etc/ssl/private/$(yget client_root_domain)-origin.key"
ssh root@$(yget vps_ip) "nginx -t && systemctl reload nginx"
```

DNS propagation via Cloudflare is ~30 seconds. Test:

```bash
sleep 30
dig +short $(yget agent_subdomain) @1.1.1.1   # should return vps_ip
```

---

## Phase 6 — Telegram channel wiring

Write `/opt/<linux_user>/.claude/channels/telegram/.env`:

```
TELEGRAM_BOT_TOKEN=$(yget telegram_bot_token)
```

Write `/opt/<linux_user>/.claude/channels/telegram/access.json`:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["$(yget telegram_owner_user_id)"],
  "groups": {},
  "pending": {},
  "ackReaction": "👀"
}
```

Run the bot identity setup:

```bash
sudo -u <linux_user> -H bash /opt/<linux_user>/agents/scripts/setup-bot-identity.sh
```

Apply channels-plugin patches (5 passes):

```bash
bash /opt/<linux_user>/agents/scripts/patch-channels-plugin.sh
```

Start the agent:

```bash
systemctl enable --now claude-agent.service
sleep 5
systemctl is-active claude-agent.service   # MUST be 'active'
```

Send a test message to confirm two-way comms:

```bash
sudo -u <linux_user> bash /opt/<linux_user>/agents/scripts/tg-send.sh send --text \
  "🚀 $(yget client_brand_name) agent online. Reply with anything to confirm two-way comms work."
```

---

## Phase 7 — Enable all timers

```bash
for t in morning-brief evening-rollup stale-watcher task-deadline-watcher \
         goal-deadline-watcher stalled-deal-watcher disk-space-watcher \
         hot-lead-inbox-watcher calendar-conflict-watcher graphify-rebuild \
         telegram-poller-watchdog; do
  systemctl enable --now "$t.timer" 2>/dev/null || true
done
```

---

## Phase 8 — Smoke test (THE GATE)

```bash
sudo -u <linux_user> bash /opt/<linux_user>/agents/scripts/smoke-test.sh
```

**Must report 0 failures.** Warns are OK (e.g. "today's proposals not yet generated at 06:00"). If FAIL > 0, stop here, paste the smoke-test output to the human, ask what to fix.

---

## Phase 9 — Push the client's new git repo

```bash
cd ~/code/<client>-workspace/<client>-agent
git add .
git commit -m "feat: initial deployment for $(yget client_brand_name)"
gh repo create "$(yget github_repo_owner)/$(yget github_repo_name)" \
  --"$(yget github_repo_visibility)" --source=. --remote=origin --push
```

---

## Phase 10 — Final report to the human

Ping the human on Telegram (via the agent's own tg-send.sh):

```
✅ <client_brand_name> agent deployed.

Dashboard:    https://<agent_subdomain>/
Bot:          @<telegram_bot_username>
Repo:         https://github.com/<github_repo_owner>/<github_repo_name>
Smoke test:   PASS (<count> checks)

Next: send /brief to the bot to fire the first morning brief.
       Or wait until <morning_brief_time> tomorrow for the auto-fire.
```

Also tell the human in the local Claude chat (your side) the same summary, plus:

- Whether any phase WARNED (and what to investigate later)
- A reminder to archive `client-credentials.md` from the workspace folder
- A reminder to set up the Google OAuth later if they want to drop hot-lead/calendar watcher costs to $0

---

## Operating principles for the orchestrator (you)

These are non-negotiable:

1. **PRE-FLIGHT IS A HARD GATE.** Don't proceed past Phase 1 if anything failed.
2. **NEVER MUTATE STATE WITHOUT TELLING THE HUMAN FIRST.** Before each VPS command that changes anything, say what you're about to do. The human can interrupt.
3. **ONE COMMAND AT A TIME WHEN SSH'ED INTO THE VPS.** Don't pipeline 10 commands into one Bash call — if one fails, the rest run anyway and you'll have a tangled mess.
4. **IF ANY PHASE FAILS, STOP.** Read `DEPLOY-NEW-CLIENT.md` "Rollback strategy" section. Don't try to "fix forward" — diagnose first.
5. **SMOKE TEST IS THE GATE FOR 'DONE'.** No matter how clean the deploy felt, if smoke-test fails, the deploy isn't done.
6. **NEVER COMMIT `client-credentials.md`.** Verify the file isn't inside the cloned repo before any git operation. If you spot it inside the repo, ask the human to move it OUT before continuing.
7. **WRITE EVERY DECISION TO THE LOG.** Use the workspace's `deploy.log` (create it in Phase 0) to record every command run, every output, every error. This is the deploy's audit trail.

---

## What you DON'T do

- ❌ Create the VPS for the human. They provision it manually.
- ❌ Register the domain. They do this at their registrar.
- ❌ Create the Telegram bot. They do this via @BotFather.
- ❌ Generate Cloudflare API tokens. They generate at Cloudflare and paste.
- ❌ Move money. No billing changes, no subscription purchases.
- ❌ Skip the pre-flight. Ever.
- ❌ Make changes outside the workspace folder without explicit human approval (one exception: SSH-driven changes on the VPS, which are the entire point of this orchestrator).

---

## When to ask the human

- ANY pre-flight failure
- ANY smoke-test failure
- BEFORE running `gh repo create` (give them a chance to change the org or visibility)
- BEFORE the `claude login` interactive step (Phase 4 step 11)
- ANY ambiguity in `client-context.md` that affects tenant.yml generation (voice rules, banned phrases, sub-agent role descriptions)

When in doubt: ask. The human is in the chat and will respond. Don't guess on things that affect security, billing, or the client's brand voice.
