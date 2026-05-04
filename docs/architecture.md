# Architecture

End-to-end view of how Ella works: where each piece lives, how data flows, what runs as a service, and what's just markdown.

---

## The 30,000-foot view

Ella is a **chief-of-staff agent** built on Claude Code with a curated set of:

1. **MCP servers** for tool integrations (CRM, web scraping, knowledge graph, vector RAG, browser automation, persistent memory, filesystem)
2. **Sub-agents** for specialist work (21 across engineering, marketing, design, testing, content production)
3. **A behavioral spec** (`CLAUDE.md`) that catalogs the above and gives the agent explicit *Tool-Leverage Heuristics* mapping common situations to the right tool combos
4. **A persistent task ledger + goals system** so the agent never forgets a commitment
5. **A Telegram bridge** for natural-language interaction from your phone (text, voice notes, mini-apps)
6. **A public dashboard** for telemetry, task status, and goal tracking
7. **An autonomous deploy command** so version releases happen from your phone

---

## Two installation modes

### Mode 1 — Local install (laptop / dev machine)

You install `agent-stack/` into your existing Claude Code setup. You get the **rituals + sub-agents + MCPs + brand-voice infrastructure** in any local Claude Code session, but the agent only runs when you're actively chatting with it.

Use this for:
- Adding the rituals layer to your day-to-day Claude Code work
- Trying out the sub-agents and tools before going to production
- Working on client projects locally with brand voice + DESIGN.md enforced

[→ docs/install-local.md](install-local.md)

### Mode 2 — VPS install (production always-on agent)

You deploy the full multi-tenant stack on a Linux VPS. Claude Code runs continuously inside a tmux session managed by systemd. The agent is reachable via your Telegram bot 24/7. A nginx-fronted dashboard at `your-domain.com` shows real-time activity.

Use this for:
- Running an autonomous chief-of-staff for a business
- Multi-tenant deployment (one VPS per tenant, same template)
- Phone-first workflows where you message a bot and the agent does the work

[→ docs/install-vps.md](install-vps.md)

---

## What lives where (production VPS layout)

```
/opt/{tenant_id}/                                  ← Linux user home for the agent
├── agents/                                        ← The agent's working directory (cwd at runtime)
│   ├── CLAUDE.md                                  ← Behavioral spec, rendered from agent-template
│   ├── .mcp.json                                  ← Project-scope MCP servers (firecrawl, ghl, etc.)
│   ├── .credentials.json                          ← Claude Code OAuth token (mode 600)
│   ├── {tenant-business-repo}/                    ← The brand canon — content, design, docs
│   ├── scripts/                                   ← deploy.sh, tg-send.sh, task-ledger.sh, ...
│   ├── tasks/                                     ← Task ledger (JSON state machine)
│   ├── goals/                                     ← Goal vault (quarterly OKRs)
│   ├── memory/                                    ← Knowledge-graph MCP store
│   ├── deploys/                                   ← /deploy command state files
│   ├── ghl-mcp/                                   ← Vendored CRM MCP (or whatever CRM)
│   └── channels/                                  ← Telegram message log (rotating)
├── .claude/                                       ← Claude Code user-level config
│   ├── agents/                                    ← Sub-agent .md files (16 from agency-agents + custom)
│   ├── skills/                                    ← Skill files (incl. graphify SKILL.md)
│   ├── plugins/cache/                             ← Vendored plugins (telegram, etc.) — patched on every restart
│   └── projects/                                  ← Per-project session state
├── .local/
│   ├── bin/graphify                               ← Graphify CLI
│   └── share/agency-agents/                       ← Cloned upstream agency-agents repo
└── .agent-stack/                                  ← Memory + Chroma DB stores
    ├── memory.json                                ← Memory MCP knowledge graph
    └── chroma_db/                                 ← Vector embeddings of knowledge library

/var/www/{tenant-domain}/                          ← Nginx-served dashboard
├── index.html                                     ← Mission Control dashboard SPA
└── api/*.json                                     ← Endpoints (tasks, telemetry, goals, queue, memory, health, meta)

/etc/systemd/system/                               ← Systemd units
├── claude-agent.service                           ← The brain (Claude Code in tmux)
├── dashboard-chat.service                         ← FastAPI for in-dashboard chat (port 8001)
├── telemetry-calc.timer                           ← Recompute per-task cost every 5 min
├── telegram-poller-watchdog.timer                 ← Detect bun-death, auto-restart
├── deploy-timeout-sweep.timer                     ← Cancel stale /deploy runs every 30 min
└── blueprint-pull.timer                           ← Auto-pull from main every 60s

/var/log/{tenant_id}-*                             ← Diagnostic logs (bun-death, watchdog actions, deploy timeouts)
/var/lib/{tenant_id}/watchdog-restart-history.txt  ← Circuit-breaker state
```

Path templates use `{tenant_id}`, `{tenant-domain}`, `{tenant-business-repo}` — these come from `vps-setup/tenants/<your-tenant>.yml` and get substituted at render time by `render-tenant.sh`.

---

## Service health

Five core services + 1 sweep timer. Health-check via `vps-setup/scripts/health.sh`:

| Service | What it does | Failure mode |
|---|---|---|
| `claude-agent.service` | The brain — Claude Code in tmux | Auto-restarted by watchdog if telegram poller stops |
| `dashboard-chat.service` | FastAPI on `127.0.0.1:8001` for in-dashboard chat | Restarts independently of agent |
| `telemetry-calc.timer` | Every 5 min — recomputes per-task cost, writes `api/telemetry.json` | Logs to journalctl; non-critical if delayed |
| `nginx` | Serves dashboard + API endpoints | Standard nginx semantics |
| `telegram-poller-watchdog.timer` | Every 5 min — detects bun-death, auto-restarts agent if telegram stops responding | Has a circuit breaker (3 restarts in 30 min trips it) |
| `deploy-timeout-sweep.timer` | Every 30 min — cancels stale `/deploy` runs that didn't reach `ready_to_ship` | Prevents zombie deploys |

