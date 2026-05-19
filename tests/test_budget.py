"""
test_budget.py — verify _budget.py circuit-breaker contract.

Hard guardrails for autonomous skills. These tests pin:
  - block/unblock round-trip
  - auto-expire after until_ts passes
  - global block takes precedence over per-skill checks
  - extend-only semantics (re-blocking never shortens)
  - fail-open on corrupt JSON
"""
from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import _budget  # noqa: E402


@pytest.fixture
def tmp_block_path(tmp_path, monkeypatch):
    """Redirect _budget.BLOCK_PATH to a tempdir so tests don't trash real state."""
    p = tmp_path / "budget-blocked.json"
    monkeypatch.setattr(_budget, "BLOCK_PATH", p)
    return p


def test_no_blocks_initially(tmp_block_path):
    assert _budget.load_blocked() == []
    assert _budget.is_blocked("anything") is None


def test_block_and_lookup_roundtrip(tmp_block_path):
    _budget.block("drift-scanner", "test reason", duration_hours=1)
    b = _budget.is_blocked("drift-scanner")
    assert b is not None
    assert b.skill == "drift-scanner"
    assert b.reason == "test reason"
    assert not b.is_global


def test_global_block_traps_any_skill(tmp_block_path):
    _budget.block_global("emergency kill switch", duration_hours=1)
    # Even a skill that was never named individually gets blocked
    b = _budget.is_blocked("totally-different-skill")
    assert b is not None
    assert b.is_global
    assert b.reason == "emergency kill switch"


def test_unblock_clears_entry(tmp_block_path):
    _budget.block("x", "y", duration_hours=1)
    assert _budget.is_blocked("x") is not None
    assert _budget.unblock("x") is True
    assert _budget.is_blocked("x") is None
    # Second unblock is a no-op
    assert _budget.unblock("x") is False


def test_extend_only_never_shortens(tmp_block_path):
    # Block for 24h
    b1 = _budget.block("skill", "first", duration_hours=24)
    until_1 = b1.until_ts
    # Attempt to "re-block" for 1h
    b2 = _budget.block("skill", "second", duration_hours=1)
    # The 24h deadline should win (extend-only)
    assert b2.until_ts == until_1


def test_auto_expire_removes_past_deadlines(tmp_block_path):
    """Manually write an expired block, ensure load_blocked prunes it."""
    expired = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    tmp_block_path.parent.mkdir(parents=True, exist_ok=True)
    with tmp_block_path.open("w") as f:
        json.dump({
            "old-skill": {"reason": "yesterday", "until_ts": expired,
                          "blocked_by": "test", "set_at": expired},
        }, f)
    # auto_expire is called by load_blocked + is_blocked
    blocks = _budget.load_blocked()
    assert blocks == []
    assert _budget.is_blocked("old-skill") is None


def test_corrupt_json_fails_open(tmp_block_path):
    """A garbled JSON file shouldn't crash — it should yield 'no blocks'."""
    tmp_block_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_block_path.write_text("{not json")
    assert _budget.load_blocked() == []
    assert _budget.is_blocked("anything") is None


def test_blocked_state_is_global_property():
    bs = _budget.BlockedState(skill="__global__", reason="x", until_ts="")
    assert bs.is_global is True
    bs2 = _budget.BlockedState(skill="something", reason="x", until_ts="")
    assert bs2.is_global is False


def test_blocked_state_expiry_detection():
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    past   = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    assert not _budget.BlockedState("s", "r", future).is_expired
    assert     _budget.BlockedState("s", "r", past).is_expired
    # Malformed = treat as expired (fail-open)
    assert     _budget.BlockedState("s", "r", "garbage").is_expired
