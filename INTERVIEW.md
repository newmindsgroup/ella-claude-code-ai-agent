# INTERVIEW.md — Conversational deployment dialogue script

> **For the LOCAL agent (Claude Code, Cursor, Codex, etc.) running on the operator's Mac.**
>
> This is a structured dialogue script the local agent reads BEFORE filling in `client-credentials.md` and `tenants/<name>.yml`. The goal is to walk the human through a sequence of questions — one at a time, conversational tone — instead of dumping a 200-line YAML template on them.
>
> **The local agent's job:** read this file, ask the questions in order, branch where indicated, validate the answers, and write the result into the right place (`client-credentials.md` and/or `tenants/<name>.yml`). After every section, summarize what's captured and offer to revise.
>
> **Tone:** like a thoughtful onboarding consultant, not a wizard installer. Pause after each section. Confirm before moving on. If an answer is vague, ask one clarifying follow-up — don't accept hand-waves on required slots.

---

## How this works

1. The human runs `claude` (or Cursor/Codex) inside a fresh workspace folder.
2. The local agent reads this `INTERVIEW.md` and starts at Section 1.
3. After each section, write the captured values into `client-credentials.md` (for secrets) or `tenants/<name>.yml` (for tenant config). Mark each with `# captured-by-interview: <ISO timestamp>`.
4. After Section 9, run `bash vps-setup/scripts/preflight-new-client.sh client-credentials.md`. If it fails, loop back to the relevant section.
5. After preflight is green, hand off to `DEPLOY-NEW-CLIENT.md` for the actual deploy.

**Required vs Optional:** every question is tagged `[REQUIRED]` or `[OPTIONAL]`. Required questions block progress — if the human doesn't know, the agent must help them find the answer (search the web, check a doc, call an API, etc.).

**Defaults:** square brackets show the default value. Pressing Enter accepts it.

---

## Section 1 — About the human

