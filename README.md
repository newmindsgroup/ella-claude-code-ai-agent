# Ella — Claude Code AI Agent for Any Business

**An autonomous, single-tenant AI chief-of-staff agent built on Claude Code. Talks via Telegram. Runs on a $20/mo VPS. Replicable for any business in under one hour.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Built_on-Claude_Code-orange)](https://claude.com/claude-code)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> Designed and built by **[Daniel Gonell](https://danielgonell.com)** — brand, UX & AI systems consultant.

---

## What this is

This repo is a **production-grade, idempotent installer + multi-tenant template** for standing up an autonomous Claude Code AI agent for any business. The reference implementation runs a personal-brand consulting agent on Telegram. **The same stack works for a fractional CMO, an agency owner, a SaaS founder, or a solo law firm** by changing one config file.

**What you get when you deploy this:**

- An always-on **chief-of-staff agent** that triages every message you send via Telegram, delegates specialist work to **21 sub-agents** (5 hand-built patterns + 16 cherry-picked from the [agency-agents](https://github.com/msitarzewski/agency-agents) MIT collection), and never forgets a commitment via a **persistent task ledger**.
- A **brand-voice + brand-visual single source of truth** ([voice playbook](examples/voice-playbook.example.md) + [DESIGN.md](examples/DESIGN.md)) that voice-aware sub-agents read before drafting any human-facing copy or visual artifact. **Banned phrases never ship.**
- A **knowledge graph** ([Graphify](https://github.com/safishamsi/graphify)) the agent queries instead of grepping, plus **Firecrawl MCP** for web scraping, search, and structured extraction. **Weekly auto-rebuild** keeps the graph current with zero LLM cost.
- A **morning-brief / proposed-moves system**: every morning the agent posts 2–3 strategic proposals to Telegram with Run/Skip buttons. You tap. It executes via the right sub-agent.
- A **proactive notification pipeline — 7 watchers** that ping you when something needs attention without you having to ask. Task deadlines, goal pace, stalled deals, disk space, hot leads in inbox, calendar conflicts, brand drift. All event-driven, all dedup-logged, all dirt cheap (no LLM-per-check on 4 of them).
- **Agent self-service ops** — 5 sudoers-gated wrapper scripts let the agent update its own Claude Code binary, deploy the website, restart services, reload nginx, install systemd units WITHOUT your password. The wrappers are the audit boundary — raw sudo is still locked down.
- An **autonomous deploy command**: edit a YAML spec, send `/deploy v1.2.3` from your phone, get one approval prompt after smoke tests pass, tap Ship. Code commits, pushes, and rolls out.
- A **public-facing dashboard** behind basic-auth ([Mission Control](docs/architecture.md#mission-control-dashboard)) showing real-time agent activity, task ledger, telemetry, goals, and per-task cost. **Opens inline as a Telegram Mini App** via `/dashboard` — no browser switch.
- **Voice round-trip** — Telegram voice notes get transcribed by local Whisper (auto-detects English vs Spanish), processed, and replied to via [edge-tts](https://github.com/rany2/edge-tts) audio. Three modes (`off`/`reply`/`always`) persisted via `/voice`.
- **Channels-plugin patches (5 passes)** — local TS patches to the upstream Telegram bot plugin add Ship/Hold/Revise on drafts, Run/Skip on proposals, Reply/Archive/Snooze on emails, forward-detection metadata, and the deploy callback flow. All idempotent + sentinel-checked.
- **End-to-end smoke test** — `bash {agent_home}/scripts/smoke-test.sh` runs 60+ checks across 12 sections (services, timers, scripts, plugin patches, bot identity, watchdog state, voice stack, knowledge graph). Re-runnable any time. Useful as a cron health check or after any system change.

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

### Fresh-client deploy (v0.4+) — local Claude orchestrates the whole thing

For deploying a new client agent on a fresh VPS, the recommended flow is **local-Claude orchestrated**. You open Claude Code in a workspace folder, give it the client's credentials + brand context, and Claude SSH's to the VPS and walks through every step (DNS, TLS, Telegram, systemd, smoke test). About 30 minutes from "I have credentials" to "first morning brief fires."

```bash
mkdir -p ~/code/<client>-workspace && cd ~/code/<client>-workspace

# Get the latest templates
git clone --depth=1 https://github.com/newmindsgroup/ella-claude-code-ai-agent /tmp/ella-tmp
cp /tmp/ella-tmp/examples/client-credentials.template.md client-credentials.md
cp /tmp/ella-tmp/NEW-CLIENT-CLAUDE.md NEW-CLIENT-CLAUDE.md

# Fill in credentials + write a client-context.md
$EDITOR client-credentials.md     # tick every checkbox at the bottom
$EDITOR client-context.md         # paragraphs about the brand, voice, business

# Open Claude Code in the workspace and say:
#  "Deploy a fresh agent for this client following NEW-CLIENT-CLAUDE.md"
claude
```

Full runbook (12 phases, dependency-ordered): [`vps-setup/DEPLOY-NEW-CLIENT.md`](vps-setup/DEPLOY-NEW-CLIENT.md). Pre-flight check that validates every credential before mutating state: [`vps-setup/scripts/preflight-new-client.sh`](vps-setup/scripts/preflight-new-client.sh).

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

## Three-tier sub-agent delegation (v0.6+)

The 21-agent roster above is **Tier 1**. v0.6 adds two more tiers for genuinely multi-step work.

| Tier | What | When to use | Cost |
|---|---|---|---|
| **Tier 1** | Agent tool sub-agents (21 specialists) | Multi-context investigation, parallelizable work, anything where 2-4 agents can fan out in their own context windows | Within Anthropic subscription |
| **Tier 2** | Domain swarms via `swarm-router.sh` | Task matches a known shape: `bizdev` (prospect → research + outreach + proposal), `content` (idea → drafts), `delivery` (client deliverables), `onboarding` (kickoff + intake) | `claude --print` per step (~$0.01-0.05) |
| **Tier 3** | [VRSEN/OpenSwarm](https://github.com/VRSEN/OpenSwarm) (optional) | Heavy-lift media generation: slides, video, image-gen, data analysis, 10K+ integrations via Composio | Variable, can be expensive |

Tier 3 is opt-in. Enable with `features.multi_agent_swarms: true` in tenant.yml + run `installers/openswarm/install-openswarm.sh` during deploy.

The agent's CLAUDE.md.tmpl includes a **Tier decision matrix** that the LLM consults before delegating — so it picks the cheapest tier that can do the job.

For long-running independent work (10+ min audits, deep research), the agent uses the v2026+ `claude agents` background flags (`--add-dir`, `--settings`, `--mcp-config`, `--effort high`, `--permission-mode bypassPermissions`) so the parent session stays responsive.

---

## Proactive notification pipeline (v0.3+)

The agent doesn't just respond — it pings you when something needs attention. Seven watchers run on systemd timers, each with its own cadence and dedup strategy:

| Watcher | Schedule (tenant TZ) | What it watches | Cost-per-run |
|---|---|---|---|
| `task-deadline-watcher` | hourly 08–22 | `tasks/active.json` deadlines crossing 24h / 4h / due / overdue | local file (free) |
| `goal-deadline-watcher` | daily 09:30 | `goals/active.json` — 7d / 1d / overdue windows + behind-pace check (>25% gap between time-elapsed and progress) | local file (free) |
| `stalled-deal-watcher` | daily 10:00 | GHL opportunities ≥$2K (default) idle ≥7d (default) | 1 GHL REST call (free) |
| `disk-space-watcher` | every 4h, around the clock | All filesystems — 75% yellow / 85% orange / 95% red, escalating dedup windows | local `df` (free) |
| `hot-lead-inbox-watcher` | 4×/day (12/16/20/00) | Gmail threads in lookback window, cross-referenced against GHL contacts | claude --print + GHL REST (~$0.01) |
| `calendar-conflict-watcher` | 3×/day (07/12/17) | Overlapping events on primary calendar, today + lookahead | claude --print (~$0.01) |
| `graphify-rebuild` | weekly Sunday 03:00 | AST-only refresh of the project-repo knowledge graph | local (free) |

Each watcher logs to `notifications/<name>-nudges.jsonl` for dedup + audit. Disable any of them via `features.<watcher_name>: false` in tenant.yml.

The architectural lesson — when an LLM is required (Gmail, Calendar), do the **split LLM/bash design**: LLM does ONE tool call → returns JSON, bash does all downstream filtering / cross-referencing / formatting / sending. Single-purpose prompts succeed reliably; multi-step prompts under sparse data sometimes short-circuit.

---

## Agent self-service ops (v0.3+)

The agent on the VPS can update itself, deploy the website, restart services, and install systemd units **without your password**. Capabilities are gated through 5 auditable wrapper scripts in `{{TENANT_AGENT_HOME}}/scripts/ops/`, not raw sudo to arbitrary commands. Every wrapper validates inputs, logs to `/var/log/{{TENANT_LINUX_USER}}-agent-ops.log`, and pings Telegram on completion.

| Wrapper | What it does |
|---|---|
| `ops-claude-update.sh` | Updates `@anthropic-ai/claude-code` global npm package, verifies 5 channels-plugin patches survive, pre-prunes watchdog history, restarts agent, runs smoke test, pings Telegram |
| `ops-website-deploy.sh [--no-build] [--skip-deps]` | pnpm install (optional) + pnpm build (optional) + restart website systemd service + HTTP probe + Telegram confirm |
| `ops-service-restart.sh <name>` | Restarts any allowlisted systemd service (strict allowlist: agent + watchers + nginx + dashboard-chat + agent-skill@*). Refuses sshd, cron, anything outside the agent stack |
| `ops-nginx-reload.sh` | `nginx -t` first (refuses reload on bad config), then zero-downtime `systemctl reload nginx` |
| `ops-systemd-install-unit.sh <src> <name>` | Copies a unit from `{{TENANT_AGENT_HOME}}/...` to `/etc/systemd/system/`, daemon-reload, auto-enable timers |

The sudoers entry (`/etc/sudoers.d/{{TENANT_LINUX_USER}}-agent-ops`) is a single line: `{{TENANT_LINUX_USER}} ALL=(root) NOPASSWD: {{TENANT_AGENT_HOME}}/scripts/ops/`. Adding a capability = adding a wrapper (auditable). Emergency lockdown = `rm /etc/sudoers.d/{{TENANT_LINUX_USER}}-agent-ops`.

**Still locked down** (deny list in `settings.json`): `/etc/**`, `/var/www/**`, `~/.ssh/**`, `~/.claude.json` writes; `reboot`, `shutdown`, `passwd`, `useradd`, `chown`, `chmod 777`; all `rm -rf /` flavors.

---

## Telegram polish — the 5 channels-plugin patches

The upstream Telegram bot plugin's callback handler only recognizes `perm:` patterns. Five idempotent local patches add additional callback routing for every approval flow in the stack:

| Pass | Pattern | What taps do |
|---|---|---|
| v2.22.2 | `deploy:(ship\|cancel):v<MAJ>.<MIN>.<PATCH>` | Ship/Cancel buttons on `/deploy` approval messages |
| v2.24.0 | `draft:(ship\|hold\|revise):t-YYYYMMDD-xxxx` | Ship/Hold/Revise on every draft surfaced to Telegram |
| v2.27.2 | `prop:(run\|skip):p-YYYYMMDD-aaaa` | Run/Skip on morning-brief Proposed Moves cards |
| v2.27.3 | `forward_origin metadata` | Surfaces forwarded-message provenance so agent auto-offers to save to memory |
| v2.27.4 | `email:(reply\|archive\|snooze):<gmail-thread-id>` | Reply/Archive/Snooze action buttons on `/inbox` triage cards |

All 5 patches re-apply on every `claude-agent.service` start via `ExecStartPre={{TENANT_AGENT_HOME}}/scripts/patch-channels-plugin.sh`. Sentinel-checked; multi-pass-aware; verified TS-compiles after each pass. Adding a sixth callback flow = adding a sixth pass following the documented pattern.

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

## Author

**Ella is designed and built by [Daniel Gonell](https://danielgonell.com)** — a brand, UX, and AI-systems consultant who builds autonomous tools that let small teams operate like large ones.

The architecture, install scripts, and agent-stack baseline were distilled from a production single-tenant agent Daniel runs for his own consulting practice. The chief-of-staff template, task ledger, proposed-moves system, voice round-trip, memory layer, and Mission Control dashboard were battle-tested across a long live release cycle before being generalized into this multi-tenant template.

- Website / portfolio: **[danielgonell.com](https://danielgonell.com)**
- Questions, ideas, or "I deployed this and here's what happened" → open a [GitHub issue](https://github.com/newmindsgroup/ella-claude-code-ai-agent/issues)

## Acknowledgements

Built on top of work by:
- Anthropic (Claude Code, MCP spec, official MCP servers)
- [Jesse Vincent](https://github.com/obra) (Superpowers plugin, agentic skills patterns)
- [Safi Shamsi](https://github.com/safishamsi) (Graphify)
- [Maciej Sitarzewski](https://github.com/msitarzewski) (agency-agents)
- [VRSEN](https://github.com/VRSEN) (OpenSwarm — 8-specialist multi-agent framework)
- [VoltAgent](https://github.com/VoltAgent) (awesome-design-md / DESIGN.md format)
- [Mendable](https://github.com/mendableai) (Firecrawl)
- [Microsoft](https://github.com/microsoft/playwright-mcp) (Playwright MCP)

If your work is in here and you'd like better attribution or want it removed, open an issue.

---

## Status

**v0.8.0** — feature-complete for autonomous multi-tier delegation + full observability. Memory layer v2, Discord command center, Obsidian mirror, 3-tier sub-agent system, OpenSwarm integration, Mission Control observability stack (rules engine + anomaly detection + ROI/cost tracking), and Telegram ↔ dashboard chat parity (streaming, voice, attachments) — all available, all opt-in via tenant.yml feature flags. Battle-tested in a production single-tenant deployment; the multi-tenant orchestrator (NEW-CLIENT-CLAUDE.md + INTERVIEW.md + DEPLOY-NEW-CLIENT.md) takes a fresh client from blank VPS to a verified green deploy.

See [CHANGELOG.md](CHANGELOG.md) for the full release history.

Issues, PRs, and "I deployed this for company X and here's what broke" reports are all welcome.
