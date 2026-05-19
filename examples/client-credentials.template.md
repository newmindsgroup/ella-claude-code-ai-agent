# client-credentials.md — TEMPLATE

> **Copy this file into `~/code/<client>-workspace/client-credentials.md` and fill in every slot.**
>
> Keep it OUTSIDE the cloned agent repo. Never commit it. Add it to your local `.gitignore` if your workspace is itself a git repo.
>
> The local Claude Code session reads this file once at the start of a new-client deployment. Treat it like a password — anyone who reads it can take over the agent.
>
> Slots marked `REQUIRED` block the deploy from starting. Slots marked `OPTIONAL` enable specific features but won't break a minimal deploy if missing.

---

## CLIENT METADATA

```yaml
client_legal_name:    "Example Consulting LLC"        # REQUIRED. For invoices, contracts.
client_brand_name:    "Example"                       # REQUIRED. Public-facing brand name.
client_first_name:    "Jane"                          # REQUIRED. The human who owns this agent.
client_email:         "jane@example.com"              # REQUIRED. Where critical alerts go.
client_timezone:      "America/New_York"              # REQUIRED. Drives all schedules.
client_city:          "New York"                      # REQUIRED. For morning brief weather.
client_lat:           40.7128                         # REQUIRED. Weather lookup.
client_lon:           -74.0060                        # REQUIRED. Weather lookup.
```

---

## VPS (where the agent will live)

```yaml
vps_provider:         "Vultr"                          # REQUIRED. Vultr / DigitalOcean / Hetzner / etc.
vps_hostname:         "example-agent"                  # REQUIRED. The hostname you set on the VPS.
vps_ip:               "1.2.3.4"                        # REQUIRED. Public IPv4.
vps_root_user:        "root"                           # REQUIRED. Default 'root' on Vultr/DO; may differ on AWS/GCP.
vps_root_ssh_key:     "~/.ssh/<client>-vps-root"       # REQUIRED. Path to YOUR private key authorized for root on the VPS.
vps_os:               "Ubuntu 24.04"                   # REQUIRED. Must be Debian-family (Ubuntu/Debian).
vps_specs:            "1 vCPU, 4GB RAM, 80GB SSD"      # OPTIONAL. For your own records.
vps_monthly_cost:     "$24/mo"                         # OPTIONAL.
```

---

## DOMAIN + DNS (Cloudflare)

```yaml
client_root_domain:   "example.com"                    # REQUIRED. The client's domain.
agent_subdomain:      "ella.example.com"               # REQUIRED. Where Mission Control will live.
blueprint_subdomain:  "blueprint.example.com"          # OPTIONAL. Where the brand blueprint will live.
website_subdomain:    "new.example.com"                # OPTIONAL. Where their Next.js site will live.

cloudflare_account_id: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # REQUIRED. cloudflare.com → top-right.
cloudflare_zone_id:    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # REQUIRED. The zone for client_root_domain.
cloudflare_api_token:  "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # REQUIRED. Scope: Zone:DNS:Edit on the client_root_domain zone.
                                                            #          Create at cloudflare.com → My Profile → API Tokens.
```

---

## TLS — Cloudflare Origin Certificate (recommended)

```yaml
# Easiest path: a wildcard *.example.com Cloudflare Origin Certificate.
# Generate at cloudflare.com → <zone> → SSL/TLS → Origin Server → Create Certificate.
# Choose: 'Let Cloudflare generate a private key and CSR', Hostnames: *.example.com,example.com
# Validity: 15 years. Download both cert + key. Paste contents below OR provide paths
# to files you've placed on the VPS already.

tls_cert_content:     |                                  # REQUIRED if not using paths.
  -----BEGIN CERTIFICATE-----
  <paste cert here>
  -----END CERTIFICATE-----
tls_key_content:      |                                  # REQUIRED if not using paths.
  -----BEGIN PRIVATE KEY-----
  <paste key here>
  -----END PRIVATE KEY-----

# OR, if you've already SCP'd the cert files to the VPS:
# tls_cert_path: "/etc/ssl/certs/example.com-origin.crt"
# tls_key_path:  "/etc/ssl/private/example.com-origin.key"
```

---

## GITHUB (for cloning + pushing the client repo)

```yaml
github_pat:           "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"  # REQUIRED. Scopes: repo (all), workflow.
                                                                   # Create at github.com/settings/tokens.
github_repo_owner:    "newmindsgroup"                  # REQUIRED. Or the client's GitHub org.
github_repo_name:     "example-agent"                  # REQUIRED. Will be created by the deploy.
github_repo_visibility: "private"                      # OPTIONAL. Default: private. 'public' is rare for client agents.
```

---

## TELEGRAM (the daily interface)

