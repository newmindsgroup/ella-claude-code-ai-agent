#!/usr/bin/env python3
"""
anomaly-detect.py — Phase 1 Python anomaly detection for Mission Control.

Reads /var/www/{dashboard}/api/telemetry.json (which has daily_token_history
written by telemetry-calc.py every 5 min). For each tracked metric, computes:

  - Rolling mean and stddev over the last N days (excluding today)
  - z-score for today: (today - mean) / stddev
  - EWMA (exponentially weighted moving average, alpha=0.3)
  - Anomaly flag when |z| >= configured threshold

Writes /var/www/{dashboard}/api/anomalies.json with the full breakdown so the
dashboard can surface it AND the rules engine can react to it (e.g., a rule
that fires when api_cost_today's z_score >= 2.5).

Stateless within a single run; no state file needed because daily_token_history
already provides the time series. EWMA is recomputed each invocation from the
same history (small data, no compounding error).

Runs as oneshot via anomaly-detect.timer every 30 min (telemetry refreshes every
5 min but we don't need real-time anomaly recompute).
"""
from __future__ import annotations

import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"
DASHBOARD_HOSTNAME = "{{TENANT_DASHBOARD_HOSTNAME}}"
if DASHBOARD_HOSTNAME.startswith("{{"):
    DASHBOARD_HOSTNAME = "dashboard.example.com"

API_DIR = Path("/var/www") / DASHBOARD_HOSTNAME / "api"
TELEMETRY_FILE = API_DIR / "telemetry.json"
OUTPUT_FILE = API_DIR / "anomalies.json"

# Anomaly threshold: |z| >= 2.0 = "noteworthy", >= 3.0 = "extreme"
Z_THRESHOLD_NOTEWORTHY = 2.0
Z_THRESHOLD_EXTREME = 3.0
EWMA_ALPHA = 0.3

# Metrics to track from daily_token_history. Each entry has {date, input,
# output, cache_read, cache_write}. We derive cost too.
PRICING_DEFAULT = {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75}


def day_cost(d, pricing):
    return ((d.get("input", 0) or 0) * pricing.get("input", 3.0)
            + (d.get("output", 0) or 0) * pricing.get("output", 15.0)
            + (d.get("cache_read", 0) or 0) * pricing.get("cache_read", 0.3)
            + (d.get("cache_write", 0) or 0) * pricing.get("cache_write", 3.75)
            ) / 1_000_000


def analyze_series(values: list[float], today_value: float | None = None) -> dict:
    """Given a series of historical daily values (today excluded) + today,
    return {mean, stddev, today, z_score, ewma, anomaly}."""
    history = [v for v in values if v is not None]
    n = len(history)
    if n < 2:
        return {
            "today": today_value,
            "mean": None, "stddev": None, "z_score": None,
            "ewma": today_value, "anomaly": "insufficient_data",
            "history_days": n,
        }
    mean = statistics.fmean(history)
    try:
        sd = statistics.stdev(history)
    except statistics.StatisticsError:
        sd = 0.0
    # EWMA over the whole series including today
    ewma = history[0]
    for v in history[1:]:
        ewma = EWMA_ALPHA * v + (1 - EWMA_ALPHA) * ewma
    if today_value is not None:
        ewma = EWMA_ALPHA * today_value + (1 - EWMA_ALPHA) * ewma
    # z-score for today
    z = None
    anomaly = "normal"
    if today_value is not None:
        if sd > 0:
            z = (today_value - mean) / sd
            abs_z = abs(z)
            if abs_z >= Z_THRESHOLD_EXTREME:
                anomaly = "extreme_high" if z > 0 else "extreme_low"
            elif abs_z >= Z_THRESHOLD_NOTEWORTHY:
                anomaly = "noteworthy_high" if z > 0 else "noteworthy_low"
        elif today_value > mean:
            # All-zero history with a non-zero today reads as anomalous even
            # without proper stddev — flag as noteworthy to surface it.
            anomaly = "noteworthy_high"
    return {
        "today": today_value,
        "mean": round(mean, 4) if mean is not None else None,
        "stddev": round(sd, 4),
        "z_score": round(z, 3) if z is not None else None,
        "ewma": round(ewma, 4) if ewma is not None else None,
        "anomaly": anomaly,
        "history_days": n,
    }


def main() -> int:
    if not TELEMETRY_FILE.exists():
        sys.stderr.write(f"telemetry.json missing at {TELEMETRY_FILE}\n")
        return 1
    try:
        tel = json.loads(TELEMETRY_FILE.read_text())
    except Exception as e:
        sys.stderr.write(f"failed to parse telemetry.json: {e}\n")
        return 2

    history = tel.get("daily_token_history") or []
    pricing = tel.get("pricing_per_mtok_usd") or PRICING_DEFAULT
    rollup_today = (tel.get("rollup") or {}).get("today") or {}

    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Split history into "today" vs "prior days"
    prior = [d for d in history if d.get("date") != today_str]
    today = next((d for d in history if d.get("date") == today_str), None)
    # If today isn't in the history yet (telemetry just rolled over),
    # use rollup.today.
    if today is None:
        today = {
            "date": today_str,
            "input": rollup_today.get("input_tokens", 0),
            "output": rollup_today.get("output_tokens", 0),
            "cache_read": rollup_today.get("cache_read_tokens", 0),
            "cache_write": rollup_today.get("cache_write_tokens", 0),
        }

    metrics = {}
    for key in ("input", "output", "cache_read", "cache_write"):
        prior_vals = [d.get(key, 0) or 0 for d in prior]
        metrics[f"{key}_tokens"] = analyze_series(prior_vals, today.get(key, 0) or 0)

    # Cost as a derived metric
    prior_costs = [day_cost(d, pricing) for d in prior]
    today_cost = day_cost(today, pricing)
    metrics["api_cost_usd"] = analyze_series(prior_costs, today_cost)

    # Task count from rollup if available — daily_token_history doesn't carry
    # it. We don't have a daily series for tasks; skip for now.

    # Surface flagged anomalies as a flat sorted list (highest |z| first)
    flagged = []
    for name, m in metrics.items():
        z = m.get("z_score")
        if z is None:
            continue
        if abs(z) >= Z_THRESHOLD_NOTEWORTHY:
            flagged.append({
                "metric": name,
                "z_score": z,
                "today": m["today"],
                "mean": m["mean"],
                "stddev": m["stddev"],
                "anomaly": m["anomaly"],
            })
    flagged.sort(key=lambda x: abs(x["z_score"]), reverse=True)

    now = datetime.now(timezone.utc)
    output = {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "thresholds": {
            "noteworthy_z": Z_THRESHOLD_NOTEWORTHY,
            "extreme_z": Z_THRESHOLD_EXTREME,
            "ewma_alpha": EWMA_ALPHA,
        },
        "metrics": metrics,
        "flagged": flagged,
        "flagged_count": len(flagged),
        "today_date": today_str,
        "history_days_used": len(prior),
    }

    # Atomic write
    tmp = OUTPUT_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(output, indent=2))
    tmp.replace(OUTPUT_FILE)
    OUTPUT_FILE.chmod(0o644)

    print(f"anomaly-detect: {len(metrics)} metrics analyzed, {len(flagged)} flagged "
          f"({len(prior)} days of history)")
    for f in flagged:
        print(f"  {f['anomaly']:>16s}  {f['metric']:<20s}  z={f['z_score']:+.2f}  "
              f"today={f['today']}  mean={f['mean']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