> *"Let's start with you. I'll use these to address you in the agent's responses, route alerts, and set the right timezone."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 1.1 | What's your full name? *(used in agent prompts + email signatures)* | REQUIRED | non-empty | `tenant.yml: person_full_name` |
| 1.2 | What should the agent call you? *(first name or nickname — defaults to first name)* | REQUIRED | non-empty | `tenant.yml: person_first_name` |
| 1.3 | What's your work email? *(reply-to address on drafts, alert destination)* | REQUIRED | valid email | `tenant.yml: contact_email` + `credentials: client_email` |
| 1.4 | What's your timezone? *(IANA tz, e.g. America/New_York)* | REQUIRED | valid IANA tz | `tenant.yml: timezone` + `credentials: client_timezone` |
| 1.5 | What city do you want to see in the morning brief weather block? | REQUIRED if morning_brief enabled | non-empty | `tenant.yml: weather_label` + `credentials: client_city` |
| 1.6 | What are the lat/lon for that city? *(I can look this up if you don't know — say "lookup")* | REQUIRED if morning_brief enabled | float, -90..90 / -180..180 | `tenant.yml: weather_lat/lon` |

**After section 1 — pause and confirm:**
> *"OK so I have you as [person_full_name], I'll call you [person_first_name], emails go to [contact_email], and the morning brief will show weather for [weather_label] ([weather_lat], [weather_lon]) in the [timezone] timezone. Look right?"*

---

## Section 2 — About the business / brand

> *"Now the brand the agent represents. The agent will write LinkedIn posts, reply to inbound, draft proposals, etc. — all in this brand's voice. So the more concrete you are here, the better the output."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 2.1 | What's the brand name? *(public-facing; can equal your name if it's a personal brand)* | REQUIRED | non-empty | `credentials: client_brand_name` |
| 2.2 | What's the legal entity name? *(for invoices/contracts)* | REQUIRED | non-empty | `credentials: client_legal_name` |
| 2.3 | One sentence — what does this person/business do? *(this becomes the agent's role-description prompt)* | REQUIRED | ≥10 chars, ≤200 chars | `tenant.yml: person_role_description` |
| 2.4 | What's your live website URL? | REQUIRED | https URL | `tenant.yml: website_url` |
| 2.5 | What's the public-facing location? *(e.g. "Atlanta, GA" — can differ from where you actually live for privacy)* | OPTIONAL | non-empty | `credentials: public_city` |
| 2.6 | Do you have a brand canon repo? *(a GitHub repo with voice playbook, positioning, response templates — say "no" and I'll scaffold one)* | REQUIRED | git URL or "no" | `tenant.yml: brand_repo_url` |

**Branching:**
- If 2.6 == "no", offer to: (a) scaffold a minimal `<name>-brand-canon` repo with stub files for voice, positioning, services, content; or (b) skip the brand canon and use generic prompts. Default is (a).
- If 2.6 is a URL, ask: *"Branch?"* (default `main`) and *"Where in that repo is the voice playbook?"* (default `15_Brand_Behavior_Playbook.md`). Land in `tenant.yml: brand_repo_branch` + `voice_playbook_path`.

---

## Section 3 — Voice + AI tells

> *"This shapes how the agent writes. If you don't have a formal voice playbook, I'll ask 4 quick questions to bootstrap one."*

**Branching:**
- If a voice playbook exists (section 2.6 had a real path), say: *"Got it, I'll defer to your playbook. I'll just confirm a couple of safety rails."* Skip to 3.5.
- If no voice playbook, run the bootstrap (3.1–3.4).

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 3.1 | If your writing had one defining trait, what would it be? *(e.g. "direct", "warm", "precise", "playful")* | REQUIRED if no playbook | non-empty | `voice-playbook.md` scaffold |
| 3.2 | Three phrases you DO use a lot? | REQUIRED if no playbook | ≥1 phrase | `voice-playbook.md` scaffold |
| 3.3 | Three phrases you NEVER want the agent to use? *(e.g. "thrilled to", "delve into", em-dash overuse)* | REQUIRED if no playbook | ≥1 phrase | `tenant.yml: voice_banned_phrases` |
| 3.4 | Emoji policy — none / sparing / liberal? | OPTIONAL [sparing] | enum | `tenant.yml: voice_emoji_policy` |
| 3.5 | Should the agent ever sign off with "Best," or similar? *(some brands feel canned)* | OPTIONAL [no] | yes/no | `voice-playbook.md` |
| 3.6 | Reading-level target — high-school / professional / academic? | OPTIONAL [professional] | enum | `voice-playbook.md` |

---

## Section 4 — The VPS

> *"Where will the agent live? You said you have Vultr/AWS/Vercel access — let me know which one."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 4.1 | Provider — vultr / aws / vercel / digitalocean / other? | REQUIRED | enum | `credentials: vps_provider` |
| 4.2 | Do you already have a VPS provisioned, or do you want me to provision one? | REQUIRED | "existing" / "provision" | (drives next branch) |
| 4.3 | If existing — what's the public IP? | REQUIRED (existing) | valid IPv4 | `credentials: vps_ip` |
| 4.4 | If existing — what user can I SSH in as? *(usually `root` on a fresh Ubuntu box)* | REQUIRED (existing) | non-empty | `credentials: vps_root_user` |
| 4.5 | Which SSH key should I use? *(path to private key — default ~/.ssh/id_ed25519)* | REQUIRED (existing) | file exists | `credentials: vps_ssh_key` |
| 4.6 | If provisioning — region preference? *(default: closest to client_city)* | REQUIRED (provision) | provider's region code | `credentials: vps_region` |
| 4.7 | If provisioning — plan? *(default for Vultr: $12/mo 2vCPU/4GB)* | REQUIRED (provision) | provider's plan code | `credentials: vps_plan` |

**Branching:**
- If `vps_provider == vultr` and `4.2 == provision`, the local agent uses the Vultr API (operator's `VULTR_API_KEY` env var or asked here) to spin up a box. Wait for "active" state, capture the IP, write to `credentials: vps_ip`.
- If `vps_provider == aws` and `4.2 == provision`, use the AWS API (operator's credentials in `~/.aws/credentials`) to launch an EC2 t3.medium with Ubuntu 24.04. Capture public IP.
- For `4.2 == existing`, immediately test `ssh -o ConnectTimeout=10 <user>@<ip> "echo ok"` and stop if it fails.

---

## Section 5 — Domain + TLS

> *"The dashboard, agent endpoint, and webhooks need a domain. Cloudflare is the smoothest path — they handle TLS automatically."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 5.1 | What domain will you use for the agent's dashboard? *(e.g. `dashboard.example.com`)* | REQUIRED | valid hostname | `tenant.yml: dashboard_hostname` |
| 5.2 | DNS provider — cloudflare / route53 / namecheap / other? | REQUIRED | enum | `credentials: dns_provider` |
| 5.3 | Cloudflare API token? *(needs `Zone:DNS:Edit` for the zone — I'll test it before using)* | REQUIRED if cloudflare | string | `credentials: cloudflare_api_token` |
| 5.4 | Cloudflare zone ID for the parent domain? | REQUIRED if cloudflare | string | `credentials: cloudflare_zone_id` |

**Branching:**
- If DNS provider != cloudflare, fall back to manual DNS instructions. Tell the operator: *"I'll skip auto-DNS. After the VPS is up, I'll print the A-record you need to add at your DNS provider, and you'll add it manually. Then we'll continue."*

---

## Section 6 — Integrations + tools

> *"Optional: which of these would you like the agent to talk to? You can skip any — features just won't fire."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 6.1 | GoHighLevel CRM — location ID + API key? *(unlocks pipeline-reporter, stalled-deal-watcher, hot-lead-inbox)* | OPTIONAL | string + string | `credentials: ghl_location_id` + `ghl_api_key` |
| 6.2 | Telegram bot — token + your chat ID? *(unlocks morning brief, voice replies, callbacks)* | OPTIONAL | string + integer | `credentials: telegram_bot_token` + `telegram_chat_id` |
| 6.3 | Gmail OAuth — credentials.json path? *(unlocks inbox-triage, hot-lead-inbox-watcher email leg)* | OPTIONAL | file exists | `credentials: gmail_oauth_path` |
| 6.4 | Google Calendar OAuth — same? *(unlocks calendar-conflict-watcher)* | OPTIONAL | file exists | `credentials: gcal_oauth_path` |
| 6.5 | Discord bot — token + guild ID? *(v0.5+ command center; ~16 channels)* | OPTIONAL | string + integer | `credentials: discord_bot_token` + `discord_guild_id` |
| 6.6 | RSS sources for competitive monitor? *(comma-separated URLs)* | OPTIONAL | list of URLs | `tenant.yml: rss_sources_path` (auto-write a sources file) |

**Branching for each:** if skipped, set the corresponding `enable_*` feature flag to `false` in `tenant.yml`.

---

## Section 7 — Cost preferences + ROI math

> *"This drives the cost-ceiling circuit breaker (v2.57.0) and the ROI dashboard (v2.56.0). Defaults work for most people, but if you want to dial it in, here are the levers."*

| # | Question | Tag | Validation | Lands in |
|---|---|---|---|---|
| 7.1 | Daily API spend cap? *(if today's spend hits this, the agent refuses to run any new skill until you investigate)* | OPTIONAL [$5] | float | `rules/budget-ceilings.yaml: value` |
| 7.2 | What hourly rate would you charge for STRATEGY work? *(used in ROI math — defensible default $200)* | OPTIONAL [$200] | float | `_roi.py: ROI_CONFIG.strategy.hourly_rate` |
| 7.3 | What hourly rate for CONTENT DRAFTING? | OPTIONAL [$75] | float | `_roi.py: ROI_CONFIG.draft.hourly_rate` |
| 7.4 | What hourly rate for ADMIN / TRIAGE? | OPTIONAL [$50] | float | `_roi.py: ROI_CONFIG.triage.hourly_rate` |
| 7.5 | Default realization rate for new task types? *(0.5 if AI output needs heavy review, 0.7 light review, 0.9 ships as-is)* | OPTIONAL [0.7] | 0.0–1.0 float | `_roi.py: ROI_CONFIG.default.realization_rate` |

---

## Section 8 — Feature toggles

> *"v0.7.0 added a lot of new Mission Control surfaces. They're all on by default because they don't cost anything to leave running — but you can disable any of them."*

| # | Question | Tag | Default | Lands in |
|---|---|---|---|---|
| 8.1 | Morning brief at <time>? *(rich HTML Telegram brief)* | OPTIONAL [09:00 local] | `tenant.yml: morning_brief_time` + `enable_morning_brief` |
| 8.2 | Evening rollup at <time>? *(yesterday-recap + today-plan)* | OPTIONAL [18:00 local] | `tenant.yml: evening_rollup_time` + `enable_evening_rollup` |
| 8.3 | Enable rules engine? *(v2.48 behavioral rules — drift escalation, cost ceilings)* | OPTIONAL [true] | `tenant.yml: enable_rules_engine` |
| 8.4 | Enable anomaly detection? *(v2.49 z-score on cost/latency)* | OPTIONAL [true] | `tenant.yml: enable_anomaly_detection` |
| 8.5 | Enable session-parser + spans store? *(v2.54 Activity tab + ROI math)* | OPTIONAL [true] | `tenant.yml: enable_session_parser` |
| 8.6 | Enable cost-ceiling circuit breakers? *(v2.57 hard guardrails)* | OPTIONAL [true] | `tenant.yml: enable_circuit_breakers` |
| 8.7 | Enable proactive watchers? *(disk, deadlines, stalled deals, etc.)* | OPTIONAL [true] | `tenant.yml: enable_watchers` |
| 8.8 | Enable multi-agent swarms? *(v0.6 OpenSwarm domain swarms)* | OPTIONAL [false] | `tenant.yml: multi_agent_swarms` |

---

## Section 9 — Confirm + write files

After all 8 sections answered, the local agent should:

1. **Summarize back to the human** — read out every value captured, grouped by section.
2. **Ask: "Anything to revise before I write the files?"** Loop on any revision.
3. **Write `client-credentials.md`** — fill the YAML blocks in `examples/client-credentials.template.md` with the captured values. Save OUTSIDE the agent repo (typically `~/code/<client>-workspace/client-credentials.md`).
4. **Write `<client>-agent/vps-setup/tenants/<tenant_id>.yml`** — fill from the captured values. Use `examples/EXAMPLE_TENANT.yml` shape.
5. **Run preflight:** `bash <client>-agent/vps-setup/scripts/preflight-new-client.sh client-credentials.md`. If it fails, loop back to the relevant section.
6. **Hand off to deploy:** read `<client>-agent/vps-setup/DEPLOY-NEW-CLIENT.md` and follow it phase by phase. The interview is over.

---

## Style notes for the local agent

- **Ask one question at a time.** Don't dump a 5-question block. Wait for an answer, validate it, then move to the next.
- **Reflect what you heard.** "OK, so [person_first_name] lives in [client_city], timezone [timezone]. Got it."
- **Don't ask for things you can derive.** If they said "I'm in Atlanta," look up the lat/lon yourself instead of asking.
- **Don't be a wizard.** If someone says "I don't have a CRM," don't push GHL on them — note it, set the flag, move on.
- **Be honest about side-effects.** "If you skip Telegram, the morning brief still gets written to a file on the VPS but won't reach your phone. Want to skip it?"
- **Save progress as you go.** Don't ask all 50 questions then crash before writing. Append to `client-credentials.md` after every section.
- **Validate before progressing.** If they paste a clearly-invalid Cloudflare token (wrong format), say so and ask for the right one. Don't write garbage to the file.
- **At the end, run preflight automatically.** Don't make the human invoke it.