```yaml
# Create the bot via @BotFather BEFORE running the deploy:
#   1. Open Telegram → search @BotFather → /newbot
#   2. Set name (free-form) + username (must end in 'bot' or '_bot')
#   3. BotFather replies with the token. Paste below.
#   4. Optional: /setdescription /setabouttext to seed the bot's profile.
#      (setup-bot-identity.sh will overwrite these to use your config.)

telegram_bot_username: "Example_AgentBot"              # REQUIRED. From BotFather.
telegram_bot_token:    "0000000000:XXXXXXXXXXXXXXXXX"  # REQUIRED. From BotFather. Treat like a password.

# Your Telegram user_id (the human who can talk to the bot):
#   Open Telegram → search @userinfobot → /start → it replies with your Id.
telegram_owner_user_id: "1439634560"                   # REQUIRED. Numeric. Goes in access.json allowFrom.
telegram_owner_username: "@jane_example"               # OPTIONAL. For audit trail.
```

---

## CRM — choose one (or none)

```yaml
crm:                  "ghl"                            # REQUIRED. 'ghl' | 'hubspot' | 'pipedrive' | 'none'

# If crm: ghl —
ghl_location_id:      "wwrlbzXIgfjiiyHj3ROD"           # REQUIRED if ghl. GHL → Location → Settings → API Keys → Location ID.
ghl_pit_token:        "pit-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # REQUIRED if ghl. Permanent Integration Token.
                                                                   # GHL → Settings → Integrations → Private Integrations.
ghl_base_url:         "https://services.leadconnectorhq.com"  # OPTIONAL. Default. Only change for private clouds.

# If crm: hubspot — (placeholder; pattern is the same, swap MCP)
# hubspot_access_token: "..."

# If crm: pipedrive — (placeholder)
# pipedrive_api_token: "..."
```

---

## OPTIONAL FEATURES

### Brand canon repo (the SSOT for voice + design + services)

```yaml
brand_repo_url:       "git@github.com:client/brand-canon.git"  # OPTIONAL but strongly recommended.
brand_repo_branch:    "main"                                    # OPTIONAL. Default: main.
brand_repo_ssh_key:   "~/.ssh/<client>-brand-deploy"             # OPTIONAL. Deploy key path (read-only).
```

If unset, the agent operates without brand-canon awareness and ALL voice/visual checks are skipped. Set this for any real client deployment.

### Website (if the client has a Next.js / similar site the agent will manage)

```yaml
website_systemd_service: "example-web.service"         # OPTIONAL. If set, agent will manage this service.
website_source_path:     "/opt/example_tenant/source"  # OPTIONAL. Where the live source lives on the VPS.
```

### Gmail + Calendar OAuth (for hot-lead-inbox-watcher + calendar-conflict-watcher to skip the LLM workaround)

Defer this. The watchers work TODAY via `claude --print` ~$0.07/day combined. Local OAuth drops cost to $0 + latency from 30s → 1s. Setup is a one-time 5-min Google Cloud Console flow — do it after first successful deploy if you want the optimization.

```yaml
google_oauth_account: "agent@example.com"              # OPTIONAL. Dedicated Google account, NOT the client's personal Gmail.
google_oauth_setup:   "deferred"                       # 'deferred' | 'configured'
# If configured, paste the gmail-oauth.json contents under tls_key_content style YAML block:
# google_oauth_json: |
#   {
#     "client_id": "...",
#     "client_secret": "...",
#     "refresh_token": "..."
#   }
```

### Firecrawl (web scraping + extract MCP)

```yaml
firecrawl_api_key:    ""                               # OPTIONAL. Without it, Firecrawl MCP is installed but inactive.
                                                       # Get one at firecrawl.dev (free tier exists).
```

### Discord command center (v0.5+, optional second surface)

Set `discord_enabled: true` in the rendered tenant.yml to activate. Setup runbook:
`vps-setup/runbooks/discord-setup.md`. ~10 minutes to create server + bot + 16 channels.

```yaml
discord_enabled:         false                         # OPTIONAL. Default: false. Set true to enable Discord surface.
discord_bot_token:       ""                            # REQUIRED if discord_enabled. discord.com/developers/applications → New Application → Bot → Reset Token
discord_guild_id:        ""                            # REQUIRED if discord_enabled. Right-click server → Copy Server ID (Developer Mode must be on)
discord_owner_user_id:   ""                            # REQUIRED if discord_enabled. Your Discord user → right-click → Copy User ID (numeric snowflake)
```

If enabled, you'll also fill in 15 channel ID slots inside `tenant.yml` after creating the channels per the runbook.

### Multi-agent swarms (v0.6+, optional heavy-lift framework)

