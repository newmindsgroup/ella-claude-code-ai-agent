#!/usr/bin/env python3
"""
roi-digest.py — weekly "what your agent did + what it was worth" summary.

v2.67.0. Reads the per-task-type ROI aggregation (from _roi.py, which reads
telemetry.json's pre-enriched top_tasks) and composes a digest:

  - How many tasks the agent completed this week
  - What it cost in API tokens (agent_cost)
  - The human-equivalent value (realization-adjusted)
  - The ROI multiple + hours saved
  - The top value-driving task types

Posts to Telegram (plain text — no MarkdownV2 escaping pain) and writes a
state file the dashboard surfaces on the ROI tab. Fires weekly via
roi-digest.timer (Monday morning). Also runnable on demand from the Skills
tab (Run-now) or `/roi-digest` in Telegram.

Design notes:
  - Plain-text Telegram message: avoids the MarkdownV2 escaping bugs that have
    bitten every other notification. Emojis + newlines only.
  - Quiet-week handling: if 0 completed tasks in the window, sends a short
    "quiet week" note rather than a confusing all-zeros report.
  - Pure read + post: no state mutation beyond the digest file. Safe to re-run.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ----------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes the {{TENANT_*}} placeholders
# ----------------------------------------------------------------------------
AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

DASHBOARD_HOSTNAME = "{{TENANT_DASHBOARD_HOSTNAME}}"
if DASHBOARD_HOSTNAME.startswith("{{"):
    DASHBOARD_HOSTNAME = "dashboard.example.com"

PERSON_FIRST_NAME = "{{TENANT_PERSON_FIRST_NAME}}"
if PERSON_FIRST_NAME.startswith("{{"):
    PERSON_FIRST_NAME = "there"

sys.path.insert(0, f"{AGENT_HOME}/scripts")
import _roi  # noqa: E402

TG_SEND = Path(AGENT_HOME) / "scripts" / "tg-send.sh"
STATE_DIR = Path(AGENT_HOME) / "state"
DIGEST_JSON = STATE_DIR / "roi-digest-latest.json"

WINDOW_DAYS = 7


def _money(n: float) -> str:
    n = n or 0
    if n >= 1000:
        return f"${n:,.0f}"
    if n >= 100:
        return f"${n:,.0f}"
    return f"${n:,.2f}"


def _roi_str(mult) -> str:
    if mult is None:
        return "—"
    if mult >= 100:
        return f"{mult:,.0f}×"
    return f"{mult:,.1f}×"


def build_digest() -> dict:
    """Compute the weekly ROI rollup. Returns a dict (also serialized to the
    dashboard state file)."""
    records = _roi.load_telemetry_tasks()
    groups = _roi.aggregate_by_type(records, window_days=WINDOW_DAYS)
    summary = _roi.summarize(groups)
    now = datetime.now(timezone.utc)
    week_start = (now - timedelta(days=WINDOW_DAYS)).date().isoformat()
    week_end = now.date().isoformat()
    # Top value drivers — by realized human value
    top = sorted(groups, key=lambda g: g.get("human_value_usd", 0), reverse=True)[:5]
    return {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "window_days": WINDOW_DAYS,
        "week_start": week_start,
        "week_end": week_end,
        "summary": summary,
        "top_drivers": top,
        "all_groups": groups,
    }


def compose_message(d: dict) -> str:
    s = d["summary"]
    runs = s.get("total_runs", 0)
    if not runs:
        return (
            f"📊 Weekly ROI digest ({d['week_start']} → {d['week_end']})\n\n"
            f"Quiet week — no completed agent tasks were attributed in the last "
            f"{d['window_days']} days. Nothing to report. (If this seems wrong, "
            f"telemetry-calc may not have attributed recent work yet.)"
        )

    agent_cost = s.get("total_agent_cost", 0)
    human_value = s.get("total_human_value", 0)
    hours = s.get("total_hours_saved", 0)
    roi = s.get("overall_roi")
    eff = s.get("overall_effective_hr")

    lines = [
        f"📊 Weekly ROI digest ({d['week_start']} → {d['week_end']})",
        "",
        f"This week your agent:",
        f"• Completed {runs} task{'s' if runs != 1 else ''} across {len(d['all_groups'])} type{'s' if len(d['all_groups']) != 1 else ''}",
        f"• Agent cost: {_money(agent_cost)} in API tokens",
        f"• Human-equivalent value: {_money(human_value)} (realization-adjusted)",
        f"• Time saved: {hours:.1f}h",
    ]
    if roi is not None:
        lines.append(f"• ROI: {_roi_str(roi)} — every $1 of agent spend ≈ {_money(roi)} of human work")
    if eff is not None:
        lines.append(f"• Effective rate: {_money(eff)}/hr of human work delivered")

    if d["top_drivers"]:
        lines.append("")
        lines.append("Top value drivers:")
        for i, g in enumerate(d["top_drivers"], 1):
            label = g.get("label") or g.get("task_type")
            lines.append(
                f"{i}. {label} — {g.get('runs', 0)}× · "
                f"{_money(g.get('human_value_usd', 0))} value · {_roi_str(g.get('roi_multiple'))} ROI"
            )

    lines.append("")
    lines.append(f"Full breakdown → https://{DASHBOARD_HOSTNAME}/  (ROI tab)")
    return "\n".join(lines)


def post_telegram(text: str) -> bool:
    if not TG_SEND.exists():
        sys.stderr.write(f"WARN: tg-send.sh missing at {TG_SEND}\n")
        return False
    try:
        # Plain text + --no-conversation-log: the digest is a one-way push;
        # we don't want it teeing back into the chat store as a "message".
        r = subprocess.run(
            [str(TG_SEND), "send", "--text", text, "--no-conversation-log"],
            capture_output=True, text=True, timeout=20,
        )
        return r.returncode == 0
    except Exception as e:
        sys.stderr.write(f"telegram post failed: {e}\n")
        return False


def write_state(d: dict, message: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    d_out = dict(d)
    d_out["message"] = message
    tmp = DIGEST_JSON.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(d_out, f, indent=2, default=str)
    tmp.replace(DIGEST_JSON)


def main() -> int:
    d = build_digest()
    message = compose_message(d)
    write_state(d, message)
    ok = post_telegram(message)
    runs = d["summary"].get("total_runs", 0)
    print(f"roi-digest: {runs} tasks · telegram={'sent' if ok else 'FAILED'} · "
          f"roi={d['summary'].get('overall_roi')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
