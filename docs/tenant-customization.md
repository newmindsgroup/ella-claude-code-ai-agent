# Tenant customization

How to customize the agent for a specific business. Pairs with [`vps-setup/PORTING.md`](../vps-setup/PORTING.md), which walks through the full porting procedure end-to-end.

This doc focuses on the **decision points** — what you need to think about when standing up a new tenant.

---

## Tenant config — `vps-setup/tenants/<tenant_id>.yml`

Everything tenant-specific lives in this one file. The engine — sub-agents, scripts, systemd units, dashboard, Telegram tooling, task ledger — is identical across tenants.

Start by copying the example:

```bash
cp vps-setup/tenants/EXAMPLE_TENANT.yml vps-setup/tenants/<your-tenant-id>.yml
```

Then walk through the file top to bottom. The example is heavily commented (~150 lines). Below are the decision points worth thinking about.

---

## Identity & Contact

```yaml
tenant_id: <slug>                         # Drives Linux user, paths, systemd unit names
person_full_name: "Jane Doe"
person_first_name: "Jane"
person_role_description: "independent fractional CMO"   # ONE sentence
contact_email: "jane@example.com"
website_url: "https://example.com"
timezone: "America/New_York"               # IANA tz; drives morning brief schedule
locale: "en-US"
```

`person_role_description` lands directly in the agent's first prompt: *"You are {person_full_name}'s chief-of-staff agent. {person_first_name} is an {person_role_description}."* Make it specific. "Independent fractional CMO" beats "consultant."

---

## Voice DNA

```yaml
voice_archetype_primary: "Sage"           # Pick from Jung/Mark+Pearson 12-archetype framework
voice_archetype_secondary: "Creator"
voice_playbook_path: <path to your voice playbook>
voice_banned_phrases:
  - "thrilled to"
  - "excited to share"
  - "in today's fast-paced world"
  - "humbled to"
  - "delve into"
  - "in the realm of"
  # add yours
```

The archetype pair feeds into the agent's CLAUDE.md. The banned phrases get checked by the drift-scanner sub-agent and refused by voice-aware sub-agents at draft time.

The voice playbook itself is a markdown file. See [`examples/voice-playbook.example.md`](../examples/voice-playbook.example.md) for the structure.

---

## Entity separation

```yaml
entity_term_1: "Acme Holdings"            # Parent legal entity — never named in client-facing output
entity_term_2: "Acme Consulting"          # Operating entity (this is what client-facing output uses)
entity_term_3: "Acme SaaS"                # Sister entity / DBA — never named in client-facing output
```

If your business has multiple legal entities, the agent enforces "in any client-facing output, you are a solo consultant — never name parent or sister entities." This is a real concern for consultants who operate through holding companies and don't want to confuse clients.

---

## Telegram bot

```yaml
telegram_bot_token: "1234567890:AABBccDDeeFF..."
telegram_chat_id: 12345678                # Your numeric chat ID — get from @userinfobot
telegram_voice_mode: "reply"              # off / reply / always
```

`voice_mode`:
- `off` — text only
- `reply` — agent replies as text by default; voice replies only when you explicitly ask
- `always` — agent replies as both text + voice audio for every message

---

## Dashboard

```yaml
dashboard_subdomain: "dashboard"          # → dashboard.{tld}
dashboard_basic_auth_user: "you"          # lowercase username for basic-auth
dashboard_basic_auth_password_hint: "set via htpasswd; never commit"
```

The dashboard runs at `https://<dashboard_subdomain>.<your_tld>/`. Behind basic-auth. All requests are explicitly NOT-cached by Cloudflare via the `Cache-Control: private, no-store, must-revalidate, always` header — without that, auth leaks via edge cache.

---

## CRM / external integrations

The example is GoHighLevel. Substitute for HubSpot / Salesforce / Pipedrive / your-stack:

```yaml
crm_mcp_name: "ghl"                       # MCP server name in .mcp.json
crm_api_key_hint: "PIT token from GHL Location settings"
crm_location_id: "<location-id>"
crm_base_url: "https://services.leadconnectorhq.com"
```

The chief-of-staff CLAUDE.md template references CRM tools as `mcp__{crm_mcp_name}__*`. Setting `crm_mcp_name` to your CRM's MCP server name makes the substitution work.

---

## Brand canon repo

```yaml
brand_repo_name: "your-business"          # Folder name under /opt/<tenant>/agents/
brand_repo_git_url: "git@github.com:youruser/your-business.git"
brand_repo_default_branch: "main"
```

The brand canon repo is YOUR business's content + design + docs. The agent operates against it as its primary working directory. Path on the VPS: `/opt/<tenant_id>/agents/<brand_repo_name>/`.

For a personal-brand consultant, this might be a private repo with brand docs, design system, content drafts, client list. For a SaaS founder, it might be the company's content + marketing site repo.

---

## Sub-agents (cherry-pick customization)

The 16 agency-agents are a default cherry-pick. Add or remove via [`agent-stack/agency-agents-installer/manifest.json`](../agent-stack/agency-agents-installer/manifest.json):

