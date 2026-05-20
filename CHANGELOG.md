# Changelog

All notable changes to this repo. Format roughly follows [Keep a Changelog](https://keepachangelog.com/). This is a multi-tenant template, so versions reflect what's available to clone for a new tenant — not what's running at any one customer's deployment.

## [v0.8.1] — 2026-05-20

### Changed — Authorship attribution + post-v0.8 leak re-scrub

Establishes clear authorship for the project and re-runs the public-readiness scrub against content added in v0.7.0 → v0.8.0 (which landed after the v0.6.1 scrub and reintroduced a few single-tenant references).

**Authorship:**
- **`LICENSE`** + **`NOTICE`** — copyright holder is now **Daniel Gonell** (was "New Minds Group"). NOTICE adds a "Created by Daniel Gonell — https://danielgonell.com" line.
- **`README.md`** — subtle byline under the badges, a dedicated **Author** section linking to [danielgonell.com](https://danielgonell.com), and the old "Credits" section split into Author + Acknowledgements. Status bumped to v0.8.0.
- **`CITATION.cff`** (new) — enables GitHub's "Cite this repository" sidebar button, crediting Daniel Gonell as author. A subtle, standard portfolio/credit surface.
- **`SECURITY.md`** — security contact routed through [danielgonell.com](https://danielgonell.com) instead of an org email, consistent with solo authorship.

**Leak re-scrub (v0.7/v0.8 content):**
- **`dashboard/index.html`** — the v0.8 chat work reverted the `<title>` back to a hardcoded name; restored to `{{TENANT_PERSON_FULL_NAME}}`.
- **`dashboard-chat/server.py`**, **`scripts/_deploy_states.py`**, **`scripts/rules-engine.py`** — bare author name in comments → `{{TENANT_PERSON_FIRST_NAME}}`.
- **`tests/conftest.py`** — "the upstream Daniel Gonell tenant" comment → "the upstream production tenant" (tests aren't rendered, so no placeholder).
- **`CLAUDE.md.tmpl`** — illustrative examples used a real service name + price ("Brand Blueprint Intensive", "$12K"). Genericized to "engagements" / "flagship engagement" so the public template isn't tied to one consultant's offer. (These predated v0.6.1 and were missed by the first scrub.)

### Result

- 0 unintended single-tenant references in the template or rendered output.
- The only remaining "Daniel Gonell" references are intentional: the `LICENSE`/`NOTICE` copyright holder, the `README`/`CITATION.cff` author credit, and `CHANGELOG.md` historical attribution.

---

## [v0.8.0] — 2026-05-20

### Added — Telegram ↔ Mission Control chat parity + voice + attachments

Ports the upstream Daniel Gonell tenant's chat suite (v2.61–v2.64) into the template. The dashboard chat now matches a ChatGPT/Claude experience AND stays in sync with Telegram, so a tenant can use either surface interchangeably. **Purely additive — Telegram keeps working exactly as before; the two surfaces just mirror each other.**

**Unified conversation store (v2.61):**
- **`dashboard-chat/_conversation.py`** — SQLite store (`conversation.db`) that is the single source of truth for the chat thread. Per-message rows tagged by source (dashboard/telegram/voice), with role, tokens, cost, attachments. Both surfaces read + write it.

**Streaming rich-text chat (v2.61):**
- `POST /api/chat/stream` — SSE token-delta streaming (`--include-partial-messages`) for a progressive render.
- `GET /api/chat/history` reads the unified store (per-message, source-tagged); `DELETE` clears it.
- Frontend: streaming with blinking caret + Stop button, markdown rendering (incl. fenced code blocks), per-message copy + regenerate, source badges, live SSE updates.

**Telegram ↔ dashboard sync (v2.62):**
- `POST /api/chat/ingest` — receives a message from another surface, stores + broadcasts via SSE.
- `tg-send.sh` tee — outbound Telegram messages (briefs, watchers, proactive replies) also appear in the dashboard. `--no-conversation-log` opts out.
- Dashboard chat exchanges mirror to Telegram (`MIRROR_DASHBOARD_TO_TELEGRAM`, default on, loop-safe).
- **`patch-channels-plugin.sh` PASS 6** — captures inbound Telegram user messages → `/api/chat/ingest`. Reuses PASS 4's proven `handleInbound` anchor + side-effecting-IIFE shape; fire-and-forget so a down backend never blocks delivery. Applies on the next claude-agent restart via ExecStartPre.

**Voice (v2.63):**
- `POST /api/chat/transcribe` — browser mic upload → whisper.cpp (`voice-transcribe.sh`) → text.
- `POST /api/chat/tts` — agent reply → edge-tts (`voice-reply.sh`) → OGG audio.
- Frontend: mic record button (click-to-toggle, auto-send transcript), 🔊 speak button per agent message, auto-voice toggle (persisted). `requirements.txt` gains `python-multipart`.

**Files + images (v2.64):**
- `POST /api/chat/upload` (allowlist + 30MB cap, path-traversal-safe serve) → files land under AGENT_HOME so the agent can Read them; `build_agent_prompt()` tells it where.
- Frontend: paperclip attach + paste-image, pending-preview strip, inline rendering (images as `<img>`, files as chips).

### Verified
- `render-tenant.sh EXAMPLE_TENANT.yml` → 169 clean files, no placeholder leaks.
- `pytest tests/` → all green (adds `test_conversation.py`).

### Deploy note
Needs a `dashboard-chat.service` restart + `pip install -r dashboard-chat/requirements.txt`. PASS 6 (Telegram inbound capture) applies on the next `claude-agent` restart. Known follow-up: the Telegram plugin's *native* agent replies (not sent via tg-send.sh) aren't captured yet — needs a PASS 7 anchor in the plugin's send path.

---

## [v0.7.1] — 2026-05-19

### Added — Deployment polish (autonomous local-agent driven deploys)

Closes the deploy-flow gap left by v0.7.0. After v0.7.0 added Mission Control's runtime components, the docs + scripts that orchestrate a fresh client deploy didn't know about them yet. v0.7.1 closes that loop so a local agent (Claude Code / Cursor / Codex) can read one script, ask the human the right questions, provision + render + bootstrap + verify autonomously, and confirm a green deploy without a human chasing systemd units.

**New documents:**
- **`INTERVIEW.md`** — Conversational dialogue script for the local agent. 9 sections (About you / About the brand / Voice / VPS / Domain + TLS / Integrations / Cost preferences / Feature toggles / Confirm). Each question tagged REQUIRED or OPTIONAL with validation rules and a mapping to where the answer lands (`client-credentials.md` vs `tenant.yml`). Branching logic for "have you done this before / want me to provision?" forks. Tone notes for the local agent (ask one question at a time, reflect what you heard, don't be a wizard).

**New scripts:**
- **`vps-setup/scripts/bootstrap-mission-control.sh`** — Single-command wire-up of every v0.7.0 Mission Control component. Installs Python deps (FastAPI, uvicorn, pyyaml), creates `state/spans.db`, enables + starts `dashboard-chat.service`, `rules-engine.timer`, `anomaly-detect.timer`, `session-parser.timer`. Honors feature flags from `.env-deploy`. Smoke-tests the FastAPI backend. Reloads nginx. Idempotent.
- **`vps-setup/scripts/post-deploy-verify.sh`** — Single-command "is the deploy green?" check. Runs from the local Mac against the deployed VPS. Verifies: VPS reachability, 14 systemd units active, 15 `/api/*.json` endpoints serve valid JSON behind basic-auth, SSE handshake works, dashboard-chat backend reachable, 53-test pytest suite passes. Exit 0 = green deploy.

**Updated documents:**
- **`NEW-CLIENT-CLAUDE.md`** — New Phase 0.5 ("if credentials missing, run INTERVIEW.md"), new Phase 7c ("Mission Control bring-up via bootstrap-mission-control.sh"), new Phase 8b ("Post-deploy verification via post-deploy-verify.sh"). Added `mission_control_v0_7` to feature-decisions table.
- **`vps-setup/DEPLOY-NEW-CLIENT.md`** — New Phase 9.5 (Mission Control bring-up) + Phase 10.5 (Post-deploy verify). Both runbook updates reference the new scripts.
- **`vps-setup/scripts/preflight-new-client.sh`** — New section 10 ("Mission Control deps — Python 3.11+ + FastAPI + sqlite3"). Checks VPS Python version, sqlite3 module, pyyaml, fastapi, uvicorn, nginx. Warns (not fails) on missing deps — bootstrap-mission-control.sh installs them. Existing OpenSwarm check moved to section 11.

**Updated config templates:**
- **`vps-setup/tenants/EXAMPLE_TENANT.yml`** — Added v0.7.0 feature flags (`mission_control_v0_7`, `enable_rules_engine`, `enable_anomaly_detection`, `enable_session_parser`, `enable_circuit_breakers`, `enable_watchers`, `enable_observability_dashboard`). Added `roi_hourly_rates` block with 20 task types + sensible defaults. Added `cost_ceiling_daily_usd` + `cost_ceiling_block_hours` for the global circuit breaker.
- **`examples/client-credentials.template.md`** — Added "v0.7 MISSION CONTROL — Cost preferences" section. Updated checklist with v0.7 review step.

### Verified
- `bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/EXAMPLE_TENANT.yml` produces 165 clean files (no new render warnings).
- `pytest tests/` runs 53/53 green.
- `bash -n` syntax check passes on bootstrap + verify + preflight scripts.

### Why this matters
Before v0.7.1, deploying a new client meant the operator had to know about: the credentials template, the deploy runbook, the preflight script, and now (post-v0.7.0) the existence of Mission Control's new components. A local agent following NEW-CLIENT-CLAUDE.md would skip the new Mission Control bring-up because the runbook didn't mention it. v0.7.1 makes the deploy flow auto-discoverable: the local agent reads NEW-CLIENT-CLAUDE.md, gets pointed at INTERVIEW.md for missing credentials, runs preflight (which now checks Mission Control deps), follows the runbook (which now has Mission Control phases), and ends at post-deploy-verify.sh (which doesn't return 0 until everything's green).

---

## [v0.7.0] — 2026-05-19

### Added — Mission Control Phase 1-4 (full observability stack)

The biggest substantive upgrade since v0.5. Brings the template fully current with the upstream Daniel Gonell tenant at v2.60.0. Every new client deploy now ships with full observability of every agent action — what they're doing, how long it's taking, what it's costing, and what it would have cost a human.

**Phase 1 — Audit + lifecycle (v2.46→v2.47):**
- **`vps-setup/agent-template/dashboard-chat/server.py`** — full FastAPI write-action layer (200+ lines, was missing entirely from Ella). Endpoints: `/api/chat`, `/api/chat/audit` GET/POST, `/api/chat/snooze` GET/POST/DELETE, `/api/chat/skills/run` POST, `/api/chat/rules` GET, `/api/chat/rules/run` POST, `/api/chat/events` SSE, `/api/chat/budget` GET/POST/DELETE. Bound to 127.0.0.1:8001, fronted by nginx with HTTP basic-auth.
- **`vps-setup/agent-template/systemd/dashboard-chat.service.tmpl`** — systemd unit for the FastAPI backend.
- **`vps-setup/agent-template/scripts/ops/ops-service-restart.sh`** — added `--no-block` flag for Run-now buttons; added `rules-engine`, `anomaly-detect`, `session-parser` to allowlist.

**Phase 2 — Behavioral rules engine (v2.48):**
- **`vps-setup/agent-template/scripts/rules-engine.py`** (388 lines) — YAML-DSL rules evaluated every 5 min. Operators: `>=, >, ==, <=, <, !=, in, contains`. Actions: `telegram`, `audit`, `log`, `circuit_breaker` (v2.57). Per-rule throttle window.
- **`vps-setup/agent-template/rules/*.yaml`** — 5 starter rules: drift-persistent-escalate, inbound-high-pileup, cost-spike-escalate, anomaly-cost-z-spike, budget-ceilings.
- **`vps-setup/agent-template/systemd/rules-engine.{service,timer}.tmpl`** — every 5 min.

**Phase 2.5 — Anomaly detection (v2.49):**
- **`vps-setup/agent-template/scripts/anomaly-detect.py`** — rolling z-score + EWMA over telemetry.json daily_token_history. Thresholds: 2.0σ noteworthy, 3.0σ extreme.
- **`vps-setup/agent-template/systemd/anomaly-detect.{service,timer}.tmpl`** — every 30 min.

**Phase 2.7 — pytest harness (v2.50):**
- **`pytest.ini`** + **`tests/conftest.py`** — pytest-xdist + JUnit XML support.
- **`tests/test_spans.py`** (14 tests), **`tests/test_roi.py`** (13), **`tests/test_budget.py`** (9), **`tests/test_deploy_states.py`** (12), **`tests/test_watchers.py`** (5) — 53 pure-logic tests pinning every Mission Control contract.

**Phase 2.8 — SSE push channel (v2.51):**
- **`vps-setup/agent-template/nginx/dashboard.conf.tmpl`** — new `location = /api/chat/events` block with `proxy_buffering off`, `proxy_read_timeout 3600s`, `chunked_transfer_encoding off`. Must come before the generic `/api/chat/(.*)` regex.

**Phase 3 — BaseWatcher + deploy state machine (v2.52→v2.53):**
- **`vps-setup/agent-template/scripts/_watcher_base.py`** — Signal dataclass + BaseWatcher class. Each watcher is now 30 lines instead of 100. Dedup, throttle, Telegram post, audit emission all centralized.
- **`vps-setup/agent-template/scripts/disk-space-watcher.py`** — first migrated watcher (mirrors the .sh, replaces it).
- **`vps-setup/agent-template/scripts/_deploy_states.py`** — canonical state machine for the /deploy lifecycle (started → preflight_passed → smoke_passed → ready_to_ship → shipped, plus failed/cancelled). Validates phase transitions against a frozen graph.

**Phase 4 — Full observability stack (v2.54→v2.60):**
- **`vps-setup/agent-template/scripts/_spans.py`** — OTel GenAI-conformant SQLite span store (`gen_ai.usage.input_tokens`, `anthropic.cache_read_input_tokens`, etc.). Indexes by tool/agent/skill/parent. Cost computed downstream from tokens (no $ in raw spans).
- **`vps-setup/agent-template/scripts/session-parser.py`** — ingests `~/.claude/projects/*.jsonl` into spans.db every 2 min. Idempotent via tool_use_id PKs. 30-day hot window with auto-prune. POSTs `spans-added` audit events for SSE broadcast.
- **`vps-setup/agent-template/scripts/_roi.py`** — per-task-type ROI math with `realization_rate` (Superkind methodology). None of the 5 OSS observability projects surveyed ship per-skill ROI — this is industry-first.
- **`vps-setup/agent-template/scripts/_budget.py`** — hard cost-ceiling circuit breakers. `block`/`unblock`/`auto_expire`. Extend-only semantics. Fail-open on corrupt JSON.
- **`vps-setup/agent-template/dashboard/index.html`** — fully overhauled with 5 new tabs (audit, rules, deploys, activity, roi) + Tool Budget widget on Overview + Cache attribution KPI + Latency widget + session-tree modal + circuit-breaker banner + live agent indicator in topbar. Retemplatized to use `{{TENANT_*}}` placeholders everywhere.
- **`vps-setup/agent-template/scripts/dashboard-sync.sh.tmpl`** — 6 new `/api/*.json` endpoints (anomalies, deploys, spans, roi, budget, rules implied).
- **`vps-setup/agent-template/systemd/session-parser.{service,timer}.tmpl`** — every 2 min.

### Rendering verified
- `bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/EXAMPLE_TENANT.yml` produces 165 clean files (was 142 in v0.6.1, +23 new template files).
- `pytest tests/` runs 53/53 green with no VPS dependencies — safe for CI.

### Methodology / industry sources
- OpenTelemetry GenAI Semantic Conventions (gen_ai.* attributes, anthropic.cache_* extensions)
- agent-telemetry-spec/atsc (21-span-kind taxonomy)
- tranhoangtu-it/agentlens (SQLite default storage)
- MLaminekane/hawkeye (cost-ceilings-as-guardrails pattern)
- AgentOps-AI/tokencost (token-to-USD library shape)
- Superkind, OptimNow/ai-roi-calculator, METR HCAST (realization_rate methodology)

---

## [v0.6.1] — 2026-05-19

### Changed — Public-readiness scrub (the leaks-fixed release)

A pre-public-flip audit caught significant single-tenant content that had leaked back into the template across v0.5 and v0.6. v0.6.1 sweeps everything clean and adds public-repo polish.

**Hard blockers fixed:**
- **`vps-setup/agent-template/scripts/_memory_import_canon.py`** — was 179 lines of the upstream author's personal facts (family member names, kids' birth years, business entity structure, residence, career details). Now a clean skeleton template with commented-out shape examples + a `{{TENANT_*}}` placeholder pattern.
- **`vps-setup/agent-template/swarms/*.py`** (4 swarm files) — hardcoded "Daniel Gonell" in agent prompts + real product pricing + "Future Fluent" newsletter name. Now parameterized via module-level `TENANT_NAME` / `TENANT_FIRST_NAME` constants rendered from `{{TENANT_PERSON_FULL_NAME}}` / `{{TENANT_PERSON_FIRST_NAME}}`. Pricing references replaced with "see tenant's services doc."
- **`vps-setup/agent-template/dashboard/index.html`** — TENANT JS constant was hardcoded with name/email/title. Now uses `{{TENANT_ID}}` / `{{TENANT_PERSON_FIRST_NAME}}` / `{{TENANT_CONTACT_EMAIL}}` / `{{TENANT_PERSON_FULL_NAME}}`. Four sentinel-style "if (TENANT.name === 'Daniel')" fallback checks simplified to plain truthiness checks.
- **`vps-setup/agent-template/scripts/{memory-extract,update-active-context,context-refresh,memory-export}`** — LLM prompt strings + active.md headers hardcoded the upstream author's name. All now use `{{TENANT_PERSON_FULL_NAME}}` / `{{TENANT_PERSON_FIRST_NAME}}` placeholders.
- **`vps-setup/agent-template/scripts/discord-memory-digest.sh`** — comment said "Run every Friday at 17:00 (Santo Domingo time)" leaking residence. Now "(tenant timezone)".
- **`vps-setup/agent-template/obsidian-vault/README.md`** — example memory file used a real third-party client's name + their company. Replaced with `<Contact Name>` / `<Company Name>` template scaffolds.
- **`vps-setup/agent-template/scripts/skill-runner.sh.tmpl`** — voice rules referenced specific entity-separation entity names by string ("no NMG / CreateMomento"). Now references the configured `entity_separation_terms` list generically.
- **`vps-setup/agent-template/scripts/entity-linker.sh`** STOP list — was hardcoded with the upstream author's first/last name. Now uses `{{TENANT_PERSON_FIRST_NAME}}` placeholder + comments explaining the customization point.

**Soft issues fixed:**
- Voice scripts (`voice-reply.sh`, `CLAUDE.md.tmpl`) — replaced "Dominican Spanish" location-revealing defaults with generic "regional Spanish" + a Microsoft voice-list link so each tenant picks their own `DEFAULT_ES`.
- `CONTRIBUTING.md` example `/opt/danielgonell/...` → `/opt/<your_user>/...`.
- `agent-stack/config/client.example.env` example path → generic placeholder.
- `docs/upstream-dependencies.md` "Dominican Spanish voice" reference → generic.
- `agent-stack/docs/per-server/{chroma,memory,playwright,filesystem}.md` — reference docs were written from the original author's perspective ("Daniel's AI Knowledge Library", "Daniel's Mac"). Now generic operator phrasing.
- `vps-setup/PORTING.md` + `vps-setup/runbooks/{discord-setup,operating-principles}.md` — same generic phrasing pass.
- 13 script files in `vps-setup/agent-template/scripts/` had bare "Daniel" in code comments and embedded LLM prompts. All replaced with `{{TENANT_PERSON_FIRST_NAME}}` so the rendered output uses the tenant's name.
- `CLAUDE.md.tmpl` — 7 deploy-section references to "Daniel" → `{{TENANT_PERSON_FIRST_NAME}}`.

**Repo metadata polish:**
- **`LICENSE`** — removed the trailing `---` separator + third-party-deps note that confused GitHub's license auto-detector. LICENSE is now pure MIT; the third-party note moved to a new `NOTICE` file. GitHub should now correctly auto-detect MIT.
- **`NOTICE`** (new) — third-party deps attribution + a pointer to `docs/upstream-dependencies.md`.
- **`SECURITY.md`** (new) — vulnerability reporting policy. Preferred channel: GitHub Security Advisories. Alternative: `info@newmindsgroup.com`. Includes a post-deploy hardening checklist for operators.
- **`CHANGELOG.md`** v0.2.1 entry corrected — the historical claim "no more lingering 'Daniel'/'Santo Domingo' leaks" was misleading; updated to point readers at v0.6.1 for the actual public-readiness pass.

### Result

- **0 hard blockers** remaining in the template or rendered EXAMPLE_TENANT output
- The only remaining "Daniel" / "New Minds Group" references are: (1) the `CHANGELOG.md` historical attribution of the project's origin, (2) the `LICENSE` + `NOTICE` copyright holder. Both are intentional and correct for a public repo.
- 142 files render cleanly; only the pre-existing `{{TENANT_TLD}}` warning from v0.3 remains.

After v0.6.1: safe to flip the repo to public.

---

## [v0.6.0] — 2026-05-19

### Added — Multi-tier sub-agent delegation framework

A coherent three-tier strategy for delegating work to sub-agents, replacing the v0.5 "sub-agent registry" section that only documented Tier 1.

- **Tier 1 — Agent tool sub-agents** (in-process, parallelizable). 5 tenant-scoped (comms / pipeline / content / research / drift-scanner) plus 16 user-scoped from `agency-agents` cherry-pick. Sub-agents run in their own context window, can fan out in parallel, cannot recursively spawn (infinite-nesting protection).
- **Tier 2 — Domain swarms** (Python pipelines via `swarm-router.sh`). 4 built-in: `bizdev` (prospect → research + outreach + proposal), `content` (idea → drafts), `delivery` (client deliverables), `onboarding` (kickoff + intake). All use `claude --print` under the hood. No external dependency.
- **Tier 3 — OpenSwarm** (8-specialist heavy-lift framework, optional). For slides / video / image-gen / data-analysis / docs. Enabled via `features.multi_agent_swarms: true` + `installers/openswarm/install-openswarm.sh`.

### Added — OpenSwarm integration

- **`installers/openswarm/install-openswarm.sh`** (new) — clones [VRSEN/OpenSwarm](https://github.com/VRSEN/OpenSwarm) to `{{TENANT_AGENT_HOME}}/openswarm-repo`, runs `npm install -g @vrsen/openswarm`, verifies CLI callability, writes `OPENSWARM_DIR=` to `.env`. Idempotent — safe to re-run.
- **`vps-setup/agent-template/swarms/`** — 6 Python files: `swarm_base.py` (shared `run_agent()` helper using `claude --print`), `bizdev_swarm.py`, `content_swarm.py`, `client_delivery_swarm.py`, `onboarding_swarm.py`, `openswarm_runner.py` (headless dispatcher into the VRSEN repo).
- **`vps-setup/agent-template/scripts/swarm-router.sh`** — dispatcher. `swarm-router.sh content|bizdev|delivery|onboarding|openswarm ...` routes to the right tier.
- Models hard-pinned: `claude-sonnet-4-6` for swarm-main, `claude-haiku-4-5-20251001` for cheap sub-steps.

### Added — Background sub-agents (Claude Code 2026+ flags)

CLAUDE.md.tmpl documents the new `claude agents` invocation:

```bash
claude agents --add-dir {{TENANT_AGENT_HOME}} --settings inherit --model sonnet \
              --effort high --permission-mode bypassPermissions \
              --task "Deep research on X. Save findings to drafts/research-X.md."
```

Flags: `--add-dir`, `--settings`, `--mcp-config`, `--plugin-dir`, `--permission-mode`, `--model`, `--effort`. Use for long-running independent work (10+ min research, multi-file audits) so the parent session stays responsive.

### Changed — Orchestrator v0.4 → v0.6 (the gap close)

The orchestrator files (NEW-CLIENT-CLAUDE.md, DEPLOY-NEW-CLIENT.md, preflight-new-client.sh, client-credentials.template.md) shipped at v0.4 and weren't updated when v0.5 added memory v2 + Discord + Obsidian + context system. v0.6 closes that gap.

- **`NEW-CLIENT-CLAUDE.md`** — new Phase 0 feature-decision table (10 toggles with defaults), new Phase 4b (memory v2 init), Phase 4c (Obsidian first export), Phase 4d (Discord), Phase 7b (OpenSwarm install). Updated Phase 7 to enable memory-extract + memory-consolidate timers + describe the crontab install.
- **`vps-setup/DEPLOY-NEW-CLIENT.md`** — new Phase 5.6 (memory v2 init), 5.7 (Obsidian export), 5.8 (crontab install), 5.9 (OpenSwarm). Updated dependency list to `python3-venv` + `sqlite3`. Rollback strategy table extended with per-phase recovery steps.
- **`vps-setup/scripts/preflight-new-client.sh`** — added Section 9 (Discord bot token + guild reachability + owner user_id numeric check) gated on `discord_enabled: true`. Added Section 10 (Node 20+ + Python 3.10+ presence on VPS) gated on `multi_agent_swarms: true`.
- **`examples/client-credentials.template.md`** — new YAML blocks for `discord_bot_token` / `discord_guild_id` / `discord_owner_user_id`, and `multi_agent_swarms` toggle. Pre-deploy checklist extended.

### Why this matters

Before v0.6: the deployment orchestrator was stuck at v0.4. v0.5's memory + Discord + Obsidian + context-system features SHIPPED in the template but the runbook didn't know they existed, so a fresh deploy left them inert.

After v0.6: every new client deploy stands up the same memory + Discord + Obsidian + context + (optionally) swarm capabilities that Daniel-stack uses today. The pre-flight script validates Discord + OpenSwarm credentials BEFORE the deploy starts, not 20 min in.

Plus: a coherent three-tier delegation framework. The agent now knows when to use the Agent tool (parallel investigation), when to dispatch to a domain swarm (known shape), and when to call OpenSwarm (heavy media generation). The Tier decision matrix is in the CLAUDE.md.tmpl.

### Render count

142 files (was 135 in v0.5 = +7 from `swarms/` + `swarm-router.sh` + `install-openswarm.sh`).

---

## [v0.5.0] — 2026-05-19

### Added — Memory layer v2 (SQLite + FTS + vector embeddings + Obsidian mirror)

The biggest substantive upgrade since v0.1. Memory is no longer "a folder of markdown files." It's a SQLite vault with full-text search, vector embeddings via a sentence-transformer daemon, supersession chains, time-aware validity, plus a markdown mirror Obsidian can render and Syncthing can sync to your Mac.

**29 scripts ported from the production single-tenant deployment** (all sanitized — zero Daniel-specific paths). The major new pieces:

- **`memory-vault.sh` v2** — 9 subcommands (add, supersede, invalidate, history, recall, summarize, forget, rebuild, list). 8 memory types (fact / decision / relationship / preference / pattern / commitment / goal / context). Confidence scores, expiry dates, access counts, supersession chains.
- **`_memory_helpers.py` v2** — 614 lines (was 165 in v0.4). SQLite + FTS5 + vector search wiring.
- **`embedding-service.py`** — sentence-transformer daemon (`all-MiniLM-L6-v2`) serving over Unix socket. Keeps the model hot for sub-second semantic recall.
- **`memory-export.py`** — bridges SQLite → `obsidian-vault/memories/<type>/m-XXXX.md` every 5 minutes via cron. Each memory becomes a markdown file with YAML frontmatter + wikilinks + history log.
- **`memory-extract.sh`** + `memory-consolidate.sh` + systemd timers — extract from claude session jsonl files hourly, consolidate nightly.
- **`_memory_import_canon.py`** — one-shot import of brand-repo canonical docs as canonical-type memories.
- **`entity-linker.sh`** (nightly cron) — promotes names appearing 3+ times across memories to canonical `relationship` records.

### Added — Obsidian vault mirror

- **`vps-setup/agent-template/obsidian-vault/`** — directory skeleton (brand / daily / inbox / memories/<8 types>) shipped with `.gitkeep` files so the structure exists from day one.
- **`obsidian-vault/README.md`** — documents the pipeline + each memory file's YAML frontmatter format + wikilink conventions.
- **Syncthing-ready** — vault is structured to be paired between VPS and user's Mac via Syncthing. Optional, documented in a future runbook. When enabled, the user browses memories in the Obsidian app on their Mac and sees the graph view + backlinks automatically.

### Added — Discord command center (optional second surface)

- **`vps-setup/RUNBOOKS/discord-setup.md`** — 10-minute setup guide. Create the server + bot, enable Developer Mode, create 16 channels organized into Ops / Memory / Intel categories.
- **`scripts/discord-memory.sh`** — post/log/search/notify/client-thread (multi-purpose). Rich embeds, color-coded by memory type.
- **`scripts/discord-commands.sh`** — polls `#commands` every 60s, routes user prompts to the agent CLI, posts results back. Bidirectional surface (you type, agent reads).
- **`scripts/discord-corpus-sync.sh`** — reads human-typed messages in `#memory-*` channels and imports them to the SQLite vault every 10 min. Discord becomes a memory INPUT, not just output.
- **`scripts/discord-task-thread.sh`** — per-task Discord threads in `#task-events` with state-transition log.
- **`scripts/discord-memory-digest.sh`** — weekly memory digest posted Fridays 17:00 tenant-TZ.
- **`discord-webhook-server.js`** — lightweight Node HTTP server on :8090. Receives GHL/Gmail webhooks, routes to the relevant Discord channel via `discord-memory.sh notify`.
- **`systemd/discord-webhook-server.service.tmpl`** — auto-starts the webhook server on boot.
- **`channels-discord/.env.discord.template`** — every env var the discord-* scripts need.
- Channel taxonomy: `#commands`, `#agent-log`, `#task-events`, `#daily-brief`, `#memory-{facts,decisions,relationships,patterns,commitments,preferences,goals,context}`, `#intel`, `#ghl-activity`, `#gmail-alerts`.

### Added — Context system (wake-up with state)

- **`context-inject.sh`** — runs on session start. Outputs JSON with `additionalContext` containing recent telegram-history + active.md + today's proposals + current goals. Claude reads this BEFORE the first message of a session, so it wakes up oriented.
- **`context-refresh.sh`** — rewrites `context/active.md` from task ledger + memory vault. Called by `task-update.sh` on every state transition.
- **`update-active-context.sh`** — called from PostToolUse hooks to keep active.md current.
- **`session-summary.sh`** — Stop hook. Writes a rich snapshot at session end so the next session has the latest narrative.
- **`tg-history-log.sh`** — appends every Telegram in/out to `telegram-history.jsonl`. Used by context-inject.
- **`startup-ping.sh`** — confirms the agent came back up after any restart (Telegram + Discord notification).

### Added — Commitment tracking (distinct from tasks)

A commitment is "I promised X to person Y by date Z." Tracked as a `commitment`-type memory (so it lives in the vault, not the task ledger), with its own deadline watcher.

- **`commitment-log.sh`** — `commitment-log.sh --to "Name" --text "..." --deadline DATE [--task TASK_ID]`
- **`commitment-deadline-watcher.sh`** — hourly cron. Pings at 24h / 4h / now before the deadline. Architecture mirrors `task-deadline-watcher.sh` but reads from memory vault, not task ledger.

### Added — Voice DNA feedback loop

- **`signal-edit.sh`** — when the user edits a draft you produced, log the diff as a `pattern` memory immediately. *"Daniel cut 'thrilled to' opener, replaced with the direct ask"* → future drafts apply the lesson preemptively.
- **`save-recommendation.sh`** — capture strategic recommendations as a special memory type that future briefs can reference.

### Added — Search

- **`search.sh`** — unified `search.sh "query"` across memory vault + tasks + drafts. Replaces "where did I see that thing about X" with one command.

### Added — tenant.yml feature toggles (12 new flags)

`features.memory_vault_v2`, `memory_auto_extract`, `memory_consolidate`, `obsidian_vault_mirror`, `entity_linker`, `commitment_tracking`, `signal_edit_tracking`, `save_recommendation`, `context_system`, `discord_enabled`, `syncthing_enabled`, `graphiti_temporal_graph`, `multi_agent_swarms`.

Plus new tenant.yml DISCORD block with `discord_bot_token_env`, `discord_guild_id`, `discord_owner_user_id`, and `discord_channels.*` for all 15 channel ID slots.

### Added — Crontab template

- **`crontab/tenant.crontab.tmpl`** — single template covering all high-frequency jobs (Discord polling, memory export, entity linker, commitment watcher, startup ping, embedding daemon @reboot, optional Syncthing). Cron is used for >1/hour cadence; systemd timers for the rest.

### Changed

- **`CLAUDE.md.tmpl`** — Memory layer section EXPANDED with v2 architecture diagram, all 9 subcommand uses, time-aware fact semantics, context system, Discord channel handling.
- **`EXAMPLE_TENANT.yml`** — new DISCORD block + 12 feature toggles.
- Render count: 135 files (was 88 in v0.4 = 47 new files).

### Why this matters

Before v0.5: Ella shipped a basic memory layer + GraphRAG via Graphify, but no semantic recall, no Obsidian mirror, no Discord, no commitment tracking distinct from tasks, no context-system for "wake up with state." Daniel-stack had ALL of these built autonomously in production over 2 months.

After v0.5: Every client deployment starts with the same memory + Discord + Obsidian + context capabilities that Daniel-stack uses today. The agent can recall semantically ("show me memories similar to 'how Acme felt about pricing'"), supersede facts when they change, mirror to Obsidian for visual browsing, and (optionally) run a Discord command center alongside Telegram.

Anyone deploying Ella for a new client gets the same brain Daniel uses for his own business.

---

## [v0.4.0] — 2026-05-19

### Added — Fresh-client deployment orchestration

Closes the "how do I clone this for a new client" question with a concrete, local-Claude-orchestrated flow. Three new files at the top level + new template + new preflight script.

- **`NEW-CLIENT-CLAUDE.md`** (new top-level) — the orchestrator instructions the LOCAL Claude reads when you're deploying a fresh client agent. 10 phases. Hard gates at pre-flight and smoke-test. Explicit "what you DO" and "what you DON'T" sections so Claude doesn't try to register domains or move money.
- **`vps-setup/DEPLOY-NEW-CLIENT.md`** — master runbook. Workspace layout, dependency-ordered phase list (1 local prep → 12 archive credentials), rollback strategy per phase, branching for clients without GHL.
- **`examples/client-credentials.template.md`** — comprehensive credentials template. Every YAML slot a new client deploy needs (VPS, GitHub PAT, Cloudflare token, Telegram bot, CRM, TLS cert, OAuth, Anthropic). Inline comments explain where each value comes from. Pre-deploy checklist at the bottom.
- **`vps-setup/scripts/preflight-new-client.sh`** — validates EVERY credential against its live endpoint before any state mutates. 8 sections (VPS SSH, GitHub PAT, Cloudflare token + zone match, Telegram bot + user_id numeric, CRM, TLS cert presence, Anthropic account, DNS pre-resolution). Exit code = "is it safe to start deploying?"

### Why this matters

Before v0.4: porting Ella to a new client meant manually rendering the template, manually SCP-ing to a VPS, manually wiring DNS, manually setting up the Telegram bot, manually testing each step. ~3-4 hours per client and easy to drop a step.

After v0.4: open Claude Code in a workspace folder, give it credentials + context, say "deploy this." Local Claude reads `NEW-CLIENT-CLAUDE.md`, runs the pre-flight gate, SSH's to the VPS, walks through every phase, runs the smoke test, pushes the client's repo to GitHub. ~30 minutes per client + most of that is `pnpm install` time on the VPS.

The pre-flight is the key innovation — it tests EVERY credential against its real endpoint BEFORE mutating anything. No more "20 minutes into a deploy, discovers Cloudflare token has wrong scope."

### Use this for

- Standing up a fresh client agent on a fresh VPS in one sitting
- Pressure-testing a credentials file before committing to a deploy
- Onboarding a new team member to the deployment process (the runbook is the training material)

---

## [v0.3.0] — 2026-05-15

### Added — Proactive notification pipeline (7 new watchers)
- `task-deadline-watcher.{sh,service,timer}` — hourly 08–22 tenant TZ. Pings on tasks crossing 24h / 4h / due / overdue windows. Local file watcher, no LLM.
- `goal-deadline-watcher.{sh,service,timer}` — daily 09:30. Pings on 7d / 1d / overdue + "behind pace" (when progress trails time-elapsed by >25pp). Local file watcher, no LLM.
- `stalled-deal-watcher.{sh,service,timer}` — daily 10:00. Pings on GHL opportunities ≥$2K idle ≥7d. Direct GHL REST API call (no LLM, no MCP).
- `disk-space-watcher.{sh,service,timer}` — every 4h around clock. 75% / 85% / 95% escalating thresholds with separate dedup windows. Local `df`, no LLM.
- `hot-lead-inbox-watcher.{sh,service,timer}` — 4×/day. Gmail threads in lookback window cross-referenced against GHL contacts. Split design: LLM does ONE Gmail call → JSON, bash does GHL REST + format + send (~$0.01 per run).
- `calendar-conflict-watcher.{sh,service,timer}` — 3×/day (07/12/17). Overlapping events on primary calendar detected via O(n²) interval-overlap in bash. Split design: LLM lists events, bash detects overlaps (~$0.01 per run).
- `graphify-rebuild.{sh,service,timer}` — weekly Sunday 03:00. AST-only refresh of the project-repo Graphify graph. No LLM, $0 cost. Pings Telegram only when delta >10 nodes/links.

### Added — Agent self-service ops
- 5 wrapper scripts in `scripts/ops/`: `ops-claude-update.sh`, `ops-website-deploy.sh`, `ops-service-restart.sh`, `ops-nginx-reload.sh`, `ops-systemd-install-unit.sh`.
- `sudoers/agent-ops.sudoers` — `{tenant_linux_user} ALL=(root) NOPASSWD: {agent_home}/scripts/ops/`. Directory-wide grant; adding a capability = adding a wrapper.
- Every wrapper validates inputs, logs to `/var/log/{tenant}-agent-ops.log`, and pings Telegram on success/failure.
- The agent can now self-update Claude Code, deploy the Next.js website, restart services, reload nginx, install systemd units — **without the user's password**.

### Added — Telegram polish (channels-plugin Pass 4 + Pass 5)
- **Pass 4 (v2.27.3)** — surfaces `ctx.message.forward_origin` as `forward_origin_type` + `_label` + `_date` meta fields so the agent can detect forwards and offer "save to memory?" with consent buttons.
- **Pass 5 (v2.27.4)** — `email:(reply|archive|snooze):<gmail-thread-id-hex>` callback routing for `/inbox` triage cards. Reply delegates to comms-agent (two-tap pattern with existing draft: flow). Archive calls Gmail MCP. Snooze creates an awaiting_external task with 24h deadline.

### Added — Smoke test infrastructure
- `scripts/smoke-test.sh` — 60+ checks across 12 sections (core services, all timers, scripts present, plugin patches verified, bot identity, config files + state, dedup logs, watchdog state, data sources, voice stack, proposal files, Graphify knowledge graph).
- Re-runnable any time. Exits 0 only when all checks pass. Useful as a cron health check or post-change validation.

### Added — Voice mode preference
- `scripts/pref.sh` — atomic JSON-backed preferences store at `{agent_home}/preferences.json`.
- `/voice` slash command cycles modes: `off` → `reply` → `always` → `off`. `/voice <mode>` sets explicitly. `/voice status` reads current.
- Off = text-only even to voice notes. Reply = TTS only when input was voice (default, matches v0.2 behavior). Always = TTS on every reply, including text inputs.

### Added — Telegram bot identity polish
- `scripts/setup-bot-identity.sh` — idempotent `setMyCommands` + `setMyDescription` + `setMyShortDescription` + `setChatMenuButton`. Re-run any time to refresh.
- `/dashboard` slash command opens Mission Control inline as a Telegram Mini App (no browser switch on mobile).
- React-as-progress: plugin auto-reacts 👀 on every inbound; agent upgrades to ✍️ when work exceeds ~10s, then 👌 when done.

### Added — Knowledge graph integration
- `scripts/graphify-rebuild.sh` weekly safety-net rebuild of the project-repo Graphify graph (AST-only via `graphify update`, $0 cost).
- Smoke test Section 12: verifies CLI present, skill installed, project graph populated (nodes>0 AND links>0), age <10 days.

### Added — Tenant.yml fields
- `weather_lat`, `weather_lon`, `weather_label` — for the morning-brief weather block (Open-Meteo, free, no API key).
- `user_home` — defaults to `/opt/{linux_user}` but explicit field allows custom paths.
- `website_source_path` — defaults to `/opt/{linux_user}/source`. Used by `ops-website-deploy.sh`.
- `features.{task,goal,stalled,disk,hot-lead,calendar,graphify}` — toggle each new watcher independently.
- `features.agent_self_service_ops` — gates the sudoers installation.
- `features.voice_round_trip` — gates the whisper.cpp + edge-tts pipeline.

### Changed
- `patch-channels-plugin.sh` now applies 5 passes (was 3 in v0.2). Verified TS-compiles after all passes.
- `tg-send.sh` gained `--webapp-buttons` flag for inline Mini App buttons and `send-voice` subcommand for OGG/Opus voice notes (waveform UI on mobile, distinct from sendAudio's music-file display).
- `voice-transcribe.sh` default changed from `--lang en` to `--lang auto` (multilingual). Output now prefixed `[LANG=xx]` so callers can route TTS reply to the matching voice.

### Fixed
- `dontAsk` permission mode works for Gmail in `claude --print` but NOT for Google Calendar (verified live 2026-05-05). Workaround: watchers using non-Gmail hosted MCPs use `--permission-mode bypassPermissions`. Documented in CLAUDE.md.tmpl.
- Watchdog circuit-breaker collision when batching restarts: documented "pre-prune current-hour history before restart" pattern in `reference_claude_code_update_procedure` style docs.

---

## [v0.2.1] — 2026-05-05

### Added
- `scripts/dashboard-sync.sh.tmpl` + `scripts/skill-runner.sh.tmpl` — templated (was hardcoded in v0.1).
- `vps_host` field in tenant.yml for `render-and-deploy.sh`.

### Changed
- Pre-v0.3 privacy + tenant scrub on docs (note: a more thorough public-readiness scrub landed in v0.6.1 — see that entry).

---

## [v0.2.0] — 2026-05-04

### Added
- `vps-setup/scripts/render-and-deploy.sh` — one-shot template render + scp + bootstrap for new tenants.

---

## [v0.1.0] — 2026-05-04

Initial public release. Sanitized fork from a production single-tenant agent stack.

### Initial feature set
- Multi-tenant agent template (`vps-setup/agent-template/` + `tenant.yml` + `render-tenant.sh`).
- Morning brief v1 (rich HTML Telegram message with weather + verse + agent status + LLM-pulled snapshot + drafts/goals/deadlines + Quick Action buttons).
- Proposed Moves system (3 strategic proposals per morning, Run/Skip callback buttons).
- Voice round-trip (whisper.cpp transcription + edge-tts reply, bilingual auto-detect).
- Mission Control dashboard (FastAPI + single-file SPA, behind basic-auth, auto-redeploy on git push).
- 21-sub-agent roster (5 hand-built + 16 cherry-picked from agency-agents).
- Task ledger + goals tracker + memory vault + knowledge graph (Graphify).
- Channels-plugin patches v2.22.2 (deploy:) + v2.24.0 (draft:) + v2.27.2 (prop:).
- Brand voice + DESIGN.md visual SSOT examples.
- GHL MCP integration + Firecrawl MCP + Playwright + Chroma + memory + filesystem + fetch MCPs.
- Sub-agent skills directory pattern.
- Tool-leverage heuristics + combo-pattern table in CLAUDE.md template.

[v0.8.1]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.8.1
[v0.8.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.8.0
[v0.7.1]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.7.1
[v0.7.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.7.0
[v0.6.1]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.6.1
[v0.6.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.6.0
[v0.5.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.5.0
[v0.4.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.4.0
[v0.3.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.3.0
[v0.2.1]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.2.1
[v0.2.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.2.0
[v0.1.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.1.0
