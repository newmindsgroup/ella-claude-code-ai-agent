# Local install — laptop / dev machine

Adds the Ella agent-stack (rituals + sub-agents + MCP servers + brand-voice infrastructure) to your local Claude Code setup. ~15 minutes on a clean Mac or Linux laptop.

This does NOT stand up an always-on Telegram-reachable agent — that's [`install-vps.md`](install-vps.md). Use this when you want the rituals, sub-agents, and tools available in any local Claude Code session.

---

## Prerequisites

| Requirement | Check command | Install if missing |
|---|---|---|
| Claude Code 2.x+ | `claude --version` | https://docs.anthropic.com/en/docs/claude-code/quickstart |
| Authenticated | `claude auth status` | `claude login` |
| Node 18+ | `node --version` | https://nodejs.org or `fnm install 24` |
| Python 3.10+ | `python3 --version` | https://www.python.org or `brew install python` |
| Git | `git --version` | `brew install git` (Mac) / `apt install git` (Linux) |
| `uv` (recommended) | `uv --version` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` — script 09 will install it for you if missing |

---

## Step 1 — Clone the repo

```bash
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent.git ~/ella
cd ~/ella
```

---

## Step 2 — Create your config

```bash
cp agent-stack/config/client.example.env agent-stack/config/client.env
$EDITOR agent-stack/config/client.env
```

Required variables:

```bash
CLIENT_NAME="my-laptop"                                # Anything — used in logs
CLAUDE_PROJECT_ROOT="$HOME/code/your-main-project"     # The repo Claude Code primarily operates in
KNOWLEDGE_LIBRARY_ROOTS="$HOME/code/your-main-project,$HOME/Documents/knowledge"
MEMORY_STORE_PATH="$HOME/.agent-stack/memory.json"
CHROMA_DB_PATH="$HOME/.agent-stack/chroma_db"

# agency-agents (script 07)
AGENCY_AGENTS_CACHE_DIR="$HOME/.local/share/agency-agents"
CLAUDE_AGENTS_DIR="$HOME/.claude/agents"
BRAND_VOICE_PATHS_FILE=""    # leave empty for laptop install — voice precedence comes from user-level CLAUDE.md

# Firecrawl (script 08) — optional. Get a free-tier key at https://firecrawl.dev/app/api-keys
FIRECRAWL_API_KEY=""         # leave empty to skip Firecrawl install
AGENT_MCP_JSON_PATH=""       # leave empty for laptop — script 08 will fall back to `claude mcp add`

# Logging
INSTALL_LOG_PATH="$HOME/.agent-stack/install.log"
```

---

## Step 3 — Run install-all

```bash
bash agent-stack/scripts/install-all.sh
```

This runs scripts 00 → 09 in sequence:

1. **00 — prereqs check** — bails out with a clear message if something's missing
2. **01 — Superpowers** — installs the engineering rituals plugin
3. **02 — Memory MCP** — knowledge graph across sessions
4. **03 — Fetch MCP** — single-URL HTML→markdown reads
5. **04 — Filesystem MCP** — scoped file ops
6. **05 — Playwright MCP** — headless browser (~200 MB — this is the slow step)
7. **06 — Chroma MCP** — local vector RAG
8. **07 — agency-agents** — clones the upstream repo, installs 16 cherry-picked sub-agents to `~/.claude/agents/`
9. **08 — Firecrawl MCP** — registers the Firecrawl MCP server (skipped if no API key)
10. **09 — Graphify** — installs `uv` if missing, then `graphifyy` via uv, then registers the Claude Code skill

Total time on a clean laptop: ~10–15 minutes. All scripts are idempotent — safe to re-run if any step fails.

---

## Step 4 — (Recommended) Set up brand-voice + visual SSOT

If you have a brand of your own (or a client's), drop the templates from `examples/` into your project root and customize:

```bash
cd ~/code/your-main-project
cp ~/ella/examples/AGENTS.md .
cp ~/ella/examples/DESIGN.md .
cp ~/ella/examples/voice-playbook.example.md ./brand-voice-playbook.md   # name as you like
$EDITOR AGENTS.md DESIGN.md brand-voice-playbook.md
```

Then optionally tell Claude Code where they live by adding a section to your user-level `~/.claude/CLAUDE.md`:

```markdown
## Brand Voice — Single Source of Truth

For ANY human-facing copy, the canonical voice spec lives in this exact order of precedence:

1. `brand-voice-playbook.md` (project root)
2. `AGENTS.md` (project root)

Banned phrases: <list yours here>

## Brand Visual — Single Source of Truth

For ANY UI / image / deck / visual artifact:

1. `DESIGN.md` (project root)
2. `design-system/tokens/tokens.json` (if you maintain one — machine canonical)
```

Voice-aware sub-agents (`linkedin-content-creator`, `carousel-growth-engine`, `ai-citation-strategist`, `image-prompt-engineer`, `document-generator`) read these references before drafting.

---

## Step 5 — Verify

```bash
bash agent-stack/scripts/99-verify-all.sh
```

You should see:
- ✅ Superpowers plugin installed
- ✅ Memory / Fetch / Filesystem / Playwright / Chroma MCPs registered
- ✅ Firecrawl MCP registered (or skipped with reason)
- ✅ 16 agency-agents in `~/.claude/agents/`
- ✅ Graphify CLI on PATH

---

## Step 6 — Smoke test

Open a new Claude Code session in any project and try:

| What to type | What should happen |
|---|---|
| "Help me draft a LinkedIn post about <topic>" | Routes to `linkedin-content-creator` sub-agent (defers to brand voice playbook if configured) |
| "Map this codebase before I work on it" | Triggers `/graphify .` |
| "Is this branch ready to ship?" | Routes to `reality-checker` |
| "Production looks broken, the service crashed" | Routes to `incident-response-commander` |
| "Search the web for X" (with Firecrawl) | Uses `firecrawl_search` tool |

Sub-agents auto-route via their description triggers — you don't need to remember names. If something doesn't auto-route, the description triggers in the agent's frontmatter need to match more keywords.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `claude: command not found` | Install Claude Code; ensure it's on PATH |
| `claude auth status` says "not authenticated" | Run `claude login` |
| Script 09 fails with `uv not found` | Run the Astral installer: `curl -LsSf https://astral.sh/uv/install.sh \| sh`, then re-run script 09 |
| Sub-agents don't appear in `~/.claude/agents/` | Check `BRAND_VOICE_PATHS_FILE` is empty (or set to a real file) — the script will refuse to run if it points at a non-existent file |
| Firecrawl MCP not connecting | `claude mcp list` to see status; check `FIRECRAWL_API_KEY` is in your shell env (`launchctl getenv FIRECRAWL_API_KEY` on Mac, `echo $FIRECRAWL_API_KEY` on Linux) |
| `npx` errors on script 02–08 | Update Node (script needs Node 18+) — `fnm install 24 && fnm use 24` |

---

## Uninstall

The install is fully reversible. Each piece can be removed independently:

```bash
# Remove cherry-picked sub-agents
grep -l "agency-agents-cherry-pick" ~/.claude/agents/*.md | xargs rm

# Remove Firecrawl MCP
claude mcp remove firecrawl

# Remove Graphify
uv tool uninstall graphifyy
rm -rf ~/.claude/skills/graphify

# Remove agent-stack stores
rm -rf ~/.agent-stack/

# Remove the cloned upstream agency-agents
rm -rf ~/.local/share/agency-agents
```

Memory and Chroma MCPs registered via `claude mcp add` get removed similarly: `claude mcp remove memory`, etc.
