# Upstream dependencies

Every external git repo, npm package, pypi package, and service this stack depends on. With links, licenses, and explicit reasoning for why each is included.

If you're auditing this for a security-conscious deployment, this is the document to read.

---

## Core (non-negotiable)

### Claude Code
- **Repo:** https://docs.anthropic.com/en/docs/claude-code (official Anthropic CLI)
- **License:** Proprietary (Anthropic) — usage governed by your Anthropic subscription ToS
- **Why:** This is the brain. Everything else orbits around it. The agent runs as `claude --channels plugin:telegram@... --permission-mode dontAsk` inside a tmux session managed by systemd.
- **Auth model:** Anthropic Max, Pro, or Team subscription via `claude login` (browser flow). **No API keys** — that's a deliberate ToS-clean choice.

### Superpowers (engineering rituals plugin)
- **Repo:** https://github.com/obra/superpowers
- **License:** Open source (check the repo for current license)
- **Author:** [Jesse Vincent (obra)](https://github.com/obra)
- **Why:** Provides agentic skills — planning, TDD, systematic debugging, verification, code review, git worktrees, parallel agents. Installed by `01-install-superpowers.sh`.
- **Used by:** The chief-of-staff agent's CLAUDE.md cites Superpowers rituals as the standard for any non-trivial code change.

### agency-agents
- **Repo:** https://github.com/msitarzewski/agency-agents
- **License:** MIT
- **Author:** [Maciej Sitarzewski](https://github.com/msitarzewski)
- **Why:** Curated collection of ~150 specialist sub-agents. We cherry-pick 16 in [`agent-stack/agency-agents-installer/manifest.json`](../agent-stack/agency-agents-installer/manifest.json). The portable installer at [`agent-stack/agency-agents-installer/install.py`](../agent-stack/agency-agents-installer/install.py) handles voice-DNA injection.
- **Cherry-picked agents:** ai-engineer, autonomous-optimization-architect, incident-response-commander, sre, code-reviewer, database-optimizer, agents-orchestrator, workflow-architect, document-generator, agentic-identity-trust, identity-graph-operator, linkedin-content-creator, carousel-growth-engine, ai-citation-strategist, image-prompt-engineer, reality-checker.

### Graphify
- **Repo:** https://github.com/safishamsi/graphify
- **License:** Open source (check the repo)
- **Author:** [Safi Shamsi](https://github.com/safishamsi)
- **Package (PyPI):** `graphifyy` (note double-y)
- **Why:** Turns any folder of code, docs, PDFs, images, video, YouTube transcripts into a queryable knowledge graph. Outputs `graph.html` (interactive viewer), `GRAPH_REPORT.md` (god nodes + surprising connections), `graph.json` (programmatic queries). Installed by `09-install-graphify.sh` via `uv tool install graphifyy`. Registers a `/graphify` slash command for Claude Code.

### Firecrawl
- **MCP Server repo:** https://github.com/mendableai/firecrawl-mcp-server
- **Service:** https://firecrawl.dev — free tier sufficient to start
- **License:** MIT (MCP server); proprietary service
- **Why:** 14-tool MCP server for scrape, search, crawl, structured extract, persistent browser sessions. Pairs with `ai-citation-strategist` for AI-search visibility audits, `competitive-monitor` patterns for site change tracking. Registered by `08-install-firecrawl-mcp.sh`.
- **Pricing:** Free tier has rate limits + monthly quota; paid tiers scale with volume.

### VoltAgent/awesome-design-md
- **Repo:** https://github.com/VoltAgent/awesome-design-md
- **License:** MIT
- **Spec:** https://stitch.withgoogle.com/docs/design-md/format/ (Google Stitch DESIGN.md format)
- **Why:** The DESIGN.md format we use in [`examples/DESIGN.md`](../examples/DESIGN.md). The repo also contains 71 ready-made DESIGN.md files extracted from Apple, Stripe, Linear, Notion, Vercel, Figma, etc. — useful as structural references when authoring your own.

---

## Official MCP servers (Anthropic + community)

### Memory MCP
- **Repo:** https://github.com/modelcontextprotocol/servers/tree/main/src/memory
- **Package:** `@modelcontextprotocol/server-memory`
- **License:** MIT
- **Why:** Knowledge-graph persistent memory across sessions. The agent stores entities, relations, observations and recalls them later. Installed by `02-install-mcp-memory.sh`.
- **State location:** `MEMORY_STORE_PATH` from `client.env` (default `~/.agent-stack/memory.json`).

### Fetch MCP
- **Repo:** https://github.com/modelcontextprotocol/servers/tree/main/src/fetch
- **Package:** `mcp-server-fetch` (Python)
- **License:** MIT
- **Why:** Single-URL HTML→markdown reads. Light-weight web reads. Firecrawl handles the heavy lifting; Fetch is for one-off lookups. Installed by `03-install-mcp-fetch.sh`. Respects `robots.txt`.

### Filesystem MCP
- **Repo:** https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem
- **Package:** `@modelcontextprotocol/server-filesystem`
- **License:** MIT
- **Why:** Scoped file operations within configured directory roots. Installed by `04-install-mcp-filesystem.sh`. Roots set by `KNOWLEDGE_LIBRARY_ROOTS` in `client.env`.

### Playwright MCP
- **Repo:** https://github.com/microsoft/playwright-mcp
- **Package:** `@playwright/mcp`
- **License:** Apache 2.0 (Microsoft)
- **Why:** Headless Chromium browser. Used for smoke tests during `/deploy`, complex scrapes Firecrawl can't handle, end-to-end tests. Installed by `05-install-mcp-playwright.sh`. Downloads ~200 MB on first run.

### Chroma (vector RAG)
- **Repo:** https://github.com/chroma-core/chroma
- **License:** Apache 2.0
- **Why:** Local vector store for RAG over knowledge libraries. Embeds the knowledge library and lets the agent semantic-search across it. Installed by `06-install-mcp-chroma.sh`.
- **Embedding model:** Default = local sentence-transformer (slower, no external dep). Optional = OpenAI embeddings if you set `OPENAI_API_KEY_FOR_EMBEDDINGS` in `client.env`.

---

## Voice round-trip (optional)

### whisper.cpp
- **Repo:** https://github.com/ggerganov/whisper.cpp
- **License:** MIT
- **Why:** Local transcription. Telegram voice notes → text. Runs on the VPS, no cloud calls. Tenant.yml controls model size (tiny/base/small/medium).
- **Cost:** $0 — runs on the VPS CPU/GPU.

### edge-tts
- **Repo:** https://github.com/rany2/edge-tts
- **License:** GPL-3.0
- **Why:** Text-to-speech. Agent replies as audio when voice mode is `always`. Uses Microsoft Edge's free TTS service.
- **Cost:** $0 — free service from Microsoft.
- **Voices:** Multilingual; the example deployment uses an English voice + Dominican Spanish voice with auto-detect.

---

## CRM integration (swap for your CRM)

The example deployment uses [GoHighLevel](https://www.gohighlevel.com/), but the architecture is CRM-agnostic. You'll register your CRM's MCP server in step 7 of the VPS install.

### GoHighLevel MCP (example used in reference deployment)
- **Repo:** https://github.com/mastanley13/GoHighLevel-MCP
- **License:** Check upstream
- **Why:** Email templates, social posts (LinkedIn / IG / TikTok), contacts, calendar, opportunities. Vendored locally so we can patch it (the reference deployment includes a one-line patch fixing `getSocialAccounts()`).
- **Patch infrastructure:** [`vps-setup/mcp-patches/apply.sh`](../vps-setup/mcp-patches/apply.sh) idempotently re-applies any `*.patch` files in that directory. Re-run after `npm install` over the MCP repo.

### Alternatives
- **HubSpot MCP** — https://github.com/PipedreamHQ/pipedream/tree/master/components/hubspot (or roll your own)
- **Salesforce MCP** — https://github.com/anthropics/model-context-protocol/tree/main/examples/salesforce (community)
- **Pipedrive MCP** — community implementations exist

For any CRM, the integration pattern is:
1. Register MCP in `/opt/<tenant>/agents/.mcp.json`
2. Update the chief-of-staff CLAUDE.md "Long-form output routing" section to reference the right MCP tools
3. Voice-aware sub-agents pick up the MCP automatically

---

## Telegram bridge

### claude-plugins-official (telegram channel)
- **Source:** vendored at `/opt/<tenant>/.claude/plugins/cache/claude-plugins-official/telegram/`
- **License:** Check upstream
- **Why:** Bridges Telegram Bot API to Claude Code's "channels" abstraction. Patched in-place by `patch-channels-plugin.sh` on every `claude-agent.service` start (ExecStartPre). Patches are idempotent and survive plugin updates.
- **What the patches enable:**
  - `v2.22.2`: deploy command callbacks (Ship/Cancel buttons)
  - `v2.24.0`: draft approval callbacks (✅ Ship / ❌ Hold / ✏️ Revise)
  - `v2.27.2`: proposal approval callbacks (Run/Skip for Proposed Moves)
  - Pass 4: forward-to-memory detection (forward a message to the bot, agent treats it as a memory observation)
  - Pass 5: react-as-progress (👀✍️👌 reactions update the same message bubble)

The patches are in [`vps-setup/agent-template/scripts/patch-channels-plugin.sh`](../vps-setup/agent-template/scripts/patch-channels-plugin.sh) and re-applied automatically on every service restart.

---

## Infrastructure

### nginx
- **Why:** Serves the Mission Control dashboard at `dashboard.<tld>` behind basic-auth, with TLS, with the critical `Cache-Control: private, no-store, must-revalidate, always` header (without `always`, 401 responses get edge-cached and auth leaks).

### Cloudflare (recommended)
- **Why:** TLS termination, DDoS, edge cache. Use Cloudflare Origin certs for the wildcard `*.<your-tld>`. Tenant.yml declares the cert + key paths.
- **Cost:** Free tier sufficient.

### Vultr / DigitalOcean / Hetzner / etc.
- **Why:** The VPS itself. Anything that runs Ubuntu 22.04+ cleanly works. Reference deployment is on Vultr (`projectizer`, ~$20/month).

---

## Python packages (pip-installed)

These are pulled in by various install scripts; listed for inventory:

- `pyyaml` — for tenant.yml parsing
- `httpx` — used by some MCP servers
- `chromadb` — Chroma vector store
- `whisper.cpp` Python bindings (or compiled binary)
- `edge-tts` — TTS

---

## Why we chose these vs. alternatives

| Decision | Alternative considered | Why we picked this |
|---|---|---|
| Claude Code over API wrapper | OpenAI SDK + custom orchestration, LangChain, AutoGPT | ToS-clean, no API keys, gets Anthropic features (caching, computer use, sub-agent harness) for free |
| Single-tenant per VPS | Multi-tenant on shared infra | Clean data separation, no noisy-neighbor, easy migration, simpler ops |
| Markdown for behavioral spec | YAML config / JSON schema | LLMs read markdown best; markdown supports prose + structure naturally |
| Telegram for chat | Slack / Discord / SMS | Free unlimited bot API, voice notes, mini-apps, callback buttons, mobile-first |
| Tmux + systemd | Docker + Compose | Lower overhead, easier debugging, agent's `~/.claude/` config persists trivially |
| Anthropic Max subscription | API metered billing | Predictable cost ($200/mo), no surprise bills from a runaway agent loop |
| Cloudflare basic-auth dashboard | Public dashboard with login form | Simpler, fewer attack surfaces, works on mobile out of the box |
| Vendored Telegram plugin patches | Forking the plugin | Patches are small, upstream evolves quickly, idempotent re-application is cheap |

---

## Keeping dependencies fresh

For the upstream repos we pull at install time (`agency-agents`, the channels plugin), the install scripts use `git fetch + reset --hard origin/HEAD` so re-running picks up upstream changes. For npm/pypi packages, we pin to the latest at install time.

If you want to lock to specific versions for stability, edit:
- `agent-stack/scripts/02-08-install-mcp-*.sh` — replace `npx -y <pkg>` with `npx -y <pkg>@<version>`
- `agent-stack/scripts/09-install-graphify.sh` — replace `uv tool install graphifyy` with `uv tool install graphifyy==<version>`
- `agent-stack/scripts/07-install-agency-agents.sh` — pin the upstream commit hash via `git checkout <sha>`

Per the [operating principles](../vps-setup/runbooks/operating-principles.md), pinning is recommended for production deployments where you don't want surprise upstream behavior changes.
