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
    try:
        with open(TELEMETRY_PATH) as f:
            t = json.load(f)
        telemetry_today = ((t.get("rollup") or {}).get("today") or {}).get("api_cost_usd")
    except Exception:
        pass

    headline_cost = telemetry_today if telemetry_today is not None else bd["total_cost_usd"]
    return {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "date": now.date().isoformat(),
        "daily_cap_usd": DAILY_CAP_USD,
        "headline_cost_usd": round(headline_cost or 0, 2),
        "pct_of_cap": round((headline_cost or 0) / DAILY_CAP_USD * 100, 1) if DAILY_CAP_USD else None,
        "spans_cost_usd": bd["total_cost_usd"],
        "cache_ratio": bd["cache_ratio"],
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


def post(text: str) -> bool:
    if not TG_SEND.exists():
        return False
    try:
        r = subprocess.run([str(TG_SEND), "send", "--text", text, "--no-conversation-log"],
                           capture_output=True, text=True, timeout=20)
        return r.returncode == 0
    except Exception:
        return False


def main() -> int:
    d = build()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_JSON.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(d, f, indent=2, default=str)
    tmp.replace(OUT_JSON)

    msg = compose(d)
    sent = post(msg) if "--post" in sys.argv else False
    print(f"cost-report: total={_money(d['headline_cost_usd'])} "
          f"cache={d['cache_ratio']*100:.0f}% posted={sent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
