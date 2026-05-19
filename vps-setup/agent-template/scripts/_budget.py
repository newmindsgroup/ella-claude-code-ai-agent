"""
_budget.py — Hard cost guardrails for autonomous skills (v2.57.0).

Rules-engine alerts are nice; they tell you a budget is breached. They don't
*prevent* the next run. v2.57.0 adds a refuse-to-run state file that
skill-runner.sh + FastAPI consult before launching anything.

State file: state/budget-blocked.json
Schema:
    {
        "<skill_name>": {
            "reason":   "daily cap $2 reached",
            "until_ts": "2026-05-19T23:59:59Z",
            "blocked_by": "rule-engine|manual|api",
            "set_at":   "2026-05-19T14:23:00Z"
        },
        "__global__": { ... }   # special key = blocks everything
    }

Entries automatically expire when `until_ts` passes — auto_expire() runs on
every load_blocked() call so callers always see a clean view.

Failure-mode philosophy: if the JSON is corrupt, fail OPEN (no blocks) and
log loudly. We'd rather a runaway agent than a stuck mission control.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional

AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

BLOCK_PATH = Path(AGENT_HOME) / "state" / "budget-blocked.json"

GLOBAL_KEY = "__global__"


@dataclass
class BlockedState:
    skill: str
    reason: str
    until_ts: str
    blocked_by: str = "manual"
    set_at: str = ""

    @property
    def is_global(self) -> bool:
        return self.skill == GLOBAL_KEY

    @property
    def is_expired(self) -> bool:
        if not self.until_ts:
            return False
        try:
            until = datetime.fromisoformat(self.until_ts.replace("Z", "+00:00"))
            return datetime.now(timezone.utc) >= until
        except (ValueError, TypeError):
            return True  # malformed timestamp = treat as expired (fail-open)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _ensure_dir() -> None:
    BLOCK_PATH.parent.mkdir(parents=True, exist_ok=True)


def _read_raw() -> dict:
    try:
        with BLOCK_PATH.open() as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        return data
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _write_raw(data: dict) -> None:
    _ensure_dir()
    tmp = BLOCK_PATH.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    tmp.replace(BLOCK_PATH)


def auto_expire() -> int:
    """Remove blocks whose until_ts has passed. Returns count removed."""
    data = _read_raw()
    if not data:
        return 0
    removed = 0
    out = {}
    for k, v in data.items():
        if not isinstance(v, dict):
            continue
        bs = BlockedState(skill=k, **{kk: vv for kk, vv in v.items() if kk in ("reason", "until_ts", "blocked_by", "set_at")})
        if bs.is_expired:
            removed += 1
            continue
        out[k] = v
    if removed:
        _write_raw(out)
    return removed


def load_blocked() -> list[BlockedState]:
    auto_expire()
    data = _read_raw()
    out = []
    for k, v in data.items():
        if not isinstance(v, dict):
            continue
        out.append(BlockedState(
            skill=k,
            reason=v.get("reason", ""),
            until_ts=v.get("until_ts", ""),
            blocked_by=v.get("blocked_by", "manual"),
            set_at=v.get("set_at", ""),
        ))
    return out


def is_blocked(skill_name: str) -> Optional[BlockedState]:
    """Returns the BlockedState if `skill_name` (or global) is currently
    blocked. Returns None if free to run."""
    blocks = load_blocked()
    # Global block trumps everything
    for b in blocks:
        if b.is_global and not b.is_expired:
            return b
    for b in blocks:
        if b.skill == skill_name and not b.is_expired:
            return b
    return None


def block(skill_name: str, reason: str, duration_hours: int = 24,
          blocked_by: str = "manual") -> BlockedState:
    """Block a skill (or __global__) for N hours. Re-blocking extends the
    deadline — never shortens it."""
    until = datetime.now(timezone.utc) + timedelta(hours=duration_hours)
    until_ts = until.isoformat().replace("+00:00", "Z")

    data = _read_raw()
    existing = data.get(skill_name) or {}
    # Extend-only: never shorten an existing block
    if existing.get("until_ts"):
        try:
            existing_until = datetime.fromisoformat(existing["until_ts"].replace("Z", "+00:00"))
            if existing_until > until:
                until = existing_until
                until_ts = existing["until_ts"]
        except (ValueError, TypeError):
            pass

    entry = {
        "reason": reason,
        "until_ts": until_ts,
        "blocked_by": blocked_by,
        "set_at": existing.get("set_at") or _now_iso(),
    }
    data[skill_name] = entry
    _write_raw(data)
    return BlockedState(skill=skill_name, **entry)


def unblock(skill_name: str) -> bool:
    """Manually clear a block. Returns True if anything was removed."""
    data = _read_raw()
    if skill_name in data:
        del data[skill_name]
        _write_raw(data)
        return True
    return False


def block_global(reason: str, duration_hours: int = 24, blocked_by: str = "manual") -> BlockedState:
    """Block every skill. Useful for kill-switch scenarios."""
    return block(GLOBAL_KEY, reason, duration_hours, blocked_by)
