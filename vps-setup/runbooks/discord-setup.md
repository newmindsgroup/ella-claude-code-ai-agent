# Discord Setup Runbook

Discord is an OPTIONAL second command surface for the agent. When enabled, it provides:

- **#commands** — type any agent prompt (the agent reads every 60s, executes, posts result back)
- **#memory-\*** channels (facts, decisions, relationships, patterns, commitments, preferences) — every memory the vault adds shows up here as a rich-embed post; conversely, anything you type in these channels gets imported into the memory vault on the next 10-min sync
- **#task-events** — per-task threads, with state transitions logged
- **#agent-log** — every meaningful state change in the agent stack
- **#daily-brief** — morning brief mirror + weekly memory digest (Fridays 17:00 tenant-TZ)
- **#intel** — research summaries from `research-agent`
- **#ghl-activity** — pipeline + contact events from the GHL webhook
- **#gmail-alerts** — hot-lead detections from the inbox watcher

It's NOT a Telegram replacement — it's a separate surface optimized for richer formatting, searchable history, threads, and parallel conversations. The tenant keeps Telegram as the primary "talking to my agent on my phone" channel and Discord as the "command center I open on my desktop."

## Setup (~10 minutes)

### Step 1 — Create the Discord server + bot

1. Open Discord → click `+` (bottom-left) → **Create My Own** → **For me and my friends**
2. Name it (e.g. "{{client_brand_name}} — Agent Ops")
3. Server name is just for you; not public-facing.

Then create the bot application:
1. Go to https://discord.com/developers/applications
2. Click **New Application** → name it (e.g. "{{client_brand_name}}-AgentBot")
3. **Bot** tab on the left → **Add Bot**
4. **Privileged Gateway Intents** → toggle ON: `MESSAGE CONTENT INTENT`. Save.
5. **Reset Token** → copy the token. **Save it in `client-credentials.md`** under `discord_bot_token`. You can't view it again.

Install the bot to your server:
1. **OAuth2** → **URL Generator** → check scopes: `bot` + `applications.commands`
2. Bot permissions: `Send Messages`, `Read Message History`, `Embed Links`, `Manage Threads`, `Use Slash Commands` (and `Read Messages/View Channels`)
3. Copy the generated URL → paste in browser → select your server → **Authorize**

### Step 2 — Enable Developer Mode

In Discord: **User Settings → Advanced → Developer Mode** = ON. This lets you right-click anything to copy IDs.

### Step 3 — Create the channel structure

In your new server, create channels (use the `+` next to "TEXT CHANNELS"):

**Category: 📋 OPS**
- `#commands` — bidirectional (you type, agent reads + responds)
- `#agent-log` — agent activity stream
- `#task-events` — per-task threads
- `#daily-brief` — morning brief + weekly digest

**Category: 🧠 MEMORY**
- `#memory-facts`
- `#memory-decisions`
- `#memory-relationships`
- `#memory-patterns`
- `#memory-commitments`
- `#memory-preferences`
- `#memory-goals`
- `#memory-context`

**Category: 📡 INTEL**
- `#intel` — research outputs
- `#ghl-activity` — pipeline + contact events
- `#gmail-alerts` — hot leads

After each channel: right-click → **Copy Channel ID** → save in `client-credentials.md` under the corresponding `discord_ch_*` slot.

Also right-click your server name → **Copy Server ID** → save as `discord_guild_id`.
And right-click your own username → **Copy User ID** → save as `discord_owner_user_id`.

### Step 4 — Wire credentials onto the VPS

The `vps-setup/agent-template/channels-discord/.env.discord.template` is your reference. During deploy, the orchestrator writes a `.env` file at `{{TENANT_AGENT_HOME}}/.env` containing all `DISCORD_*` variables. The discord scripts source this on every invocation.

If deploying manually:
```bash
ssh root@<vps_ip>
cd /opt/<tenant>/agents
sudo -u <tenant> nano .env   # paste the contents of .env.discord.template with real values
```

### Step 5 — Enable the systemd service + crontab entries

```bash
# Install discord-webhook-server.service
sudo cp /opt/<tenant>/agents/scripts/../systemd/discord-webhook-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now discord-webhook-server.service

# Install crontab entries (the tenant.crontab.tmpl ships them; just uncomment the Discord lines)
sudo crontab -u <tenant> -e
# Uncomment the discord-commands, discord-corpus-sync, discord-memory-digest lines
```

The orchestrator handles all this if `discord_enabled: true` in tenant.yml.

### Step 6 — Confirm two-way comms

In Discord, type in `#commands`:
```
ping
```

Within 60 seconds the agent should respond in the same channel. If not:
- `journalctl -u discord-webhook-server.service -n 50` on the VPS for server errors
- `tail -50 {agent_home}/logs/discord-commands.log` for poller errors
- Verify `DISCORD_BOT_TOKEN` is correct + `MESSAGE CONTENT INTENT` is ON in the dev portal

### Step 7 — Configure webhook URLs (optional)

If you want GHL events to flow into `#ghl-activity` and Gmail webhooks to flow into `#gmail-alerts`:

1. The agent runs `discord-webhook-server.js` on port 8090
2. Add nginx vhost block:
```nginx
location /webhooks/ghl {
  proxy_pass http://127.0.0.1:8090/ghl;
}
location /webhooks/gmail {
  proxy_pass http://127.0.0.1:8090/gmail;
}
```
3. Configure GHL webhooks to POST to `https://<agent_subdomain>/webhooks/ghl`
4. Configure Gmail push notifications (or webhook forwarder) to POST to `/webhooks/gmail`

## How Discord and Telegram differ in usage

| | Telegram | Discord |
|---|---|---|
| Best for | Phone-first, voice notes, one-tap approvals | Desktop, rich history, threads, parallel work |
| Memory writes | Echoed as one-line confirmations | Posted as rich embeds in #memory-* channels |
| Memory reads | `/recall` slash command (text result) | Browse the channel history (Discord's search) |
| Task tracking | Approval buttons inline | Per-task threads in #task-events |
| Voice notes | Native (whisper.cpp + edge-tts) | Not yet — Telegram is the voice surface |
| Commands | Slash commands or natural language | Type in #commands, agent polls every 60s |

You can run with EITHER, BOTH, or NEITHER. The agent stack works fine without Discord. Telegram is the minimum for "talk to my agent."
