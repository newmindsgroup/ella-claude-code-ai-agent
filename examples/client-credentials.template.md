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

### Anthropic subscription (the agent uses Claude Code via this account)

```yaml
anthropic_account:    "agent@example.com"              # REQUIRED. Anthropic Max/Pro/Team subscription this account holds.
                                                       # The VPS install will run `claude login` interactively as this account.
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
