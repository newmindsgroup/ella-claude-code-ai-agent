# Task ledger

Single source of truth for what the chief-of-staff agent is tracking.

## Files

- `ledger.jsonl` — append-only event log. One JSON object per line. Never edited, never deleted.
- `active.json` — materialized view of all current tasks. Re-computed from `ledger.jsonl` on every event.
- `archive.json` — completed/cancelled tasks older than 7 days (moved by `task-ledger.sh archive`).

These three files are NOT committed to git. They contain operational state, not configuration. The scripts that manage them (`task-ledger.sh`, `task-update.sh`, `tasks-render.sh`) live in `vps-setup/agents-config/scripts/` and ARE in git.

## Event schema (one line per event in `ledger.jsonl`)

```json
{"ts":"2026-04-30T16:00:00Z","id":"t-20260430-a1b2","event":"create","summary":"Draft Acme proposal","owner":"comms-agent","deadline":"2026-05-02","loud":true,"source":"telegram","state":"committed"}
{"ts":"2026-04-30T16:14:21Z","id":"t-20260430-a1b2","event":"state","state":"in_progress","msg":"Drafting"}
{"ts":"2026-04-30T16:42:08Z","id":"t-20260430-a1b2","event":"state","state":"awaiting_review","msg":"Draft staged in GHL"}
{"ts":"2026-05-01T09:11:42Z","id":"t-20260430-a1b2","event":"state","state":"done","msg":"Sent."}
```

## States

| State | Emoji | Meaning |
| --- | --- | --- |
| `proposed` | ✏️ | Surfaced but not committed |
| `committed` | 📌 | Agreed, on the board |
| `in_progress` | 🔧 | Agent actively working |
| `awaiting_review` | 👀 | Finished, needs {{TENANT_PERSON_FIRST_NAME}}'s ✅ |
| `awaiting_external` | ⏳ | Needs {{TENANT_PERSON_FIRST_NAME}} to do something |
| `blocked` | 🚧 | Stuck, surface why |
| `done` | ✅ | Completed |
| `cancelled` | ✖️ | {{TENANT_PERSON_FIRST_NAME}} said skip |
| `stale` | 🕐 | No movement in 48h+ (set by stale-watcher) |

## Auto-pings to Telegram

When a task with `loud: true` (default) goes through `state` event, `task-ledger.sh` calls `tg-send.sh` to ping {{TENANT_PERSON_FIRST_NAME}} with the new state, summary, and any progress message.

Tasks marked `loud: false` log silently and only show up in `/tasks` queries and the morning/evening rollups.
