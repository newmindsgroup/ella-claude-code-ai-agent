"""
_deploy_states.py — State machine for the /deploy lifecycle.

deploy.sh (~600 lines of bash) manages the actual deploy mechanics — git
fetch, preflight, smoke, callback handling, push, etc. v2.53.0 doesn't
replace that. Instead, this module is the canonical record of which state
transitions are LEGAL, so we can:

  1. Validate state files in deploys/{version}.state.json
  2. Detect transitions that should be impossible (e.g., shipped → started)
  3. Surface deploy state on the dashboard (Deploys tab)
  4. Provide a typed library that a future deploy.sh refactor can call into

The bash code remains the orchestrator. This module is a passive observer +
validator. If the validator finds an illegal transition, that's a bug in
deploy.sh (or hand-edited state) that needs investigation.

Transition graph (from deploy.sh header + actual code paths):

  (initial) ──► started
  started ──► preflight_passed
  preflight_passed ──► smoke_passed
  smoke_passed ──► ready_to_ship
  ready_to_ship ──► shipped
  ANY ──► failed   (preflight fail, git push fail, etc.)
  ANY ──► cancelled ({{TENANT_PERSON_FIRST_NAME}} taps Cancel button or /deploy cancel)

Terminal states: shipped, failed, cancelled
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# Canonical phase list — ordered for UI display.
PHASES = (
    "started",
    "preflight_passed",
    "smoke_passed",
    "ready_to_ship",
    "shipped",
    "failed",
    "cancelled",
)

# Legal forward transitions from each phase.
# `None` represents the implicit pre-state before any state file exists.
LEGAL_TRANSITIONS: dict[str | None, set[str]] = {
    None:               {"started"},
    "started":          {"preflight_passed", "failed", "cancelled"},
    "preflight_passed": {"smoke_passed", "failed", "cancelled"},
    "smoke_passed":     {"ready_to_ship", "failed", "cancelled"},
    "ready_to_ship":    {"shipped", "failed", "cancelled"},
    # Terminal states — no further transitions allowed
    "shipped":          set(),
    "failed":           set(),
    "cancelled":        set(),
}

TERMINAL_PHASES = {"shipped", "failed", "cancelled"}
ACTIVE_PHASES = {p for p in PHASES if p not in TERMINAL_PHASES}


def is_legal_transition(from_phase: str | None, to_phase: str) -> bool:
    """Returns True if `from_phase → to_phase` is allowed by the state machine."""
    if to_phase not in PHASES:
        return False
    allowed = LEGAL_TRANSITIONS.get(from_phase, set())
    return to_phase in allowed


def is_terminal(phase: str) -> bool:
    return phase in TERMINAL_PHASES


def is_active(phase: str) -> bool:
    return phase in ACTIVE_PHASES


@dataclass
class DeployRecord:
    """One deploy's state, including derived health diagnostics."""
    version: str
    phase: str
    started_at: str = ""
    updated_at: str = ""
    state_file: str = ""
    history: list[str] = None  # type: ignore[assignment]
    is_legal: bool = True
    illegal_reason: str = ""
    is_terminal: bool = False
    age_seconds: int = 0
    extra: dict = None  # type: ignore[assignment]

    def __post_init__(self):
        if self.history is None:
            self.history = []
        if self.extra is None:
            self.extra = {}


def parse_state_file(state_file: Path) -> DeployRecord | None:
    """Parse a deploys/{version}.state.json. Returns None if unreadable."""
    try:
        data = json.loads(state_file.read_text())
    except Exception:
        return None

    if not isinstance(data, dict):
        return None

    version = data.get("version") or state_file.stem.replace(".state", "")
    phase = data.get("phase", "")
    started_at = data.get("started_at", "")
    updated_at = data.get("updated_at", "")

    # Extract any history if present. deploy.sh doesn't currently log a
    # full transition history, but we can reconstruct it from the file mtime.
    history = data.get("history", [])
    if not isinstance(history, list):
        history = []

    # Age relative to now
    now = datetime.now(timezone.utc)
    age = 0
    if started_at:
        try:
            started_dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            age = int((now - started_dt).total_seconds())
        except Exception:
            pass

    return DeployRecord(
        version=version,
        phase=phase,
        started_at=started_at,
        updated_at=updated_at,
        state_file=str(state_file),
        history=history,
        is_legal=phase in PHASES,
        illegal_reason="" if phase in PHASES else f"unknown phase {phase!r}",
        is_terminal=phase in TERMINAL_PHASES,
        age_seconds=age,
        extra={k: v for k, v in data.items()
               if k not in ("version", "phase", "started_at", "updated_at", "history")},
    )


def load_deploys(deploys_dir: Path) -> list[DeployRecord]:
    """Load every deploys/*.state.json and validate."""
    if not deploys_dir.exists():
        return []
    out = []
    for f in sorted(deploys_dir.glob("*.state.json")):
        record = parse_state_file(f)
        if record:
            out.append(record)
    # Sort: active first, then by most-recently-updated
    out.sort(key=lambda r: (r.is_terminal, -r.age_seconds))
    return out


def summarize(deploys: Iterable[DeployRecord]) -> dict:
    """Group deploys by phase + terminal/active. Useful for /api/deploys.json."""
    by_phase: dict[str, int] = {p: 0 for p in PHASES}
    active = 0
    terminal = 0
    illegal = 0
    for d in deploys:
        if d.phase in by_phase:
            by_phase[d.phase] += 1
        if d.is_terminal:
            terminal += 1
        else:
            active += 1
        if not d.is_legal:
            illegal += 1
    return {
        "total": sum(by_phase.values()),
        "active": active,
        "terminal": terminal,
        "illegal": illegal,
        "by_phase": by_phase,
    }
