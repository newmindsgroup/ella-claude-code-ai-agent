#!/usr/bin/env python3
"""
telemetry-calc.py — compute per-task telemetry from the task ledger and Claude
conversation JSONLs.

For each task it derives:
  - wall_seconds         (in_progress_at -> completed_at, when both exist)
  - input_tokens         (raw + cache reads)
  - output_tokens
  - cache_read_tokens
  - cache_write_tokens
  - api_cost_usd         (Sonnet 4.6 list pricing)
  - human_eq_minutes     (industry-standard time per task type)
  - value_usd            (industry-standard hourly rate per task type)
  - net_savings_usd      (value_usd minus api_cost_usd)

Token attribution is by timestamp window: each Claude conversation message
that lands between a task's in_progress_at and completed_at is attributed to
that task. Messages outside any task window go to an unattributed bucket.

Output:
  /var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/telemetry.json
with rollup, by_type, by_owner, top_tasks, daily_token_history.

Designed to be run by a systemd timer every ~5 minutes. Atomic write via
tempfile + os.replace.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from glob import glob
from pathlib import Path

# ----------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes the {{TENANT_*}} placeholders
# ----------------------------------------------------------------------------

TENANT_ID         = "{{TENANT_ID}}"
AGENT_HOME        = "{{TENANT_AGENT_HOME}}"
LEDGER_PATH       = f"{AGENT_HOME}/tasks/ledger.jsonl"
CLAUDE_PROJECTS   = f"{AGENT_HOME.replace('/agents', '')}/.claude/projects"
OUTPUT_PATH       = "/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/telemetry.json"
TASKS_OUTPUT_PATH = "/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/tasks.json"
ACTIVE_TASKS_PATH = f"{AGENT_HOME}/tasks/active.json"

# Sonnet 4.6 list pricing — refreshed 2026-04-30
INPUT_PER_MTOK_USD       = 3.00
OUTPUT_PER_MTOK_USD      = 15.00
CACHE_WRITE_PER_MTOK_USD = 3.75   # 1.25x input
CACHE_READ_PER_MTOK_USD  = 0.30   # 0.1x input

# Human-equivalent rates per task type
# (min_per_task, hourly_rate_usd, label)
TASK_TYPE_LOOKUP: dict[str, tuple[int, float, str]] = {
    "draft":             (45, 75.0,  "Drafting"),
    "research":          (60, 150.0, "Research"),
    "strategy":          (90, 200.0, "Strategy"),
    "review":            (20, 100.0, "Review"),
    "outreach":          (15, 90.0,  "Outreach"),
    "summary":           (15, 75.0,  "Summarization"),
    "scheduling":        (10, 50.0,  "Scheduling"),
    "data-pull":         (30, 90.0,  "Data pull"),
    "memory":            ( 5, 50.0,  "Memory note"),
    "drift-scan":        (30, 100.0, "Brand audit"),
    "morning-brief":     (20, 75.0,  "Morning briefing"),
    "evening-rollup":    (15, 75.0,  "Evening rollup"),
    "social-draft":      (30, 90.0,  "Social drafting"),
    "newsletter":        (90, 150.0, "Newsletter"),
    "pipeline-report":   (30, 100.0, "Pipeline report"),
    "competitive-scan":  (60, 150.0, "Competitive scan"),
    "self-improvement":  (45, 150.0, "Self-improvement review"),
    "dashboard-chat":    (10, 90.0,  "Dashboard chat"),
    "telegram-chat":     (10, 90.0,  "Telegram chat"),
    "default":           (15, 75.0,  "General task"),
}

UTC = timezone.utc


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        # tolerate trailing Z
        s = s.replace("Z", "+00:00")
        return datetime.fromisoformat(s).astimezone(UTC)
    except (ValueError, TypeError):
        return None


def fmt_iso(dt: datetime | None) -> str | None:
    return dt.astimezone(UTC).isoformat() if dt else None


def lookup_type(task_type: str | None) -> tuple[int, float, str]:
    if not task_type:
        return TASK_TYPE_LOOKUP["default"]
    key = task_type.strip().lower()
    return TASK_TYPE_LOOKUP.get(key, TASK_TYPE_LOOKUP["default"])


def cost_for_tokens(input_tok: int, output_tok: int, cache_r: int, cache_w: int) -> float:
    """Compute Sonnet 4.6 API cost in USD from token counts."""
    # input_tok here is *raw* input (excluding cache reads)
    return round(
        (input_tok  / 1_000_000.0) * INPUT_PER_MTOK_USD +
        (output_tok / 1_000_000.0) * OUTPUT_PER_MTOK_USD +
        (cache_w    / 1_000_000.0) * CACHE_WRITE_PER_MTOK_USD +
        (cache_r    / 1_000_000.0) * CACHE_READ_PER_MTOK_USD,
        6,
    )


# ----------------------------------------------------------------------------
# Stage 1 — read the task ledger and build per-task records
# ----------------------------------------------------------------------------

def load_tasks() -> dict[str, dict]:
    """Walk the JSONL ledger and collapse events into per-task records."""
    tasks: dict[str, dict] = {}
    if not os.path.exists(LEDGER_PATH):
        return tasks

    with open(LEDGER_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            tid = ev.get("task_id") or ev.get("id")
            if not tid:
                continue
            t = tasks.setdefault(tid, {
                "task_id": tid,
                "summary": "",
                "owner": "",
                "source": "",
                "type": "",
                "state": "queued",
                "created_at": None,
                "in_progress_at": None,
                "completed_at": None,
                "failed_at": None,
                "events": [],
            })
            t["events"].append(ev)

            # Field updates from any event
            for k in ("summary", "owner", "source", "type", "state"):
                if ev.get(k):
                    t[k] = ev[k]

            ts = parse_iso(ev.get("ts") or ev.get("timestamp"))
            new_state = ev.get("state") or ev.get("event")
            if ts:
                if new_state == "created" or t["created_at"] is None:
                    if t["created_at"] is None or ts < t["created_at"]:
                        t["created_at"] = ts
                if new_state == "in_progress" and t["in_progress_at"] is None:
                    t["in_progress_at"] = ts
                if new_state in ("done", "completed"):
                    t["completed_at"] = ts
                if new_state in ("failed", "error", "blocked"):
                    t["failed_at"] = ts

    return tasks


# ----------------------------------------------------------------------------
# Stage 2 — walk Claude conversation JSONLs and harvest token events
# ----------------------------------------------------------------------------

def load_token_events() -> list[dict]:
    """Each entry: {ts, input, output, cache_read, cache_write}."""
    events: list[dict] = []
    if not os.path.isdir(CLAUDE_PROJECTS):
        return events

    for jsonl_path in sorted(glob(os.path.join(CLAUDE_PROJECTS, "**/*.jsonl"), recursive=True)):
        try:
            with open(jsonl_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = rec.get("message") or rec
                    usage = msg.get("usage") if isinstance(msg, dict) else None
                    if not usage:
                        continue
                    ts = parse_iso(
                        rec.get("timestamp") or rec.get("ts") or msg.get("created_at")
                    )
                    if not ts:
                        continue
                    events.append({
                        "ts": ts,
                        "input":       int(usage.get("input_tokens", 0) or 0),
                        "output":      int(usage.get("output_tokens", 0) or 0),
                        "cache_read":  int(usage.get("cache_read_input_tokens", 0) or 0),
                        "cache_write": int(usage.get("cache_creation_input_tokens", 0) or 0),
                    })
        except OSError:
            continue
    return events


# ----------------------------------------------------------------------------
# Stage 3 — attribute token events to tasks via timestamp windows
# ----------------------------------------------------------------------------

def attribute_tokens(tasks: dict[str, dict], events: list[dict]) -> tuple[dict[str, dict], dict]:
    # Sort tasks by in_progress_at
    windowed = [t for t in tasks.values() if t.get("in_progress_at")]
    windowed.sort(key=lambda t: t["in_progress_at"])

    bucket = lambda: {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "n_messages": 0}
    per_task = {tid: bucket() for tid in tasks}
    unattributed = bucket()

    for ev in events:
        ts = ev["ts"]
        match = None
        for t in windowed:
            start = t["in_progress_at"]
            end   = t.get("completed_at") or t.get("failed_at") or (start + timedelta(hours=2))
            if start <= ts <= end:
                match = t
                break
        target = per_task[match["task_id"]] if match else unattributed
        target["input"]       += ev["input"]
        target["output"]      += ev["output"]
        target["cache_read"]  += ev["cache_read"]
        target["cache_write"] += ev["cache_write"]
        target["n_messages"]  += 1

    return per_task, unattributed


# ----------------------------------------------------------------------------
# Stage 4 — compute per-task telemetry derived fields
# ----------------------------------------------------------------------------

def enrich_tasks(tasks: dict[str, dict], per_task_tok: dict[str, dict]) -> list[dict]:
    out = []
    for tid, t in tasks.items():
        tok = per_task_tok.get(tid, {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "n_messages": 0})
        wall = None
        if t.get("in_progress_at") and t.get("completed_at"):
            wall = (t["completed_at"] - t["in_progress_at"]).total_seconds()

        api_cost = cost_for_tokens(tok["input"], tok["output"], tok["cache_read"], tok["cache_write"])
        human_min, hourly_rate, type_label = lookup_type(t.get("type"))
        value_usd = round(human_min * (hourly_rate / 60.0), 2)
        net_savings = round(value_usd - api_cost, 2)
        cache_total = tok["input"] + tok["cache_read"]
        cache_ratio = (tok["cache_read"] / cache_total) if cache_total > 0 else 0.0

        out.append({
            "task_id": tid,
            "summary": t.get("summary", ""),
            "owner":   t.get("owner", ""),
            "source":  t.get("source", ""),
            "type":    t.get("type", ""),
            "type_label": type_label,
            "state":   t.get("state", ""),
            "created_at":     fmt_iso(t.get("created_at")),
            "in_progress_at": fmt_iso(t.get("in_progress_at")),
            "completed_at":   fmt_iso(t.get("completed_at")),
            "failed_at":      fmt_iso(t.get("failed_at")),
            "wall_seconds":   wall,
            "input_tokens":   tok["input"],
            "output_tokens":  tok["output"],
            "cache_read_tokens":  tok["cache_read"],
            "cache_write_tokens": tok["cache_write"],
            "n_messages":     tok["n_messages"],
            "api_cost_usd":   api_cost,
            "human_eq_minutes": human_min,
            "human_hourly_rate_usd": hourly_rate,
            "value_usd":      value_usd,
            "net_savings_usd": net_savings,
            "cache_hit_ratio": round(cache_ratio, 4),
        })
    return out


# ----------------------------------------------------------------------------
# Stage 5 — rollups
# ----------------------------------------------------------------------------

def in_window(iso: str | None, start: datetime, end: datetime) -> bool:
    dt = parse_iso(iso)
    return bool(dt and start <= dt <= end)


def rollup(records: list[dict], start: datetime, end: datetime) -> dict:
    sub = [r for r in records if in_window(r.get("created_at"), start, end)
                              or in_window(r.get("completed_at"), start, end)]
    sums = defaultdict(float)
    sums["task_count"] = len(sub)
    for r in sub:
        sums["input_tokens"]       += r["input_tokens"]
        sums["output_tokens"]      += r["output_tokens"]
        sums["cache_read_tokens"]  += r["cache_read_tokens"]
        sums["cache_write_tokens"] += r["cache_write_tokens"]
        sums["api_cost_usd"]       += r["api_cost_usd"]
        sums["value_usd"]          += r["value_usd"]
        sums["net_savings_usd"]    += r["net_savings_usd"]
        sums["human_eq_minutes"]   += r["human_eq_minutes"]
    cache_total = sums["input_tokens"] + sums["cache_read_tokens"]
    sums["cache_hit_ratio"] = (sums["cache_read_tokens"] / cache_total) if cache_total > 0 else 0.0
    sums["human_eq_hours"]  = round(sums["human_eq_minutes"] / 60.0, 2)
    return {k: (round(v, 4) if isinstance(v, float) else v) for k, v in sums.items()}


def daily_history(events: list[dict], days: int = 7) -> list[dict]:
    today = datetime.now(UTC).date()
    out = []
    for i in range(days - 1, -1, -1):
        day = today - timedelta(days=i)
        day_start = datetime(day.year, day.month, day.day, tzinfo=UTC)
        day_end   = day_start + timedelta(days=1)
        bucket = {"date": day.isoformat(), "input": 0, "output": 0, "cache_read": 0, "cache_write": 0}
        for ev in events:
            if day_start <= ev["ts"] < day_end:
                bucket["input"]       += ev["input"]
                bucket["output"]      += ev["output"]
                bucket["cache_read"]  += ev["cache_read"]
                bucket["cache_write"] += ev["cache_write"]
        out.append(bucket)
    return out


def by_dimension(records: list[dict], key: str, top: int | None = None) -> list[dict]:
    grouped: dict[str, dict] = defaultdict(lambda: {
        "count": 0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
        "cache_write_tokens": 0, "api_cost_usd": 0.0, "value_usd": 0.0, "net_savings_usd": 0.0,
    })
    for r in records:
        k = r.get(key) or "(none)"
        g = grouped[k]
        g["count"] += 1
        g["input_tokens"]       += r["input_tokens"]
        g["output_tokens"]      += r["output_tokens"]
        g["cache_read_tokens"]  += r["cache_read_tokens"]
        g["cache_write_tokens"] += r["cache_write_tokens"]
        g["api_cost_usd"]       += r["api_cost_usd"]
        g["value_usd"]          += r["value_usd"]
        g["net_savings_usd"]    += r["net_savings_usd"]
    out = [{key: k, **{kk: round(vv, 4) if isinstance(vv, float) else vv for kk, vv in v.items()}} for k, v in grouped.items()]
    out.sort(key=lambda x: x["value_usd"], reverse=True)
    return out[:top] if top else out


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

def write_merged_tasks_json(records: list[dict]) -> int:
    """Write /api/tasks.json with lifecycle + telemetry merged per task.

    v2.22.0: replaces dashboard-sync.sh's role for tasks.json. The dashboard
    no longer joins client-side; it gets a single endpoint with both shapes.

    Lifecycle (id, summary, events, owner, source, state, deadline, loud,
    created_at, updated_at) comes from tasks/active.json. Attribution
    (input_tokens, output_tokens, cache_*, wall_seconds, api_cost_usd,
    value_usd, human_eq_minutes, etc.) comes from `records` (the enriched
    output of enrich_tasks). Tasks present in lifecycle but missing
    attribution stay in the output with zero/null cost fields. Tasks
    present in attribution but missing lifecycle (rare; usually transient)
    are added as bare attribution records.
    """
    # Build by-id lookup from the attributed records.
    by_id: dict[str, dict] = {}
    for r in records:
        tid = r.get("task_id") or r.get("id")
        if tid:
            by_id[tid] = r

    # Read lifecycle. tasks/active.json may be a dict-by-id, an array, or absent.
    lifecycle: dict[str, dict] = {}
    if os.path.exists(ACTIVE_TASKS_PATH):
        try:
            with open(ACTIVE_TASKS_PATH, encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict):
                lifecycle = raw
            elif isinstance(raw, list):
                for t in raw:
                    if isinstance(t, dict) and t.get("id"):
                        lifecycle[t["id"]] = t
        except (OSError, json.JSONDecodeError) as e:
            print(f"[telemetry] WARN: could not read {ACTIVE_TASKS_PATH}: {e}")

    # Merge — lifecycle wins on shared keys; telemetry adds attribution fields.
    TELEM_FIELDS = (
        "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
        "wall_seconds", "n_messages", "api_cost_usd", "value_usd",
        "human_eq_minutes", "human_hourly_rate_usd", "net_savings_usd",
        "cache_hit_ratio", "type_label",
    )
    merged: dict[str, dict] = {}
    seen = set()
    for tid, t in lifecycle.items():
        out = dict(t)
        out.setdefault("id", tid)
        r = by_id.get(tid)
        if r:
            for k in TELEM_FIELDS:
                if k in r and out.get(k) is None:
                    out[k] = r[k]
        merged[tid] = out
        seen.add(tid)
    # Attributed-but-not-lifecycle (e.g. dashboard-chat tasks not yet in active.json).
    for tid, r in by_id.items():
        if tid in seen:
            continue
        # Synthesize a minimal lifecycle record from the attribution fields.
        merged[tid] = {
            "id": tid,
            "summary": r.get("summary", ""),
            "owner":   r.get("owner",   ""),
            "source":  r.get("source",  ""),
            "state":   r.get("state",   "done"),
            "events":  [],
            "created_at": r.get("created_at"),
            "updated_at": r.get("completed_at") or r.get("created_at"),
            **{k: r[k] for k in TELEM_FIELDS if k in r},
        }

    out_path = Path(TASKS_OUTPUT_PATH)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="tasks-", suffix=".json", dir=str(out_path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2, default=str)
        os.replace(tmp, out_path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    try:
        os.chmod(out_path, 0o644)
    except OSError:
        pass
    return len(merged)


def main() -> int:
    now = datetime.now(UTC)
    today_start = datetime(now.year, now.month, now.day, tzinfo=UTC)
    week_start  = today_start - timedelta(days=7)
    month_start = today_start - timedelta(days=30)
    epoch       = datetime(1970, 1, 1, tzinfo=UTC)

    tasks = load_tasks()
    events = load_token_events()
    per_task_tok, unattributed = attribute_tokens(tasks, events)
    records = enrich_tasks(tasks, per_task_tok)

    payload = {
        "generated_at": now.isoformat(),
        "tenant_id": TENANT_ID,
        "pricing_model": "claude-sonnet-4-6",
        "pricing_per_mtok_usd": {
            "input": INPUT_PER_MTOK_USD,
            "output": OUTPUT_PER_MTOK_USD,
            "cache_write": CACHE_WRITE_PER_MTOK_USD,
            "cache_read": CACHE_READ_PER_MTOK_USD,
        },
        "rollup": {
            "today":    rollup(records, today_start, now),
            "week":     rollup(records, week_start,  now),
            "month":    rollup(records, month_start, now),
            "all_time": rollup(records, epoch,       now),
        },
        "daily_token_history": daily_history(events, days=7),
        "by_type":  by_dimension(records, "type"),
        "by_owner": by_dimension(records, "owner"),
        "top_tasks": sorted(records, key=lambda r: r["value_usd"], reverse=True)[:10],
        "unattributed_tokens": unattributed,
        "task_count": len(records),
        "event_count": len(events),
    }

    out_path = Path(OUTPUT_PATH)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Atomic write
    fd, tmp = tempfile.mkstemp(prefix="telemetry-", suffix=".json", dir=str(out_path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, default=str)
        os.replace(tmp, out_path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise

    try:
        os.chmod(out_path, 0o644)
    except OSError:
        pass

    print(f"[telemetry] wrote {out_path} — {len(records)} tasks, {len(events)} token events")

    # v2.22.0: also write the merged /api/tasks.json so the dashboard doesn't
    # need to client-side-join lifecycle (tasks/active.json) + attribution
    # (telemetry.json#top_tasks). Single source of truth.
    try:
        n_merged = write_merged_tasks_json(records)
        print(f"[telemetry] wrote {TASKS_OUTPUT_PATH} — {n_merged} tasks (lifecycle+attribution merged)")
    except Exception as e:
        # Don't let the merge step fail the whole telemetry-calc run — telemetry.json
        # is the more critical output. Log and continue.
        print(f"[telemetry] WARN: tasks.json merge failed: {e}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