Set `multi_agent_swarms: true` in the rendered tenant.yml to install [VRSEN/OpenSwarm](https://github.com/VRSEN/OpenSwarm). Adds slide-deck / video / image-gen / data-analysis capabilities on top of the built-in Python swarms (bizdev/content/delivery/onboarding).

```yaml
multi_agent_swarms:      false                         # OPTIONAL. Default: false. Set true to install OpenSwarm.
                                                       # Installer: installers/openswarm/install-openswarm.sh
                                                       # Requires Node 20+ and Python 3.10+ (installer will install if missing).
```

The four built-in swarms work with `claude --print` without OpenSwarm — you only need OpenSwarm if you want slides/video/image generation. Skip for minimal client deploys.

### Anthropic subscription (the agent uses Claude Code via this account)

```yaml
anthropic_account:    "agent@example.com"              # REQUIRED. Anthropic Max/Pro/Team subscription this account holds.
                                                       # The VPS install will run `claude login` interactively as this account.
```

---

## v0.7 MISSION CONTROL — Cost preferences (drives ROI dashboard + circuit breakers)

> Defaults work for most solo consultants. Override per-client if their billable rates differ materially. These values land in `vps-setup/tenants/<tenant_id>.yml` under `roi_hourly_rates` + `cost_ceiling_*`.

```yaml
# Daily API spend cap. When today's actual cost crosses this, the global
# circuit breaker engages and autonomous skills refuse to run for the next
# `cost_ceiling_block_hours`. Manual override: DELETE /api/chat/budget.
cost_ceiling_daily_usd:    5.0   # OPTIONAL. Default $5.
cost_ceiling_block_hours:  12    # OPTIONAL. Default 12h.

# Hourly rates for ROI math (used on the ROI dashboard tab + /api/roi.json).
# Realization rate accounts for "AI output still needs human review" —
# 0.5 = heavy review, 0.7 = light review (default), 0.9 = ships as-is.
roi_rate_strategy_usd:     200.0  # OPTIONAL. Strategy/positioning work.
roi_rate_research_usd:     150.0  # OPTIONAL. Research, competitive scans.
roi_rate_content_usd:       75.0  # OPTIONAL. Content drafting.
roi_rate_admin_usd:         50.0  # OPTIONAL. Triage, scheduling, memory notes.
roi_default_realization:   0.7    # OPTIONAL. Default realization rate.

# Mission Control feature toggles. Default all ON; flip to false to skip
# wiring during bootstrap-mission-control.sh.
enable_rules_engine:       true   # OPTIONAL. Behavioral rules engine (v2.48).
enable_anomaly_detection:  true   # OPTIONAL. Z-score + EWMA on telemetry (v2.49).
enable_session_parser:     true   # OPTIONAL. Ingest Claude Code sessions into spans.db (v2.54).
enable_circuit_breakers:   true   # OPTIONAL. Hard cost-ceiling guardrails (v2.57).
```

---

## CHECKLIST BEFORE STARTING THE DEPLOY

- [ ] VPS provisioned, root SSH key authorized, can `ssh root@<vps_ip> 'whoami'` from this Mac
- [ ] Cloudflare zone for `client_root_domain` shows zone_id at top of the dashboard
- [ ] Cloudflare API token created with `Zone:DNS:Edit` on the right zone
- [ ] Cloudflare Origin Cert generated for `*.client_root_domain` (cert + key both saved)
- [ ] GitHub PAT created (`gh auth login` or paste in `github_pat` slot above)
- [ ] @BotFather bot created, token saved
- [ ] Your Telegram user_id captured from @userinfobot
- [ ] CRM credentials gathered (if using one)
- [ ] Anthropic account subscription confirmed active
- [ ] Brand canon repo (if any) accessible to a deploy key
- [ ] (v0.5 optional) Discord server + bot created if `discord_enabled: true` — see `vps-setup/runbooks/discord-setup.md`
- [ ] (v0.6 optional) Decided whether `multi_agent_swarms: true` — adds OpenSwarm install during deploy
- [ ] (v0.7 — Mission Control) Reviewed cost preference defaults above or set custom values
- [ ] This file (`client-credentials.md`) is OUTSIDE any git repo OR added to .gitignore

When all boxes ticked, open Claude Code in the workspace folder and say:
> *"Deploy a fresh agent for this client following NEW-CLIENT-CLAUDE.md"*

The local Claude reads NEW-CLIENT-CLAUDE.md and orchestrates the rest.

---

## SECURITY NOTES

- This file contains tokens equivalent to passwords. If your laptop is shared or backed up to cloud storage, encrypt this folder.
- The Cloudflare token can modify DNS for the entire `client_root_domain` zone — scope it to that one zone, not "all zones."
- The GitHub PAT can create + push to any repo in the owner. Scope to a fine-grained PAT bound to ONE org if possible.
- The Telegram bot token can post messages as the bot AND read messages from the chat. Anyone with this token can impersonate the bot.
- The GHL PIT token can read + write the entire location's data. Treat like a database password.
- After deploy, this file is no longer NEEDED on the local Mac. The VPS has its own copies of what it requires (in `.env-deploy`, `.mcp.json`, etc.). Consider archiving this file to a password manager and removing it from the workspace.
