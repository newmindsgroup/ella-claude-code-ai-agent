# Changelog

All notable changes to this repo. Format roughly follows [Keep a Changelog](https://keepachangelog.com/). This is a multi-tenant template, so versions reflect what's available to clone for a new tenant — not what's running at any one customer's deployment.

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
