"""
test_roi.py — verify _roi.py ROI math.

These tests pin the methodology (Superkind / OptimNow / Retool) so any future
hourly-rate tweak or realization_rate change is intentional, not accidental.
"""
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import _roi


def test_lookup_returns_default_for_unknown_type():
    bm, hr, rr, lbl = _roi.lookup("warp-speed-thing")
    assert bm == 15
    assert hr == 75.0
    assert rr == 0.7


def test_lookup_returns_known_type():
    bm, hr, rr, lbl = _roi.lookup("strategy")
    assert bm == 90
    assert hr == 200.0
    assert rr == 0.5
    assert lbl == "Strategy"


def test_human_cost_math():
    # 60min @ $150/hr * 0.7 realization = $105
    cost = _roi.human_cost_usd(60, 150.0, 0.7)
    assert abs(cost - 105.0) < 0.001


def test_hours_saved_applies_realization():
    # 120 min * 0.5 realization = 1 hour saved
    assert abs(_roi.hours_saved(120, 0.5) - 1.0) < 0.001
    # 120 min * 1.0 = 2 hours
    assert abs(_roi.hours_saved(120, 1.0) - 2.0) < 0.001


def test_roi_multiple_basic():
    # $100 human value, $1 agent cost = 100×
    assert _roi.roi_multiple(100, 1) == 100.0


def test_roi_multiple_handles_zero_agent_cost():
    """Infinite ROI is misleading — return None."""
    assert _roi.roi_multiple(100, 0) is None


def test_effective_hourly_rate():
    # $5 agent cost over 0.5 hrs saved = $10/hr
    assert _roi.effective_hourly_rate(5.0, 0.5) == 10.0


def test_effective_hourly_rate_handles_zero_hours():
    assert _roi.effective_hourly_rate(5.0, 0) is None


def test_aggregate_by_type_groups_correctly():
    now_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    records = [
        {"task_id": "1", "type": "draft", "completed_at": now_iso,
         "api_cost_usd": 0.10, "value_usd": 56.25, "human_eq_minutes": 45,
         "human_hourly_rate_usd": 75.0},
        {"task_id": "2", "type": "draft", "completed_at": now_iso,
         "api_cost_usd": 0.20, "value_usd": 56.25, "human_eq_minutes": 45,
         "human_hourly_rate_usd": 75.0},
        {"task_id": "3", "type": "research", "completed_at": now_iso,
         "api_cost_usd": 0.50, "value_usd": 150.0, "human_eq_minutes": 60,
         "human_hourly_rate_usd": 150.0},
    ]
    groups = _roi.aggregate_by_type(records)
    by_type = {g["task_type"]: g for g in groups}

    # Draft: 2 runs, $0.30 agent cost, $112.50 raw value, 0.7 realization
    assert by_type["draft"]["runs"] == 2
    assert abs(by_type["draft"]["agent_cost_usd"] - 0.30) < 0.001
    assert by_type["draft"]["realization_rate"] == 0.7
    # Realized value = 112.50 * 0.7 = 78.75
    assert abs(by_type["draft"]["human_value_usd"] - 78.75) < 0.001
    # ROI = 78.75 / 0.30 = 262.5×
    assert by_type["draft"]["roi_multiple"] == 262.5


def test_aggregate_filters_old_completed_tasks():
    """Tasks completed more than `window_days` ago are skipped."""
    long_ago = "2020-01-01T00:00:00Z"
    now_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    records = [
        {"task_id": "old", "type": "draft", "completed_at": long_ago,
         "api_cost_usd": 0.10, "value_usd": 56.25, "human_eq_minutes": 45},
        {"task_id": "new", "type": "draft", "completed_at": now_iso,
         "api_cost_usd": 0.20, "value_usd": 56.25, "human_eq_minutes": 45},
    ]
    groups = _roi.aggregate_by_type(records, window_days=7)
    assert len(groups) == 1
    assert groups[0]["runs"] == 1


def test_summarize_totals_correctly():
    groups = [
        {"runs": 2, "agent_cost_usd": 0.30, "human_value_usd": 78.75, "hours_saved": 1.05},
        {"runs": 1, "agent_cost_usd": 0.50, "human_value_usd": 105.0, "hours_saved": 0.70},
    ]
    s = _roi.summarize(groups)
    assert s["total_runs"] == 3
    assert abs(s["total_agent_cost"] - 0.80) < 0.001
    assert abs(s["total_human_value"] - 183.75) < 0.01
    # Overall ROI = 183.75 / 0.80 ≈ 229.7
    assert s["overall_roi"] is not None
    assert 229.5 < s["overall_roi"] < 230.0


def test_summarize_handles_no_groups():
    s = _roi.summarize([])
    assert s["total_runs"] == 0
    assert s["total_agent_cost"] == 0.0
    assert s["overall_roi"] is None
    assert s["overall_effective_hr"] is None


def test_realization_rates_in_valid_range():
    """No misconfigured realization rate should sneak in."""
    for ttype, (bm, hr, rr, lbl) in _roi.ROI_CONFIG.items():
        assert 0.0 < rr <= 1.0, f"{ttype} has invalid realization_rate={rr}"
        assert bm > 0, f"{ttype} has non-positive baseline_minutes={bm}"
        assert hr > 0, f"{ttype} has non-positive hourly_rate={hr}"
