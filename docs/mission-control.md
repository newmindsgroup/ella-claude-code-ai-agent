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

![Mission Control — overview view](images/mc-overview.png)

### Tasks
The full task ledger — every task with its state (in_progress / awaiting_review / blocked / done), deadline, and **per-task cost** computed from spans.

![Mission Control — tasks view](images/mc-tasks.png)

### Goals
Outcome goals with target dates, progress bars, and behind-pace flags (when elapsed time outruns progress).

![Mission Control — goals view](images/mc-goals.png)

### Memory
The SQLite memory vault rendered as browsable cards across all eight types — fact, decision, relationship, preference, pattern, commitment, goal, context — with confidence and supersession info.

![Mission Control — memory view](images/mc-memory.png)

### Drafts
Pending drafts awaiting review (LinkedIn posts, emails, newsletter issues), each with a preview.

![Mission Control — drafts view](images/mc-drafts.png)

### Inbound
High-priority inbound email/messages, classified and triaged.

![Mission Control — inbound view](images/mc-inbound.png)

### Improvements
Output from the self-improvement review — concrete things the agent proposes to do better, drawn from its own audit log.

![Mission Control — improvements view](images/mc-improvements.png)

### Insights
Strategic insights and saved recommendations the agent has surfaced over time.

![Mission Control — insights view](images/mc-insights.png)

### Skills
The skill registry with one-click **Run** buttons that dispatch a skill via the FastAPI backend.

![Mission Control — skills view](images/mc-skills.png)

### Audit
An append-only log of every write action the agent took — the accountability trail.

![Mission Control — audit view](images/mc-audit.png)

### Rules
The behavioral rules engine: active YAML rules, when each last fired, and a Run-now button. Rules can post to Telegram, write audit entries, or trip a circuit breaker.

![Mission Control — rules view](images/mc-rules.png)

### Deploys
The `/deploy` lifecycle state machine — started → preflight_passed → smoke_passed → ready_to_ship → shipped (plus failed / cancelled) — so a half-finished deploy is always visible.

![Mission Control — deploys view](images/mc-deploys.png)

### Activity
A live, SSE-driven feed of agent actions as they happen.

![Mission Control — activity view](images/mc-activity.png)

### ROI
Per-task-type return on investment: agent cost vs. the human-equivalent cost of the same work, adjusted by a realization rate. The headline figure also shows in the sidebar.

![Mission Control — roi view](images/mc-roi.png)

### Drift
Brand-drift scan results — banned phrases, off-brand language, and entity-separation leaks caught in recent output.

![Mission Control — drift view](images/mc-drift.png)

### Competitive
Competitive-monitor diffs: pricing, positioning, and hiring changes detected on tracked competitor sites.

![Mission Control — competitive view](images/mc-competitive.png)

### Schedule
A calendar view of today + upcoming events, with conflicts surfaced.

![Mission Control — schedule view](images/mc-schedule.png)

### Telemetry
Token usage over time, daily spend history, model mix, and anomaly markers from the z-score detector.

![Mission Control — telemetry view](images/mc-telemetry.png)

### Chat
A full chat with the agent — streaming responses, voice in/out, and file/image attachments — synced with Telegram (see the README's "Telegram ↔ dashboard chat parity" section).

![Mission Control — chat view](images/mc-chat.png)

### Settings
Per-tenant configuration, surfaced read-only.

![Mission Control — settings view](images/mc-settings.png)

---

## Capturing screenshots

Mission Control shows live tenant data, so **never publish screenshots of a production instance** — they contain real tasks, deals, contacts, and financials. Two safe ways to produce the images above:

1. **Demo tenant (recommended for public docs).** Render `EXAMPLE_TENANT.yml`, serve the dashboard with synthetic `/api/*.json` fixtures, and screenshot each view. Nothing real is exposed.
2. **Redacted production capture.** Screenshot your live dashboard, then blur/replace names, dollar amounts, and contact details before committing.

The screenshots in this doc were produced with method 1 (synthetic demo tenant). The reusable harness — synthetic fixtures + Playwright capture scripts — lives in [`docs/demo/`](demo/) with a step-by-step regenerate guide.
