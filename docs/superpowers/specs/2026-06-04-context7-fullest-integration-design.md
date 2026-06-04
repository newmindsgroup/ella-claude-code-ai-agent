# Context7 — Fullest Integration Across the Ella Stack

**Date:** 2026-06-04
**Author:** Daniel Gonell (via Claude Code session)
**Status:** Approved by user, ready for implementation plan
**Repos touched:** `daniel-personal-brand`, `ella-claude-code-ai-agent`, `ai-agent-skills-library`

## Purpose

Context7 is already substantively wired in the Ella reference template (v0.22.0): installer, `.mcp.json` block, CLAUDE.md "ALWAYS use Context7 before generating code" rule, optional API key path. The gaps that remain are:

1. **Daniel's live Chief-of-Staff agent on `projectizer` is built from the Daniel repo, which has zero Context7 wiring** — so the live agent currently has no Context7 access at all. Parity backport is the actual install.
2. Context7 is not smoke-verified, so a silent regression is invisible.
3. Context7 is only callable from the main agent turn — sub-agents, swarms, and skills can't reach it.
4. There is no explicit user surface for forcing a docs lookup (only the inline `use context7` trigger).
5. Code-producing cherry-picked sub-agents (frontend-developer, backend-architect, ai-engineer, security-auditor) have their own system prompts and do not inherit Ella's CLAUDE.md rule.
6. No observability — we cannot see whether Context7 is being called, what libraries are queried most, or whether free-tier rate limits are biting.
7. The integration pattern is not codified in `ai-agent-skills-library`, so a fresh client deploy could reintroduce the same gaps.

This spec closes all seven gaps with six small atomic phases plus a skills-library codification.

## Non-goals (explicit "no redundancy" promise)

- **No new CLAUDE.md rules.** The rule at `vps-setup/agent-template/CLAUDE.md.tmpl:64-76` is already strong; adding more would dilute it.
- **No doc-staleness watcher.** Context7 *is* the staleness fix; a watcher is over-engineering.
- **No paid API key plumbing.** User chose free tier; existing optional-key path stays as-is.
- **No second .mcp.json registration mechanism.** `10-install-context7-mcp.sh` already handles registration.
- **No edits to `docs/context7-setup.md`.** Current contents are accurate.

## Architecture

All work is at the `.tmpl` SSOT layer. `render-and-deploy.sh` propagates `.tmpl` → `agents-config/<tenant>/<file>` and pushes to the live VPS. **No direct edits to rendered tenant files** (per the render-pipeline-SSOT rule).

Three primary repos kept in parity + one auxiliary local repo:

| Repo | Role | Why it's touched |
|---|---|---|
| `daniel-personal-brand` | Live target — builds the CoS agent that runs on `projectizer` as `danielgonell` | Currently has zero Context7 wiring; needs the full backport |
| `ella-claude-code-ai-agent` | Public reference template — what new clients deploy from | Receives the new capabilities (smoke, /docs, sub-agent awareness, MC tile) so future clients get them automatically |
| `ai-agent-skills-library` | Codification layer — runbooks + install scripts that all client deploys read | Receives the `context7-integration-pattern.md` runbook (v1.5.0) |
| `~/src/agency-agents` (auxiliary, local-only) | Cherry-pick installer that writes sub-agent system prompts into `~/.claude/agents/` | Phase 5 only — extends the Daniel-stack header on four code-producing sub-agents |

## Phase 1 — Parity backport (Daniel repo gets Context7 at all)

**Goal:** Daniel's live CoS agent on `projectizer` actually has Context7 installed.

### Files added to `daniel-personal-brand`

| File | Source |
|---|---|
| `agent-stack/scripts/10-install-context7-mcp.sh` | Copied verbatim from `ella-claude-code-ai-agent/agent-stack/scripts/10-install-context7-mcp.sh` |
| `vps-setup/agent-template/.mcp.json.example.tmpl` (add `context7` block) | Match Ella's block at lines 15-21 |
| `vps-setup/agent-template/CLAUDE.md.tmpl` (add §"Library / API docs — ALWAYS use Context7") | Copy lines 64-76 from Ella verbatim — tenant tokens (`{{TENANT_PERSON_FIRST_NAME}}`, `{{TENANT_LINUX_USER}}`, `{{TENANT_AGENT_HOME}}`) are identical across both templates, no rewrite needed |
| `docs/context7-setup.md` | Copy verbatim from Ella (one-paragraph rewrite to swap "the agent" → "the Chief-of-Staff agent") |
| `vps-setup/tenants/danielgonell.yml` | Add `features.context7: true` |
| `agent-stack/scripts/install-all.sh` | Add the `10-install-context7-mcp.sh` line if it's not already there |

### Deploy steps (user runs these)

```bash
# After commit + push:
ssh projectizer
cd /opt/danielgonell/source
git pull
sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
sudo bash agent-stack/scripts/10-install-context7-mcp.sh
sudo -u danielgonell -H claude mcp list | grep context7    # expect: ✓ connected
```

