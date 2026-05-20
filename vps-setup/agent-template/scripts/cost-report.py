#!/usr/bin/env python3
"""
cost-report.py — daily token-spend attribution (v2.68.0).

Answers "where did today's spend go?" — the actionable upgrade to the dumb
dollar-cap circuit breaker. When a spend spike happens (like the $114 day),
this tells you WHAT drove it: cost by span-kind, the top sessions by cost,
and — the headline diagnostic — the prompt-cache hit ratio.

Cache ratio is the thing to watch: on a Max subscription the dollar figure is
notional, but a LOW cache ratio means each agent turn is re-paying full input
price for the conversation context instead of the 10×-cheaper cache-read price.
That's the usual cause of a runaway "cost" number on a long session.

Writes state/cost-today.json (dashboard surfaces it) and, with --post, sends a
plain-text Telegram report. Runnable on demand:
  python3 cost-report.py            # write state file only
  python3 cost-report.py --post     # also send to Telegram
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

TELEMETRY_PATH = "/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/telemetry.json"
if TELEMETRY_PATH.startswith("/var/www/{{"):
    TELEMETRY_PATH = "/var/www/dashboard.example.com/api/telemetry.json"

# Display-only cap for context. The ENFORCED cap lives in
# rules/budget-ceilings.yaml; this mirrors it for the report header. Override
# via the COST_CAP_USD env var if you've changed the rule.
import os  # noqa: E402
DAILY_CAP_USD = float(os.environ.get("COST_CAP_USD", "20") or "20")

sys.path.insert(0, f"{AGENT_HOME}/scripts")
import _spans  # noqa: E402

TG_SEND = Path(AGENT_HOME) / "scripts" / "tg-send.sh"
STATE_DIR = Path(AGENT_HOME) / "state"
OUT_JSON = STATE_DIR / "cost-today.json"

# v2.69.0: spike alert tuning. Alert (don't block) when today's spend is
# SPIKE_RATIO× the rolling baseline AND above SPIKE_FLOOR (so we never alert on
# a tiny baseline). The hard runaway block lives in rules/budget-ceilings.yaml.
SPIKE_RATIO = 3.0
SPIKE_FLOOR_USD = 30.0


def _money(n: float) -> str:
    n = n or 0
    return f"${n:,.2f}" if n < 100 else f"${n:,.0f}"


def build() -> dict:
    now = datetime.now(timezone.utc)
    since = _spans.iso_start_of_day_utc()
    try:
        with _spans.connect() as conn:
            bd = _spans.cost_breakdown(conn, since)
    except Exception as e:
        bd = {"total_cost_usd": 0, "tokens": {}, "cache_ratio": 0,
              "cache_savings_usd": 0, "by_kind": [], "top_sessions": [], "error": str(e)}

    # Authoritative daily total comes from telemetry-calc (all agent activity),
    # which may exceed the spans-derived figure if session-parser is behind.
    telemetry_today = None
    telemetry_week = None
    today_cache_ratio = None
    try:
        with open(TELEMETRY_PATH) as f:
            t = json.load(f)
        rollup = t.get("rollup") or {}
        telemetry_today = (rollup.get("today") or {}).get("api_cost_usd")
        telemetry_week = (rollup.get("week") or {}).get("api_cost_usd")
        today_cache_ratio = (rollup.get("today") or {}).get("cache_hit_ratio")
    except Exception:
        pass

    headline_cost = telemetry_today if telemetry_today is not None else bd["total_cost_usd"]
    headline_cost = round(headline_cost or 0, 2)

    # v2.69.0: rolling baseline = avg of the PRIOR 6 days (week minus today / 6).
    # spike_ratio = today vs that baseline. Drives the alert (not a block).
    baseline = None
    spike_ratio = None
    if telemetry_week is not None and telemetry_week > 0:
        prior6 = max(0.0, telemetry_week - headline_cost) / 6.0
        baseline = round(prior6, 2)
        if prior6 > 0:
            spike_ratio = round(headline_cost / prior6, 2)

    is_spike = bool(spike_ratio is not None and spike_ratio >= SPIKE_RATIO
                    and headline_cost >= SPIKE_FLOOR_USD)

    # Prefer telemetry's authoritative today cache ratio over the partial spans one.
    cache_ratio = today_cache_ratio if today_cache_ratio is not None else bd["cache_ratio"]

    return {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "date": now.date().isoformat(),
        "daily_cap_usd": DAILY_CAP_USD,
        "headline_cost_usd": headline_cost,
        "pct_of_cap": round(headline_cost / DAILY_CAP_USD * 100, 1) if DAILY_CAP_USD else None,
        "baseline_usd": baseline,
        "spike_ratio": spike_ratio,
        "is_spike": is_spike,
        "spans_cost_usd": bd["total_cost_usd"],
        "cache_ratio": cache_ratio,
        "cache_savings_usd": bd["cache_savings_usd"],
        "tokens": bd["tokens"],
        "by_kind": bd["by_kind"],
        "top_sessions": bd["top_sessions"],
    }


def compose(d: dict) -> str:
    lines = [
        f"💰 Today's spend — {d['date']}",
        f"Total: {_money(d['headline_cost_usd'])} (cap {_money(d['daily_cap_usd'])}"
        + (f", {d['pct_of_cap']:.0f}%" if d.get("pct_of_cap") is not None else "") + ")",
    ]
    cr = d.get("cache_ratio")
    if cr is not None:
        flag = ""
        if cr < 0.5:
            flag = "  ⚠ LOW — caching may not be landing (this 10×'s cost)"
        elif cr >= 0.85:
            flag = "  ✓ healthy"
        lines.append(f"Cache hit ratio: {cr*100:.0f}%{flag}")
        if d.get("cache_savings_usd"):
            lines.append(f"Cache saved ~{_money(d['cache_savings_usd'])} vs uncached")

    if d.get("by_kind"):
        lines.append("")
        lines.append("By kind:")
        for k in d["by_kind"][:5]:
            lines.append(f"  • {k['kind']}: {_money(k['cost_usd'])} ({k['calls']} calls)")

    if d.get("top_sessions"):
        lines.append("")
        lines.append("Top sessions by cost:")
        for s in d["top_sessions"][:3]:
            sid = (s["conversation_id"] or "?")[:8]
            lines.append(f"  • {sid} — {_money(s['cost_usd'])} ({s['calls']} calls)")

    lines.append("")
    if d["headline_cost_usd"] > d["daily_cap_usd"]:
        lines.append("Over cap. If cache ratio is high, it's just heavy legit volume; "
                     "if low, the session context isn't caching — consider /clear or a fresh session.")
    return "\n".join(lines)


def compose_spike_alert(d: dict) -> str:
    cr = d.get("cache_ratio")
    cache_line = ""
    if cr is not None:
        if cr >= 0.85:
            cache_line = (f"\nCache hit ratio: {cr*100:.0f}% — healthy, so this is heavy "
                          f"VOLUME, not a caching problem. Likely a busy day.")
        elif cr < 0.5:
            cache_line = (f"\nCache hit ratio: {cr*100:.0f}% — ⚠ LOW. Caching isn't landing; "
                          f"this is a real inefficiency worth fixing (10× cost).")
        else:
            cache_line = f"\nCache hit ratio: {cr*100:.0f}%."
    top = ""
    if d.get("by_kind"):
        k = d["by_kind"][0]
        top = f"\nTop driver: {k['kind']} ({_money(k['cost_usd'])}, {k['calls']} calls)."
    return (
        f"📈 Spend spike — {d['date']}\n"
        f"Today: {_money(d['headline_cost_usd'])} vs ~{_money(d.get('baseline_usd') or 0)}/day baseline "
        f"({d.get('spike_ratio')}×)."
        f"{cache_line}{top}\n\n"
        f"This is an FYI, not a block — autonomous work keeps running. "
        f"(Hard runaway backstop is $300/day.)"
    )


def post(text: str) -> bool:
    if not TG_SEND.exists():
        return False
    try:
        r = subprocess.run([str(TG_SEND), "send", "--text", text, "--no-conversation-log"],
                           capture_output=True, text=True, timeout=20)
        return r.returncode == 0
    except Exception:
        return False


def _spike_already_alerted(date: str) -> bool:
    return (STATE_DIR / f"cost-spike-alerted-{date}.flag").exists()


def _mark_spike_alerted(date: str) -> None:
    (STATE_DIR / f"cost-spike-alerted-{date}.flag").write_text(
        datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))


def main() -> int:
    d = build()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_JSON.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(d, f, indent=2, default=str)
    tmp.replace(OUT_JSON)

    # v2.69.0: anomaly ALERT (not a block) — once per day, when spend spikes vs
    # baseline. The hourly timer keeps cost-today.json fresh; this fires the
    # Telegram alert at most once/day even though we run every hour.
    spike_sent = False
    if d.get("is_spike") and not _spike_already_alerted(d["date"]):
        spike_sent = post(compose_spike_alert(d))
        if spike_sent:
            _mark_spike_alerted(d["date"])

    # --post forces the full daily report (used on demand / by the weekly path).
    report_sent = post(compose(d)) if "--post" in sys.argv else False

    cr = d.get("cache_ratio") or 0
    print(f"cost-report: total={_money(d['headline_cost_usd'])} cache={cr*100:.0f}% "
          f"spike={d.get('spike_ratio')} spike_alert={spike_sent} report={report_sent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
