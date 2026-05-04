# Ella — Claude Code AI Agent for Any Business

**An autonomous, single-tenant AI chief-of-staff agent built on Claude Code. Talks via Telegram. Runs on a $20/mo VPS. Replicable for any business in under one hour.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Built_on-Claude_Code-orange)](https://claude.com/claude-code)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

---

## What this is

This repo is a **production-grade, idempotent installer + multi-tenant template** for standing up an autonomous Claude Code AI agent for any business. The reference implementation runs `Daniel_AgentBot` on Telegram for a personal-brand consultant in Santo Domingo — **the same stack works for a fractional CMO, an agency owner, a SaaS founder, or a solo law firm** by changing one config file.

**What you get when you deploy this:**

- An always-on **chief-of-staff agent** that triages every message you send via Telegram, delegates specialist work to **21 sub-agents** (5 hand-built patterns + 16 cherry-picked from the [agency-agents](https://github.com/msitarzewski/agency-agents) MIT collection), and never forgets a commitment via a **persistent task ledger**.
- A **brand-voice + brand-visual single source of truth** ([voice playbook](examples/voice-playbook.example.md) + [DESIGN.md](examples/DESIGN.md)) that voice-aware sub-agents read before drafting any human-facing copy or visual artifact. **Banned phrases never ship.**
- A **knowledge graph** ([Graphify](https://github.com/safishamsi/graphify)) the agent queries instead of grepping, plus **Firecrawl MCP** for web scraping, search, and structured extraction.
- A **morning-brief / proposed-moves system**: every morning the agent posts 2–3 strategic proposals to Telegram with Run/Skip buttons. You tap. It executes via the right sub-agent.
- An **autonomous deploy command**: edit a YAML spec, send `/deploy v1.2.3` from your phone, get one approval prompt after smoke tests pass, tap Ship. Code commits, pushes, and rolls out.
- A **public-facing dashboard** behind basic-auth ([Mission Control](docs/architecture.md#mission-control-dashboard)) showing real-time agent activity, task ledger, telemetry, goals, and per-task cost.
- **Voice round-trip** — Telegram voice notes get transcribed by local Whisper, processed, and replied to via [edge-tts](https://github.com/rany2/edge-tts) audio if you set voice mode to `always`.

**What this is NOT:**
- ❌ A wrapper around the Claude API. This runs on **Claude Code with an Anthropic Max/Pro/Team subscription**. ToS-clean. No API keys.
- ❌ A prompt-engineering project. Claude Code is the brain — this is **infrastructure + governance + business-tier integrations** around it.
- ❌ A SaaS. There's no hosted version. You deploy on your own VPS. You own everything.

---

## Quick links

| If you want to... | Read |
|---|---|
| See the architecture end-to-end | [docs/architecture.md](docs/architecture.md) |
| Install the agent on your laptop (local dev) | [docs/install-local.md](docs/install-local.md) |
| Install the agent on a VPS (production) | [docs/install-vps.md](docs/install-vps.md) |
| Customize for a new business / client / tenant | [docs/tenant-customization.md](docs/tenant-customization.md) — also [vps-setup/PORTING.md](vps-setup/PORTING.md) |
| Understand how the agent decides which tool to use | [docs/tool-leverage-heuristics.md](docs/tool-leverage-heuristics.md) |
| Lock down brand voice + visual identity | [docs/voice-and-visual-ssot.md](docs/voice-and-visual-ssot.md) |
| See every external dependency and why | [docs/upstream-dependencies.md](docs/upstream-dependencies.md) |
| Add the agent stack to an existing project (just the rituals layer) | [agent-stack/README.md](agent-stack/README.md) |

---

## Architecture in one diagram

```
                 Phone (Telegram)
                        │
                        ▼
            ┌─────────────────────────┐
            │  Telegram Bot Channel   │   ← claude-code-plugins official + local patches
            │  (your @YourAgentBot)   │       (callback_data, voice notes, mini-apps)
            └────────────┬────────────┘
                         │
                         ▼
        ┌────────────────────────────────────┐
        │  Chief-of-Staff Agent              │   ← Claude Code in tmux, systemd-managed
        │  /opt/{tenant}/agents/             │      (CLAUDE.md = behavioral spec,
        │                                    │       rendered from agent-template)
        │  ┌──────────────────────────────┐  │
        │  │ Triage rules                 │  │   ← trivial / specialized / conversational / ambiguous
        │  │ Tool-leverage heuristics     │  │   ← when to fire firecrawl, graphify, sub-agents
        │  │ Task ledger                  │  │   ← state machine: proposed→committed→done
        │  │ Memory recall                │  │   ← knowledge-graph MCP across sessions
        │  └──────────────────────────────┘  │
        └────────────┬───────────────────────┘
                     │
       ┌─────────────┼─────────────────────────────────────────┐
       ▼             ▼                  ▼                      ▼
   Sub-agents   MCP tools         Brand canon            Public dashboard
   ─────────    ─────────         ───────────            ────────────────
   • 16 from    • GHL/HubSpot     • Voice playbook       • blueprint.{your-tld}
     agency-      (your CRM)      • DESIGN.md              (Cloudflare + nginx +
     agents     • Firecrawl       • Messaging              basic-auth + 60s pull)
   • Hand-      • Graphify          framework            • {your-tld}/dashboard
     built      • Memory MCP                                (Mission Control,
     domain     • Filesystem                                 telemetry, tasks,
     experts    • Playwright                                 goals, proposals)
                • Chroma RAG
```

The agent reads its behavioral spec (`CLAUDE.md`), looks at incoming messages, decides which tools and sub-agents to fire, executes work, narrates progress to the task ledger (which pings the user via Telegram), and emits proposals to act on tomorrow's moves.

---

## What's in this repo

```
ella-claude-code-ai-agent/
├── README.md                          ← you are here
├── LICENSE                            ← MIT
├── agent-stack/                       ← Portable installer (works for any project, not just VPS)
│   ├── scripts/                         00-prereqs → 09-install-graphify, install-all, verify-all
│   ├── config/                          client.example.env, CLAUDE.md.template (engineering rituals)
│   ├── agency-agents-installer/         install.py + manifest + voice-paths.example.json
│   └── docs/per-server/                 chroma, fetch, filesystem, memory, playwright, superpowers
├── vps-setup/                         ← Multi-tenant agent template (production)
│   ├── PORTING.md                       end-to-end "spin up this stack for a new business"
│   ├── agent-template/                  CLAUDE.md.tmpl + scripts + dashboard + nginx + systemd + tasks
│   ├── tenants/EXAMPLE_TENANT.yml       comprehensive example tenant config (~150 lines, fully documented)
│   ├── scripts/                         render-tenant.sh, bootstrap-tenant.sh, health.sh, smoke.sh, preflight.sh
│   ├── runbooks/                        operating-principles.md (the 7 commitments)
│   └── mcp-patches/                     idempotent patch-applier for vendored MCP servers
├── docs/                              ← Deep-dive documentation
│   ├── architecture.md                  system architecture, file flow, service health
│   ├── install-local.md                 laptop install (Mac/Linux dev) — 15 min
│   ├── install-vps.md                   VPS install (production) — 60 min from blank Ubuntu
│   ├── tenant-customization.md          per-business customization
│   ├── tool-leverage-heuristics.md      when to fire which tool (the autonomy playbook)
│   ├── voice-and-visual-ssot.md         brand voice + DESIGN.md pattern
│   └── upstream-dependencies.md         every git repo / npm package / pypi package this depends on, with why
├── examples/                          ← Drop-in templates for any new tenant
│   ├── DESIGN.md                        blank Stitch 9-section visual SSOT template
│   ├── AGENTS.md                        blank brand-context template
│   └── voice-playbook.example.md        blank voice-DNA + banned-phrases template
└── CONTRIBUTING.md
```

---

## Quick start (60-second TL;DR)

### Local install (laptop)

```bash
# 1. Make sure Claude Code is installed and authenticated
claude --version
claude auth status

# 2. Clone this repo
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent.git ~/ella
cd ~/ella

# 3. Configure
cp agent-stack/config/client.example.env agent-stack/config/client.env
$EDITOR agent-stack/config/client.env

# 4. Install
bash agent-stack/scripts/install-all.sh

# 5. Drop the brand-voice + visual templates into your project repo
cp examples/AGENTS.md examples/DESIGN.md examples/voice-playbook.example.md /path/to/your/project/
```

That gives you the **rituals + sub-agents + MCPs + brand-voice infrastructure** in any Claude Code session.

### VPS install (production always-on agent)

See [docs/install-vps.md](docs/install-vps.md) — the short version is:

```bash
# On a clean Ubuntu 22.04+ VPS, as a non-root sudo user:
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent.git ~/ella
cd ~/ella

# Stand up Claude Code, install agent-stack, render your tenant, deploy systemd units
claude login
bash agent-stack/scripts/install-all.sh
cp vps-setup/tenants/EXAMPLE_TENANT.yml vps-setup/tenants/<your-tenant-id>.yml
$EDITOR vps-setup/tenants/<your-tenant-id>.yml
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<your-tenant-id>.yml
bash vps-setup/scripts/bootstrap-tenant.sh vps-setup/tenants/<your-tenant-id>.yml
```

Then point your domain's DNS at the VPS and you have a fully autonomous always-on agent reachable via your Telegram bot in ~60 minutes from blank Ubuntu.

---

## What makes this different

| Feature | Why it matters |
|---|---|
| **Single-tenant, owned by you** | Your VPS, your data, your Anthropic subscription. No SaaS vendor between you and your agent. |
| **ToS-clean** | Built on Claude Code with a normal Anthropic Max/Pro/Team subscription. No API keys. No third-party brain wrappers. No grey-zone token reselling. |
| **Multi-tenant template** | One config file (`tenant.yml`) drives every business-specific value. The engine is identical across tenants. **Stand up a new client in under an hour.** |
| **Brand voice as code** | The voice playbook is a markdown file the agent reads before every draft. Banned phrases are absolute. No more catching "thrilled to" in copy review. |
| **Visual SSOT (DESIGN.md)** | Companion to AGENTS.md. AI tools (Cursor, v0, Lovable, Claude Code) read it before generating UI. Same aesthetic across every project. Reusable as a client deliverable. |
| **Strategic tool autonomy** | The chief-of-staff has explicit *Tool-Leverage Heuristics* in its CLAUDE.md mapping common situations to tool combos. It reaches for `incident-response-commander` when production breaks. It runs `/graphify` proactively before answering big-picture codebase questions. **You don't memorize tool names.** |
| **Real engineering discipline** | [`operating-principles.md`](vps-setup/runbooks/operating-principles.md) is non-negotiable: idempotent installs, dry-runs before production changes, append-only audit logs, no force-push to main. The kind of discipline a real ops shop runs on. |
| **Mobile-first UX** | Designed to be operated entirely from your phone via Telegram. Voice notes work. Inline approval buttons. Mini-apps for the dashboard. Voice round-trip in English/Spanish (extensible). |

---

## The 21-strong sub-agent roster

The agent has a curated set of specialists it auto-routes to via "Use PROACTIVELY when..." description triggers — you don't memorize names, you describe what's needed.

**Hand-built patterns** (project-scoped — the *examples* live in [`vps-setup/agent-template/CLAUDE.md.tmpl`](vps-setup/agent-template/CLAUDE.md.tmpl); replace with your own):
- `comms-agent` — client-facing emails, Telegram replies, short social posts
- `pipeline-agent` — read-only CRM analysis, deal status, stalled-deal flagging
- `content-agent` — long-form drafting (newsletter, blog posts, scripts)
- `research-agent` — prospect lookup, competitive intel, public web research
- `drift-scanner` — audits recently published content for banned phrases / brand drift

**Cherry-picked from [msitarzewski/agency-agents](https://github.com/msitarzewski/agency-agents) (MIT)** — installed by [`scripts/07-install-agency-agents.sh`](agent-stack/scripts/07-install-agency-agents.sh):
- Engineering: `ai-engineer`, `autonomous-optimization-architect`, `incident-response-commander`, `sre`, `code-reviewer`, `database-optimizer`
- Multi-agent / orchestration: `agents-orchestrator`, `workflow-architect`, `agentic-identity-trust`, `identity-graph-operator`
- Content production (voice-aware — defer to brand voice playbook): `linkedin-content-creator`, `carousel-growth-engine`, `ai-citation-strategist`, `document-generator`
- Visual / production gate: `image-prompt-engineer`, `reality-checker`

The cherry-pick list is in [`agent-stack/agency-agents-installer/manifest.json`](agent-stack/agency-agents-installer/manifest.json) — edit and re-run to add/remove.

---

## Upstream dependencies (what makes this work)

This repo is **architecture + governance + glue** — not original code for the most part. Full inventory in [docs/upstream-dependencies.md](docs/upstream-dependencies.md). The non-negotiable ones:

| Dependency | What | Why |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) (Anthropic) | The brain | The whole stack runs on it. Max/Pro/Team subscription. |
| [Superpowers](https://github.com/obra/superpowers) | Engineering rituals plugin | Planning, TDD, systematic debugging, verification, code review |
| [agency-agents](https://github.com/msitarzewski/agency-agents) (MIT) | 16 cherry-picked sub-agents | Specialist coverage across engineering, marketing, design, testing |
| [Graphify](https://github.com/safishamsi/graphify) | Code/doc → knowledge graph | Agent navigates by graph instead of grepping |
| [Firecrawl MCP](https://github.com/mendableai/firecrawl-mcp-server) | Web scraping + structured extract | JS-rendered scrapes, bulk crawls, AI-search visibility audits |
| [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) | DESIGN.md format | Visual SSOT format AI tools read most reliably |
| [`@modelcontextprotocol/server-memory`](https://github.com/modelcontextprotocol/servers) | Persistent knowledge graph MCP | Cross-session memory |
| [`@modelcontextprotocol/server-fetch`](https://github.com/modelcontextprotocol/servers) | Single-URL HTML→markdown reads | Light web reads (Firecrawl handles the heavy lifting) |
| [`@modelcontextprotocol/server-filesystem`](https://github.com/modelcontextprotocol/servers) | Scoped filesystem operations | Bounded file access |
| [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) | Headless browser automation | Smoke tests + complex scrapes |
| [Chroma](https://www.trychroma.com/) | Local vector RAG | Embeddings over project knowledge library |
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | Local transcription | Telegram voice notes → text |
| [edge-tts](https://github.com/rany2/edge-tts) | Text-to-speech | Voice replies via Telegram |
| [GoHighLevel-MCP](https://github.com/mastanley13/GoHighLevel-MCP) (or your CRM's MCP) | CRM integration | Email templates, social posts, contacts, calendar — example uses GHL; **swap for HubSpot / Salesforce / Pipedrive MCPs as needed** |

---

## License

MIT — see [LICENSE](LICENSE). Use it for your business, your clients' businesses, anywhere.

The cherry-picked sub-agents from `msitarzewski/agency-agents` are also MIT. Each MCP server has its own license — check the upstream repos.

---

## Credits

Architecture patterns, install scripts, and the agent-stack baseline were extracted from a production single-tenant deployment for an independent brand consultant in Santo Domingo. The chief-of-staff template, task ledger, proposed-moves system, voice round-trip, and Mission Control dashboard were battle-tested across the v2.0–v2.27 release cycle.

Built on top of work by:
- Anthropic (Claude Code, MCP spec, official MCP servers)
- [Jesse Vincent](https://github.com/obra) (Superpowers plugin, agentic skills patterns)
- [Safi Shamsi](https://github.com/safishamsi) (Graphify)
- [Maciej Sitarzewski](https://github.com/msitarzewski) (agency-agents)
- [VoltAgent](https://github.com/VoltAgent) (awesome-design-md / DESIGN.md format)
- [Mendable](https://github.com/mendableai) (Firecrawl)
- [Microsoft](https://github.com/microsoft/playwright-mcp) (Playwright MCP)

If your work is in here and you'd like better attribution or want it removed, open an issue.

---

## Status

This is a **v0.1 reference release** — the patterns are battle-tested, the installer is idempotent, but it's still single-tenant in practice. Multi-tenant template support is in place but only one tenant has been deployed end-to-end as of this release.

Issues, PRs, and "I deployed this for company X and here's what broke" reports are all welcome.