### Acceptance

- `sudo -u danielgonell -H claude mcp list | grep context7` returns `✓ connected`
- In a CoS Claude Code session, asking "What's the current Stripe Node SDK API? use context7" causes a `resolve-library-id` → `get-library-docs` pair of calls (visible in the session log)

### Commit message shape

```
daniel-stack v<next>.<next>.<next> — Context7 MCP parity backport from Ella v0.22.0

Backports the four files Ella v0.22.0 ships to make Context7 default-on for
Daniel's Chief-of-Staff agent on projectizer:
  - agent-stack/scripts/10-install-context7-mcp.sh
  - vps-setup/agent-template/.mcp.json.example.tmpl   (context7 block)
  - vps-setup/agent-template/CLAUDE.md.tmpl           (§ Library / API docs)
  - docs/context7-setup.md
  - vps-setup/tenants/danielgonell.yml                (features.context7: true)

Closes the gap where the live CoS agent had no access to version-aware
library docs and was generating code from training-data guesses.
```

## Phase 2 — Smoke verification (in both Ella + Daniel)

**Goal:** silent Context7 failure becomes a smoke-test red.

### Files modified

`vps-setup/agent-template/scripts/smoke-test.sh.tmpl` in both repos — add two checks at the MCP section:

```bash
# Context7 MCP — registered + reachable
check "Context7 MCP registered with Claude Code" \
  "sudo -u {{TENANT_LINUX_USER}} -H claude mcp list 2>/dev/null | grep -qE '^context7\b'"

check "Context7 MCP package fetchable via npx" \
  "npx -y @upstash/context7-mcp@latest --help >/dev/null 2>&1"
```

### Acceptance

- Smoke count moves from 90 → 92 in Ella, plus +2 in Daniel (current count unknown — measure first).
- Running the smoke test with the MCP intact: both checks pass.
- Running with `context7` removed from `.mcp.json`: first check fails red.

## Phase 3 — VPS skill library install (`context7-cli`)

**Goal:** `skill-runner.sh` and any swarm/agent that reads from the VPS skill library can invoke the `ctx7` CLI for Context7 work outside the MCP path.

### Files added

In **both** templates:

- `vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl` — new installer that:
  1. Verifies `ctx7` global install via `npm list -g ctx7` (installs if missing: `npm install -g ctx7@latest`)
  2. Creates `{{TENANT_AGENT_HOME}}/.agents/skills/context7-cli/` and copies the SKILL.md + references from a baked-in template (rather than reading from the operator's `~/.claude/skills/`, since the VPS doesn't have that)
  3. Idempotent — skips if SKILL.md already present

### Bake-in source

Copy the SKILL.md + `references/` from `/Users/newmindsgroup/.claude/skills/context7-cli/` into the template at:

`vps-setup/agent-template/skills-bundle/context7-cli/`

So the install script reads from the rendered tenant copy, not the operator's machine.

### Wire into `install-all.sh`

Add the new installer to the install chain in both repos.

### Acceptance

- `/opt/danielgonell/.agents/skills/context7-cli/SKILL.md` exists after install
- `which ctx7 && ctx7 --version` returns a version
- A test swarm invocation that does `ctx7 docs fetch "react hooks"` returns content

## Phase 4 — `/docs` slash command (first slash command in either repo)

**Goal:** explicit user-facing surface — type `/docs next.js 15 middleware` and get a docs-grounded answer without typing "use context7".

### Files added

In **both** templates:

- `vps-setup/agent-template/.claude/commands/docs.md.tmpl`

Contents:

```md
---
name: docs
description: Fetch current library/framework docs via Context7 before answering. Use when {{TENANT_PERSON_FIRST_NAME}} asks about a library's current API surface, a version-specific feature, or asks "how do I do X with Y framework".
---

The user invoked `/docs $ARGUMENTS`.

Your job in this turn:
1. Call `mcp__context7__resolve-library-id` with the library name from `$ARGUMENTS`. If a version is mentioned, include it.
2. Call `mcp__context7__get-library-docs` with the resolved ID and the specific question from `$ARGUMENTS`.
3. Answer **only** from the returned snippets. Quote the relevant snippet and cite the section. If Context7 returned nothing useful, say so explicitly — never fall back to training-data guesses.
4. If `$ARGUMENTS` is empty, ask which library + question to look up.

Never skip step 1 or 2. If the MCP is unavailable, surface that as an error rather than improvising.
```

### Acceptance

- In a CoS session on projectizer: `/docs supabase row level security` triggers the two MCP calls and returns a doc-grounded answer with a citation.
- `/docs` (no args) prompts for input.
- If MCP is down: the command says "Context7 MCP unavailable" rather than answering from training data.

## Phase 5 — Sub-agent awareness (cherry-picked agency-agents)

**Goal:** dispatched sub-agents that produce code automatically call Context7 first.

