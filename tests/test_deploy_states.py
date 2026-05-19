"""
test_deploy_states.py — verify _deploy_states.py state machine.

These tests are pure-logic (no VPS hits). They lock in the canonical
transition graph so any future refactor (e.g., a real Python `/deploy`
implementation) is bound to the same legal-transitions contract.
"""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import _deploy_states as ds  # noqa: E402


def test_initial_can_only_become_started():
    assert ds.is_legal_transition(None, "started")
    for phase in ("preflight_passed", "smoke_passed", "ready_to_ship",
                  "shipped", "failed", "cancelled"):
        assert not ds.is_legal_transition(None, phase)


def test_forward_progression_is_legal():
    legal_chain = ["started", "preflight_passed", "smoke_passed",
                   "ready_to_ship", "shipped"]
    for i in range(len(legal_chain) - 1):
        assert ds.is_legal_transition(legal_chain[i], legal_chain[i + 1]), \
            f"{legal_chain[i]} → {legal_chain[i+1]} should be legal"


def test_skipping_phases_is_illegal():
    """Going from started directly to shipped is illegal."""
    assert not ds.is_legal_transition("started", "shipped")
    assert not ds.is_legal_transition("started", "ready_to_ship")
    assert not ds.is_legal_transition("preflight_passed", "shipped")
    assert not ds.is_legal_transition("smoke_passed", "shipped")


def test_failed_and_cancelled_legal_from_active_phases():
    """failed and cancelled are reachable from every active phase."""
    for active in ("started", "preflight_passed", "smoke_passed", "ready_to_ship"):
        assert ds.is_legal_transition(active, "failed"), f"{active} → failed should be legal"
        assert ds.is_legal_transition(active, "cancelled"), f"{active} → cancelled should be legal"


def test_terminal_phases_have_no_exit():
    """shipped/failed/cancelled are terminal — no further transitions."""
    for terminal in ("shipped", "failed", "cancelled"):
        for next_phase in ds.PHASES:
            assert not ds.is_legal_transition(terminal, next_phase), \
                f"{terminal} should not transition to {next_phase}"


def test_backwards_transitions_are_illegal():
    """ready_to_ship → started is illegal."""
    assert not ds.is_legal_transition("ready_to_ship", "started")
    assert not ds.is_legal_transition("smoke_passed", "preflight_passed")


def test_unknown_phase_is_illegal():
    """Made-up phase names rejected."""
    assert not ds.is_legal_transition("started", "rolled_back")
    assert not ds.is_legal_transition("started", "")


def test_is_terminal_marks_correct_set():
    assert ds.is_terminal("shipped")
    assert ds.is_terminal("failed")
    assert ds.is_terminal("cancelled")
    assert not ds.is_terminal("started")
    assert not ds.is_terminal("ready_to_ship")


def test_parse_state_file_handles_valid_phase(tmp_path):
    f = tmp_path / "v2.50.0.state.json"
    f.write_text(json.dumps({
        "version": "v2.50.0",
        "phase": "ready_to_ship",
        "started_at": "2026-05-19T01:00:00Z",
        "updated_at": "2026-05-19T01:15:00Z",
    }))
    rec = ds.parse_state_file(f)
    assert rec is not None
    assert rec.version == "v2.50.0"
    assert rec.phase == "ready_to_ship"
    assert rec.is_legal is True
    assert rec.is_terminal is False
    assert rec.age_seconds > 0


def test_parse_state_file_flags_unknown_phase(tmp_path):
    f = tmp_path / "v999.state.json"
    f.write_text(json.dumps({
        "version": "v999",
        "phase": "warp-speed",  # not a real phase
        "started_at": "2026-05-19T01:00:00Z",
    }))
    rec = ds.parse_state_file(f)
    assert rec is not None
    assert rec.is_legal is False
    assert "warp-speed" in rec.illegal_reason


def test_load_deploys_sorts_active_first(tmp_path):
    """Active deploys should sort before terminal ones."""
    (tmp_path / "v1.state.json").write_text(json.dumps({
        "version": "v1", "phase": "shipped",
        "started_at": "2026-05-19T01:00:00Z",
    }))
    (tmp_path / "v2.state.json").write_text(json.dumps({
        "version": "v2", "phase": "ready_to_ship",
        "started_at": "2026-05-19T01:30:00Z",
    }))
    deploys = ds.load_deploys(tmp_path)
    assert len(deploys) == 2
    # Active first
    assert deploys[0].version == "v2"
    assert deploys[1].version == "v1"


def test_summarize_counts_correctly(tmp_path):
    for name, phase in [("v1", "shipped"), ("v2", "ready_to_ship"),
                        ("v3", "failed"), ("v4", "preflight_passed")]:
        (tmp_path / f"{name}.state.json").write_text(json.dumps({
            "version": name, "phase": phase,
            "started_at": "2026-05-19T01:00:00Z",
        }))
    deploys = ds.load_deploys(tmp_path)
    s = ds.summarize(deploys)
    assert s["total"] == 4
    assert s["active"] == 2  # ready_to_ship + preflight_passed
    assert s["terminal"] == 2  # shipped + failed
    assert s["illegal"] == 0
    assert s["by_phase"]["shipped"] == 1
    assert s["by_phase"]["ready_to_ship"] == 1
    assert s["by_phase"]["failed"] == 1
    assert s["by_phase"]["preflight_passed"] == 1
