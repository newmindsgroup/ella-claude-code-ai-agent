# Changelog

All notable changes to this repo. Format roughly follows [Keep a Changelog](https://keepachangelog.com/). This is a multi-tenant template, so versions reflect what's available to clone for a new tenant — not what's running at any one customer's deployment.

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
- Pre-v0.3 privacy + tenant scrub on docs (no more lingering "Daniel"/"Santo Domingo" leaks in examples).

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

[v0.3.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.3.0
[v0.2.1]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.2.1
[v0.2.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.2.0
[v0.1.0]: https://github.com/newmindsgroup/ella-claude-code-ai-agent/releases/tag/v0.1.0