---

## Data flow — what happens when you message the bot

```
1. User sends a Telegram message:  "draft me this week's newsletter on AI agents"
                ↓
2. Telegram → patched channels-plugin → claude-agent.service
                ↓
3. Agent reads CLAUDE.md (behavioral spec), classifies intent:
       trivial / specialized / conversational / ambiguous
                ↓
4. "Specialized work" → matches voice-aware content-agent → delegates via Task tool
                ↓
5. Sub-agent (linkedin-content-creator or content-agent):
       a. Reads brand voice playbook (15_Brand_Behavior_Playbook.md)
       b. Checks against banned phrases
       c. Drafts the newsletter
                ↓
6. Agent stages draft as DRAFT email template in CRM (e.g. GHL)
                ↓
7. Agent creates task in task ledger (state: awaiting_review)
                ↓
8. Agent replies in Telegram with:
       - First 200 chars preview
       - Link to the draft in the CRM
       - Inline approval buttons: ✅ Ship  ❌ Hold  ✏️ Revise
                ↓
9. User taps a button on phone → callback_data routes through patched plugin
                ↓
10. Agent receives callback as synthetic message → executes Ship/Hold/Revise
                ↓
11. Task ledger transitions to done/cancelled/in_progress accordingly
```

---

## Mission Control dashboard

The dashboard at `dashboard.{your-tld}` is a **single-page HTML app** served by nginx, behind basic-auth, with backing JSON endpoints written by:

- `dashboard-sync.sh` — pulls task ledger + goals + memory state every 60s
- `telemetry-calc.py` — computes per-task wall-time, tokens, API cost, "human-equivalent value" every 5 min

The dashboard reads the JSON endpoints, renders KPI cards (open tasks, deals in pipeline, API spend MTD, goal progress), shows the live task ledger filtered by state, and exposes a Chat tab that talks to `dashboard-chat.service` (a FastAPI server on `127.0.0.1:8001` that proxies into the same Claude Code instance the Telegram bot uses — so chats from the dashboard create tasks in the same ledger as Telegram chats).

---

## Multi-tenant template

Everything tenant-specific lives in `vps-setup/tenants/{tenant_id}.yml`. The engine — sub-agents, scripts, systemd units, Telegram tooling, task ledger, dashboard — is identical across tenants.

```
                vps-setup/agent-template/             ← The recipe (templated with {{TENANT_*}})
                          │
                          │  bash render-tenant.sh tenants/<tenant>.yml
                          ▼
                vps-setup/agents-config/<tenant>/     ← Rendered output for one tenant
                          │
                          │  bash bootstrap-tenant.sh tenants/<tenant>.yml
                          ▼
            /opt/<tenant>/agents/  +  /etc/systemd/system/<tenant>-*  +  /var/www/<tenant-domain>/
```

To stand up a new client / business:
1. Copy `vps-setup/tenants/EXAMPLE_TENANT.yml` to `vps-setup/tenants/<your-id>.yml`, fill in values
2. `render-tenant.sh` walks the template, substitutes every `{{TENANT_*}}` token
3. `bootstrap-tenant.sh` deploys the rendered files to the VPS, sets up systemd units, registers MCP servers

[→ vps-setup/PORTING.md](../vps-setup/PORTING.md) walks through the full procedure.

---

## Operating principles (non-negotiable)

The 7 commitments in [`vps-setup/runbooks/operating-principles.md`](../vps-setup/runbooks/operating-principles.md) govern every infrastructure change:

1. **Idempotent installs.** Re-running any script is safe and deterministic.
2. **Dry-run before production changes.** Especially anything touching systemd, nginx, or the agent service.
3. **Append-only audit logs.** `implementation-log.md`, task ledger, goal vault — all append-only.
4. **No force-push to main.** Ever. History is the audit trail.
5. **Don't batch-restart the agent.** 2+ manual restarts within 30 min collide with the watchdog circuit breaker. Pre-prune `/var/lib/{tenant}/watchdog-restart-history.txt` if you must restart twice.
6. **CDN + basic-auth cache rule.** Internal vhosts behind Cloudflare need `Cache-Control: private, no-store, must-revalidate, always` or auth leaks via edge cache.
7. **Memory entries for every meaningful change.** For rollback AND portability to other agent installs.

These are not aspirational — they're the rules that emerged from real outages. Read [`operating-principles.md`](../vps-setup/runbooks/operating-principles.md) before making any infrastructure change.

---

## Why this architecture

Three design decisions worth calling out:

**1. Single-tenant, single-VPS.**
Each tenant gets their own VPS. No multi-tenant noisy-neighbor. No shared brain. Each tenant owns their Anthropic subscription, their data, their VPS. Clean separation, easy migration, no SaaS vendor lock-in. The multi-tenant *template* is for replicating quickly — not for running multiple businesses on one machine.

**2. Claude Code as the brain — no API wrappers.**
Anthropic Max/Pro/Team subscriptions, no API keys. ToS-clean. No third-party "agent framework" between Claude and your work. When Claude Code ships an update, the agent gets it — no mediator that breaks features or charges a margin.

**3. Markdown over schemas wherever possible.**
Behavioral spec is markdown. Voice playbook is markdown. DESIGN.md is markdown. Brand canon is markdown. The agent reads markdown most reliably. Schemas where they matter (tasks, telemetry, MCP config), markdown everywhere else.
