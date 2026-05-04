# VPS agent configuration — as-built

This directory mirrors what's deployed on the Vultr box at `<your-vps-ip>` under `{{TENANT_AGENT_HOME}}/`. It exists so the chief-of-staff stack can be rebuilt from git on a fresh box, and so changes have a versioned history.

**Layout on the VPS:**

```
{{TENANT_AGENT_HOME}}/
├── CLAUDE.md                                   ← chief-of-staff system prompt
├── .claude/
│   ├── settings.json                           ← project-level permissions (allow + deny)
│   └── agents/
│       ├── comms-agent.md
│       ├── pipeline-agent.md
│       ├── content-agent.md
│       ├── research-agent.md
│       └── drift-scanner.md
├── .mcp.json                                   ← project MCP servers (GHL credentials inside — do NOT commit the live one)
├── scripts/
│   ├── tg-send.sh                              ← Telegram Bot API wrapper
│   └── morning-brief.sh                        ← daily morning brief composer
├── ghl-mcp/                                    ← cloned mastanley13/GoHighLevel-MCP, npm-built dist/
├── {{TENANT_BRAND_REPO_NAME}}/                      ← cloned brand canon (this repo)
├── drafts/
└── logs/
```

**Systemd units (root-installed at `/etc/systemd/system/`):**

- `claude-agent.service` — keeps Claude Code alive in tmux with `--channels` + `--permission-mode dontAsk`
- `morning-brief.service` — oneshot composer
- `morning-brief.timer` — fires `OnCalendar=*-*-* 09:00:00 {{TENANT_TIMEZONE}}` (handles AST↔ADT auto)

**Files in this folder:**

| File | Purpose | Contains secrets? |
| --- | --- | --- |
| `CLAUDE.md` | Chief-of-staff system prompt | No |
| `.claude/agents/*.md` | 5 sub-agent definitions | No |
| `.claude/settings.json` | Permission allow/deny lists | No |
| `.mcp.json.example` | MCP registration template — substitute `${GHL_PRIVATE_INTEGRATIONS_TOKEN}` and `${GHL_LOCATION_ID}` before placing on the VPS as `.mcp.json` | No (template) |
| `scripts/tg-send.sh` | Direct Telegram Bot API wrapper | No (reads token from `~/.claude/channels/telegram/.env` at runtime) |
| `scripts/morning-brief.sh` | Composer + delivery script | No |
| `systemd/*.service`, `*.timer` | Unit files for autostart | No |

## Restoring on a fresh box

After completing `vps-setup/README.md` (the main runbook):

```bash
# As root, after cloning {{TENANT_BRAND_REPO_NAME}} to {{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/
DST={{TENANT_AGENT_HOME}}
SRC={{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/vps-setup/agents-config

# Place the configs
sudo -u {{TENANT_LINUX_USER}} cp "$SRC/CLAUDE.md" "$DST/CLAUDE.md"
sudo -u {{TENANT_LINUX_USER}} mkdir -p "$DST/.claude/agents" "$DST/scripts"
sudo -u {{TENANT_LINUX_USER}} cp "$SRC"/.claude/agents/*.md "$DST/.claude/agents/"
sudo -u {{TENANT_LINUX_USER}} cp "$SRC/.claude/settings.json" "$DST/.claude/settings.json"
sudo -u {{TENANT_LINUX_USER}} cp "$SRC"/scripts/*.sh "$DST/scripts/"
sudo -u {{TENANT_LINUX_USER}} chmod +x "$DST"/scripts/*.sh

# Render .mcp.json with real credentials (do NOT commit the rendered file)
GHL_PIT='pit-...' GHL_LOC='...' \
  envsubst < "$SRC/.mcp.json.example" > "$DST/.mcp.json"
sudo -u {{TENANT_LINUX_USER}} chmod 600 "$DST/.mcp.json"

# Install systemd units
cp "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now claude-agent.service morning-brief.timer
```

## What never gets committed

These files exist on the VPS but are deliberately excluded from git:

- `{{TENANT_AGENT_HOME}}/.mcp.json` (live, with real PIT)
- `{{TENANT_USER_HOME}}/.claude/channels/telegram/.env` (Telegram bot token)
- `{{TENANT_USER_HOME}}/.claude/.credentials.json` (Claude Max OAuth credential)
- `{{TENANT_AGENT_HOME}}/ghl-mcp/.env` (duplicate of MCP credentials, used when running ghl-mcp standalone)
- `{{TENANT_AGENT_HOME}}/drafts/` and `{{TENANT_AGENT_HOME}}/logs/` (generated content)

If the VPS is rebuilt, those secrets are re-issued from their respective sources (BotFather, GHL, Claude login).

---

*Synced from VPS: 2026-04-30 · Companion to `../README.md` (the main provisioning runbook)*