### Background

`~/src/agency-agents/.local-install/manifest.json` selects the 16 cherry-picked sub-agents. Per memory `project_agency_agents_install.md`, five are voice-aware. We need four code-producing agents to also be Context7-aware:

- `frontend-developer`
- `backend-architect`
- `ai-engineer`
- `security-auditor`

### Mechanism

The agency-agents install script (`install.py`) appends a Daniel-stack header to each agent's system prompt. We extend that header for the four named agents with one line:

```md
**Library docs — Context7 first.** Before generating any code that uses a third-party library, SDK, framework, or external API, call `mcp__context7__resolve-library-id` then `mcp__context7__get-library-docs` to ground the code in the current API surface. Do not fall back to training-data guesses.
```

This change lives in `~/src/agency-agents/.local-install/` (not in the Ella/Daniel template repos, since agency-agents has its own install path). Reinstall via the documented `python3 ~/src/agency-agents/.local-install/install.py`.

### Acceptance

- Reading `~/.claude/agents/frontend-developer.md` (post-reinstall) shows the new line under the existing Daniel-stack header.
- Dispatching the agent for a React task: the agent calls Context7 before writing JSX.

## Phase 6 — Mission Control "Library Docs" tile

**Goal:** observability — see Context7 earning its keep.

### Data source

Claude Code writes session JSONL transcripts to `~/.claude/projects/<slugged-project>/*.jsonl`. Each MCP call is one JSON line with `tool_name == "mcp__context7__resolve-library-id"` or `mcp__context7__get-library-docs`.

### Files modified / added

- `vps-setup/agent-template/scripts/dashboard-sync-autonomy.py.tmpl` — extend to write a new endpoint `state/context7.json`:

```json
{
  "calls_24h": 18,
  "calls_7d": 142,
  "top_libraries": [
    { "id": "/vercel/next.js", "calls": 31 },
    { "id": "/supabase/supabase", "calls": 24 },
    ...
  ],
  "last_queries": [
    { "ts": "2026-06-04T15:42:00Z", "library": "/stripe/stripe-node", "query": "subscription update API" },
    ...
  ],
  "free_tier": true
}
```

- `vps-setup/agent-template/dashboard/index.html` — new tab `Library Docs` that fetches `/api/context7.json` and renders three cards: 24h/7d totals, top libraries bar chart, last 5 queries timeline.

### Acceptance

- Smoke check `state/context7.json exists and validates as JSON` (smoke count +1).
- Dashboard tab loads and shows non-zero values after a /docs call.

## Phase 7 (codification) — `ai-agent-skills-library` v1.5.0

**Goal:** every future client deploy gets all six phases automatically.

### Files added

- `runbooks/context7-integration-pattern.md` — runbook documenting the six-phase pattern, when to use it (any client doing software work), what to skip if not (a non-coding client like a sales-only tenant can stop at Phase 1).
- Updates to `SKILLS-CATALOG.md` and `CHANGELOG.md` (v1.4.x → v1.5.0).

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Concurrent committer sweeps stage Context7 patches into an unrelated commit and regresses VERSION | Verify HEAD + VERSION before/after every commit in both repos; commit one phase at a time |
| `npm install -g ctx7` fails on VPS (corporate firewall, npm registry down) | Phase 3 install script does `|| log_warn` instead of `exit 1` — Context7 MCP path still works without the CLI |
| Free-tier rate limit hit during burst use | Phase 6 dashboard surfaces this; if it bites, upgrade to paid key (out-of-scope for this spec) |
| Sub-agent prompt edit (Phase 5) is overwritten by an upstream agency-agents update | The Daniel-stack header is added by `install.py`; re-running it after upstream pull restores the patches. Already documented behavior. |
| The Daniel repo VERSION bumps land out of band with the agent's running version | Render-and-deploy.sh restarts the agent so the new VERSION is the live VERSION post-deploy |

## Acceptance for the whole spec

When all phases ship, the following are true on `projectizer`:

1. `sudo -u danielgonell -H claude mcp list` shows `context7  ✓ connected`
2. Smoke test passes with at least 2 Context7 checks (registered + reachable)
3. `/opt/danielgonell/.agents/skills/context7-cli/SKILL.md` exists
4. `/docs <library> <question>` in the agent works and answers from Context7 snippets, not training data
5. Dispatching `frontend-developer`, `backend-architect`, `ai-engineer`, or `security-auditor` to a code task triggers a Context7 call before generation
6. Mission Control `Library Docs` tab loads and shows real call counts
7. `ai-agent-skills-library` v1.5.0 ships the runbook so every future client gets the same setup

## Out of scope (parking lot)

- Paid Context7 API key wiring beyond what's already in the template
- Dashboard widget for `/docs` invocation from the browser (deferred to a future MC pass)
- Ports to other clients (no other clients exist yet)
- A "Context7 budget guard" similar to the LLM cost ceiling (irrelevant on free tier)