```json
{
  "agents": [
    {
      "src": "marketing/marketing-linkedin-content-creator.md",
      "name": "linkedin-content-creator",
      "triggers": "Use PROACTIVELY when the user wants to write a LinkedIn post... Trigger on: 'LinkedIn post', 'thought leadership', ...",
      "voice_aware": true
    },
    ...
  ]
}
```

Browse the [full agency-agents catalog](https://github.com/msitarzewski/agency-agents) — there are ~150 agents across many domains (engineering, design, marketing, sales, product, testing, support, specialized). Cherry-pick what fits your tenant's domain.

To add a custom hand-built sub-agent:
1. Drop a `.md` file into `~/.claude/agents/` with proper frontmatter (`name`, `description`)
2. Description must include explicit "Use PROACTIVELY when..." trigger phrases for auto-routing

---

## Custom tools / MCP servers

If you need a tool that's not in the default install (Notion MCP, Google Drive MCP, custom internal API):

1. Add the server entry to `/opt/<tenant>/agents/.mcp.json` directly (matching the pattern for `firecrawl`, `ghl`, etc.)
2. Update the chief-of-staff CLAUDE.md to reference it under "MCP servers available"
3. Restart `claude-agent.service` to load it

Per the operating-principles, **commit the change** to your tenant.yml or a separate config file so it survives re-deploys.

---

## Deploy command (autonomous releases)

```yaml
deploy_versioned: true                    # If you maintain release versions like v1.2.3
deploy_queue_dir: "vps-setup/queue"       # Where /deploy reads version specs from
deploy_basic_auth_pw_path: "/opt/<tenant>/agents/.env-deploy"
```

If you want to deploy from your phone via Telegram:
1. Write a deploy spec at `<deploy_queue_dir>/<version>.yml` (preflight checks, smoke tests, GATE prompts)
2. Send `/deploy <version>` to the bot
3. Agent runs preflight + smoke, then asks for approval with Ship/Cancel buttons
4. You tap Ship — agent commits, pushes, and rolls out

Set up requires `BASIC_AUTH_PW` to be in the agent's environment (sourced from `<deploy_basic_auth_pw_path>` via systemd `EnvironmentFile=`).

See [`vps-setup/runbooks/feature-registry.md`](../vps-setup/runbooks/feature-registry.md) — wait, that's tenant-specific. The deploy command pattern is documented in `vps-setup/PORTING.md` and the agent-template's CLAUDE.md.tmpl.

---

## Knowledge library

```yaml
knowledge_library_roots:
  - "/opt/<tenant>/agents/<brand_repo_name>"
  - "/opt/<tenant>/agents/<brand_repo_name>/docs"
```

Roots that the Filesystem MCP can read/write. Embedded into the Chroma vector store on every refresh. The agent semantic-searches this when answering knowledge questions.

---

## Customizing the chief-of-staff CLAUDE.md template

The template at [`vps-setup/agent-template/CLAUDE.md.tmpl`](../vps-setup/agent-template/CLAUDE.md.tmpl) has explicit sections you can customize per-tenant:

- **Header description** (line 3) — who the tenant is, what tools they have
- **Sub-agent registry** — list of available specialists with trigger examples
- **Tool-leverage heuristics** — the combo-pattern table (see [tool-leverage-heuristics.md](tool-leverage-heuristics.md))
- **Long-form output routing** — where drafts go (CRM, blog repo, lead-magnet folder)
- **Out of bounds** — what the agent must never touch

Edit the `.tmpl`, re-run `render-tenant.sh`, copy the rendered CLAUDE.md to `/opt/<tenant>/agents/CLAUDE.md`, restart `claude-agent.service`.

**Always commit the template change** — drift between rendered files and the canonical template is the #1 source of "I'm not sure why the agent does X."

---

## Validation checklist before going live

After running through `bootstrap-tenant.sh`:

- [ ] `claude-agent.service` is `active` and stable for 10+ minutes
- [ ] `claude mcp list` from the agent's cwd shows all MCP servers as `✓ Connected`
- [ ] `~/.claude/agents/` has the 16 cherry-picked sub-agents
- [ ] Voice-aware agents (linkedin / carousel / ai-citation / image-prompt / document-generator) have inline brand-voice block referencing your voice playbook
- [ ] Sending "hello" to your bot returns a reply within 10 seconds
- [ ] Sending a substantive prompt routes to the right sub-agent (test: "draft me a LinkedIn post about X" → linkedin-content-creator)
- [ ] Dashboard at `dashboard.<your-tld>` is reachable, basic-auth works, KPI cards render
- [ ] Chat tab on the dashboard works (proxies to the same agent as Telegram)
- [ ] `bash vps-setup/scripts/health.sh tenants/<tenant>.yml` reports all services green
- [ ] Voice round-trip works (send a voice note, get a reply) — only if `voice_mode != off`

If all green: you're production. Save the install state to a memory entry per the operating-principles.
