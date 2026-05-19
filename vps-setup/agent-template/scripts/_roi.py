"""
_roi.py — Per-skill / per-task-type ROI math for Mission Control.

v2.56.0 ships the centerpiece of Phase 4: a dashboard surface that answers
"value vs human" and "ROI of everything." None of the 5 OSS observability
projects surveyed (agentops, agentlens, hawkeye, nexus-labs, atsc) ship this.

Methodology (cross-checked across OptimNow/ai-roi-calculator, METR HCAST,
Superkind, MetaCTO, Retool, DX):

    human_cost      = (rate_per_hour / 60) * baseline_minutes * realization_rate
    agent_cost      = sum(tokens × pricing_table) + infra_overhead (we use 0)
    hours_saved     = (baseline_minutes / 60) * realization_rate
    roi_multiple    = human_cost / agent_cost  (∞ when agent_cost == 0)
    effective_hr    = agent_cost / hours_saved (when hours_saved > 0)

`realization_rate` ∈ [0, 1] discounts for "AI output still needs human review."
Industry split (Superkind):
    0.5 = output requires significant rework
    0.7 = average — light review then ship                 ← default
    0.9 = output ships with no edits

Values are conservative on purpose. We'd rather underreport ROI than overreport.

Reads from:
  - tasks/active.json + tasks/ledger.jsonl (lifecycle)
  - telemetry.json (already has per-task value_usd + agent_cost)
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable

# ----------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes {{TENANT_*}} placeholders
# ----------------------------------------------------------------------------
AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

LEDGER_PATH = Path(AGENT_HOME) / "tasks" / "ledger.jsonl"
TELEMETRY_PATH_DEFAULT = Path("/var/www/dashboard.example.com/api/telemetry.json")

# ROI config per task type. Mirrors TASK_TYPE_LOOKUP in telemetry-calc.py but
# adds realization_rate. Keep both in sync — if a new task type is added in
# telemetry-calc.py, add it here too (with a realization rate tier).
# (baseline_minutes, hourly_rate_usd, realization_rate, label)
ROI_CONFIG: dict[str, tuple[int, float, float, str]] = {
    "draft":             (45,  75.0, 0.7, "Drafting"),
    "research":          (60, 150.0, 0.7, "Research"),
    "strategy":          (90, 200.0, 0.5, "Strategy"),       # needs heavy review
    "review":            (20, 100.0, 0.9, "Review"),         # ships ~as-is
    "outreach":          (15,  90.0, 0.7, "Outreach"),
    "summary":           (15,  75.0, 0.9, "Summarization"),
    "scheduling":        (10,  50.0, 0.9, "Scheduling"),
    "data-pull":         (30,  90.0, 0.9, "Data pull"),
    "memory":            ( 5,  50.0, 0.9, "Memory note"),
    "drift-scan":        (30, 100.0, 0.9, "Brand audit"),
    "morning-brief":     (20,  75.0, 0.9, "Morning briefing"),
    "evening-rollup":    (15,  75.0, 0.9, "Evening rollup"),
    "social-draft":      (30,  90.0, 0.7, "Social drafting"),
    "newsletter":        (90, 150.0, 0.5, "Newsletter"),     # always edited
    "pipeline-report":   (30, 100.0, 0.9, "Pipeline report"),
    "competitive-scan":  (60, 150.0, 0.9, "Competitive scan"),
    "self-improvement":  (45, 150.0, 0.7, "Self-improvement review"),
    "dashboard-chat":    (10,  90.0, 0.9, "Dashboard chat"),
    "telegram-chat":     (10,  90.0, 0.9, "Telegram chat"),
    "default":           (15,  75.0, 0.7, "General task"),
}


def lookup(task_type: str | None) -> tuple[int, float, float, str]:
    if not task_type:
        return ROI_CONFIG["default"]
    return ROI_CONFIG.get(task_type, ROI_CONFIG["default"])


def human_cost_usd(baseline_min: int, hourly_rate: float, realization_rate: float = 1.0) -> float:
    """Direct port of the methodology formula."""
    return (hourly_rate / 60.0) * baseline_min * realization_rate


def hours_saved(baseline_min: int, realization_rate: float = 1.0) -> float:
    return (baseline_min / 60.0) * realization_rate


def roi_multiple(human_cost: float, agent_cost: float) -> float | None:
    """Returns None if agent_cost is zero (infinite ROI is misleading)."""
    if agent_cost <= 0:
        return None
    return round(human_cost / agent_cost, 2)


def effective_hourly_rate(agent_cost: float, hrs_saved: float) -> float | None:
    if hrs_saved <= 0:
        return None
    return round(agent_cost / hrs_saved, 2)


# ----------------------------------------------------------------------------
# Aggregation — group completed tasks by type, compute ROI per group
# ----------------------------------------------------------------------------
def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def load_telemetry_tasks(telemetry_path: Path = TELEMETRY_PATH_DEFAULT) -> list[dict]:
    """Read telemetry.json's top_tasks list (pre-enriched by telemetry-calc.py)."""
    try:
        with telemetry_path.open() as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    tasks = data.get("top_tasks") or []
    return [t for t in tasks if isinstance(t, dict)]


