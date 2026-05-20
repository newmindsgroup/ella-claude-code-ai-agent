# Mission Control — visual tour

Mission Control is Ella's self-hosted dashboard: one screen that shows everything the agent is doing, how long it's taking, what it's costing, and what it would have cost a human. It runs behind nginx HTTP basic-auth at `https://<your-subdomain>/` and also opens inline as a Telegram Mini App via `/dashboard`.

This page walks through each view. Screenshots are captured from a demo tenant seeded with synthetic data (no real client information).

> **Note on screenshots:** the image slots below are filled from a demo deployment with synthetic data. If you're cloning Ella, your own dashboard will look identical with your data. To capture your own, see [Capturing screenshots](#capturing-screenshots) at the bottom.

---

## How it's wired

```
Browser / Telegram Mini App
        │  HTTPS + basic-auth (nginx)
        ▼
┌─────────────────────────────────────────────┐
│ dashboard/index.html  (single-file SPA)      │
│   • reads ~15 /api/*.json snapshots          │
│   • subscribes to /api/chat/events (SSE)     │
└──────────────┬──────────────────────────────┘
               │
   ┌───────────┴────────────┐
   ▼                        ▼
dashboard-sync.sh      dashboard-chat/server.py
(regenerates the        (FastAPI write-action
 /api/*.json snapshots   backend on 127.0.0.1:8001:
 from task ledger,       chat, audit, snooze,
 memory, spans, roi,     skills/run, rules/run,
 budget, telemetry)      budget, SSE events)
```

The SPA has no build step (Tailwind via CDN). `dashboard-sync.sh` runs on a timer to refresh the read-only JSON; the FastAPI backend handles anything that writes.

---

## The views

### Overview
The landing view. Greeting + date, a live "agent active" indicator in the topbar, a KPI strip (open tasks, pending drafts, active goals, today's spend), the **Tool Budget** widget, a **cache-attribution** KPI (how much spend was served from prompt cache), a **latency** widget, and a **circuit-breaker banner** that appears when a cost ceiling is hit.

> 📸 _Screenshot slot: `docs/images/mc-overview.png`_

### Tasks
The full task ledger — every task with its state (in_progress / awaiting_review / blocked / done), deadline, and **per-task cost** computed from spans.

> 📸 _Screenshot slot: `docs/images/mc-tasks.png`_

### Goals
Outcome goals with target dates, progress bars, and behind-pace flags (when elapsed time outruns progress).

> 📸 _Screenshot slot: `docs/images/mc-goals.png`_

### Memory
The SQLite memory vault rendered as browsable cards across all eight types — fact, decision, relationship, preference, pattern, commitment, goal, context — with confidence and supersession info.

> 📸 _Screenshot slot: `docs/images/mc-memory.png`_

### Drafts
Pending drafts awaiting review (LinkedIn posts, emails, newsletter issues), each with a preview.

> 📸 _Screenshot slot: `docs/images/mc-drafts.png`_

### Inbound
High-priority inbound email/messages, classified and triaged.

> 📸 _Screenshot slot: `docs/images/mc-inbound.png`_

### Improvements
Output from the self-improvement review — concrete things the agent proposes to do better, drawn from its own audit log.

> 📸 _Screenshot slot: `docs/images/mc-improvements.png`_

### Insights
Strategic insights and saved recommendations the agent has surfaced over time.

> 📸 _Screenshot slot: `docs/images/mc-insights.png`_

### Skills
The skill registry with one-click **Run** buttons that dispatch a skill via the FastAPI backend.

> 📸 _Screenshot slot: `docs/images/mc-skills.png`_

### Audit
An append-only log of every write action the agent took — the accountability trail.

> 📸 _Screenshot slot: `docs/images/mc-audit.png`_

### Rules
The behavioral rules engine: active YAML rules, when each last fired, and a Run-now button. Rules can post to Telegram, write audit entries, or trip a circuit breaker.

> 📸 _Screenshot slot: `docs/images/mc-rules.png`_

### Deploys
The `/deploy` lifecycle state machine — started → preflight_passed → smoke_passed → ready_to_ship → shipped (plus failed / cancelled) — so a half-finished deploy is always visible.

> 📸 _Screenshot slot: `docs/images/mc-deploys.png`_

### Activity
A live, SSE-driven feed of agent actions as they happen.

> 📸 _Screenshot slot: `docs/images/mc-activity.png`_

### ROI
Per-task-type return on investment: agent cost vs. the human-equivalent cost of the same work, adjusted by a realization rate. The headline figure also shows in the sidebar.

> 📸 _Screenshot slot: `docs/images/mc-roi.png`_

### Drift
Brand-drift scan results — banned phrases, off-brand language, and entity-separation leaks caught in recent output.

> 📸 _Screenshot slot: `docs/images/mc-drift.png`_

### Competitive
Competitive-monitor diffs: pricing, positioning, and hiring changes detected on tracked competitor sites.

> 📸 _Screenshot slot: `docs/images/mc-competitive.png`_

### Schedule
A calendar view of today + upcoming events, with conflicts surfaced.

> 📸 _Screenshot slot: `docs/images/mc-schedule.png`_

### Telemetry
Token usage over time, daily spend history, model mix, and anomaly markers from the z-score detector.

> 📸 _Screenshot slot: `docs/images/mc-telemetry.png`_

### Chat
A full chat with the agent — streaming responses, voice in/out, and file/image attachments — synced with Telegram (see the README's "Telegram ↔ dashboard chat parity" section).

> 📸 _Screenshot slot: `docs/images/mc-chat.png`_

### Settings
Per-tenant configuration, surfaced read-only.

> 📸 _Screenshot slot: `docs/images/mc-settings.png`_

---

## Capturing screenshots

Mission Control shows live tenant data, so **never publish screenshots of a production instance** — they contain real tasks, deals, contacts, and financials. Two safe ways to produce the images above:

1. **Demo tenant (recommended for public docs).** Render `EXAMPLE_TENANT.yml`, serve the dashboard with synthetic `/api/*.json` fixtures, and screenshot each view. Nothing real is exposed.
2. **Redacted production capture.** Screenshot your live dashboard, then blur/replace names, dollar amounts, and contact details before committing.

Drop the resulting PNGs into `docs/images/` using the filenames in the slots above, then replace each `> 📸 _Screenshot slot: ..._` line with `![Alt text](images/mc-<view>.png)`.