def aggregate_by_type(records: Iterable[dict], window_days: int = 7) -> list[dict]:
    """Group records by task type, compute ROI per group.

    Each input record should look like:
        {
            "task_id": ...,
            "type": "draft" | "research" | ...,
            "completed_at": ISO ts,
            "api_cost_usd": float,        # actual agent cost
            "value_usd": float,            # human-equivalent value (already
                                           # computed by telemetry-calc.py
                                           # WITHOUT realization_rate)
            "human_eq_minutes": int,
            "human_hourly_rate_usd": float,
            ...
        }
    Returns a list of group summaries with realization_rate applied.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=window_days)
    groups: dict[str, dict] = {}

    for r in records:
        if not isinstance(r, dict):
            continue
        completed = _parse_iso(r.get("completed_at"))
        if completed and completed < cutoff:
            continue
        ttype = r.get("type") or "default"
        baseline_min, hourly_rate, real_rate, label = lookup(ttype)

        g = groups.setdefault(ttype, {
            "task_type": ttype,
            "label": label,
            "runs": 0,
            "baseline_minutes_per_run": baseline_min,
            "hourly_rate_usd": hourly_rate,
            "realization_rate": real_rate,
            "agent_cost_usd": 0.0,
            "human_value_usd_raw": 0.0,   # without realization rate
            "human_minutes_saved": 0,
        })
        g["runs"] += 1
        g["agent_cost_usd"] += float(r.get("api_cost_usd") or 0)
        g["human_value_usd_raw"] += float(r.get("value_usd") or 0)
        g["human_minutes_saved"] += int(r.get("human_eq_minutes") or 0)

    # Finalize: apply realization rate, compute ROI multiples
    out = []
    for ttype, g in groups.items():
        real = g["realization_rate"]
        g["human_value_usd"] = round(g["human_value_usd_raw"] * real, 2)
        g["agent_cost_usd"]  = round(g["agent_cost_usd"], 4)
        g["human_value_usd_raw"] = round(g["human_value_usd_raw"], 2)
        hrs = hours_saved(g["human_minutes_saved"], real)
        g["hours_saved"]     = round(hrs, 2)
        g["roi_multiple"]    = roi_multiple(g["human_value_usd"], g["agent_cost_usd"])
        g["effective_hourly_rate"] = effective_hourly_rate(g["agent_cost_usd"], hrs)
        out.append(g)

    # Sort by ROI multiple desc (with None at the bottom)
    out.sort(key=lambda x: (x["roi_multiple"] is None, -(x["roi_multiple"] or 0)))
    return out


def summarize(groups: list[dict]) -> dict:
    """Top-line aggregate over all groups."""
    total_runs       = sum(g.get("runs", 0) for g in groups)
    total_agent_cost = round(sum(g.get("agent_cost_usd", 0) for g in groups), 4)
    total_human_val  = round(sum(g.get("human_value_usd", 0) for g in groups), 2)
    total_hrs_saved  = round(sum(g.get("hours_saved", 0) for g in groups), 2)
    return {
        "total_runs":          total_runs,
        "total_agent_cost":    total_agent_cost,
        "total_human_value":   total_human_val,
        "total_hours_saved":   total_hrs_saved,
        "overall_roi":         roi_multiple(total_human_val, total_agent_cost),
        "overall_effective_hr": effective_hourly_rate(total_agent_cost, total_hrs_saved),
    }
