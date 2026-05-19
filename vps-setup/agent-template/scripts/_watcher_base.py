"""
_watcher_base.py — Shared base class for Mission Control proactive watchers.

Six watchers (disk-space, task-deadline, goal-deadline, stalled-deal, hot-lead-
inbox, calendar-conflict) all reinvent the same pattern in bash:
  1. Gather signals from some data source
  2. Per-signal dedup against a JSONL log of past notifications
  3. Per-signal throttle window (don't refire within N seconds)
  4. Post to Telegram via tg-send.sh
  5. Append the fired notification to the dedup log

Each bash watcher is ~100 lines and most of that is dedup bookkeeping +
Telegram posting boilerplate. v2.52.0 lifts that into Python so:
  - Each new watcher is 30 lines, not 100
  - Dedup logic is tested centrally (pytest)
  - Telegram posting paths are unified (one place to fix bugs)
  - Audit events post to /api/chat/audit automatically

To migrate a bash watcher:
  1. Subclass BaseWatcher
  2. Implement gather_signals() — return a list of Signal objects
  3. Optional override: dedup_key, throttle_seconds, format_telegram
  4. Replace the bash systemd ExecStart with the new Python entrypoint
  5. Keep the .sh in place as fallback during the migration window
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

NUDGE_DIR = Path(AGENT_HOME) / "notifications"
TG_SEND = Path(AGENT_HOME) / "scripts" / "tg-send.sh"
AUDIT_URL = "http://127.0.0.1:8001/api/chat/audit"


@dataclass
class Signal:
    """One actionable observation from a watcher.

    Attributes:
        dedup_key: stable identifier used for throttle bookkeeping. Two signals
            with the same dedup_key within `throttle_seconds` are considered
            duplicates; only the first fires.
        message: Telegram text (plain — tg-send.sh wraps as needed).
        throttle_seconds: minimum interval between fires for this dedup_key.
            Defaults to 24h.
        severity: free-form tag for logging / audit. Conventions: "info",
            "warning", "critical".
        details: arbitrary metadata for audit log + future ML features.
    """
    dedup_key: str
    message: str
    throttle_seconds: int = 86400
    severity: str = "info"
    details: dict = field(default_factory=dict)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(d: datetime) -> str:
    return d.isoformat().replace("+00:00", "Z")


class BaseWatcher:
    """Subclass and implement gather_signals(). The base class handles
    dedup, throttling, posting, logging, and audit event emission."""

    # Subclasses MUST set name (used for log filename + audit action prefix)
    name: str = ""

    def __init__(self):
        if not self.name:
            raise RuntimeError(f"{self.__class__.__name__} must set `name`")
        self.nudge_log = NUDGE_DIR / f"{self.name}-nudges.jsonl"
        NUDGE_DIR.mkdir(parents=True, exist_ok=True)
        self.nudge_log.touch()

    # ------------------------------------------------------------------ API
    def gather_signals(self) -> list[Signal]:
        """Override: return a list of Signals. Empty list = nothing to fire."""
        raise NotImplementedError

    # ------------------------------------------------------------ Dedup IO
    def _load_history(self) -> list[dict]:
        out = []
        try:
            with self.nudge_log.open() as f:
                for line in f:
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        continue
        except FileNotFoundError:
            pass
        return out

    def _last_fired_at(self, dedup_key: str, history: list[dict]) -> datetime | None:
        # Newest-first scan (history is append-only chronological)
        for entry in reversed(history):
            if entry.get("dedup_key") == dedup_key:
                ts = entry.get("ts")
                if ts:
                    try:
                        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except Exception:
                        continue
        return None

    def _is_throttled(self, signal: Signal, history: list[dict], now: datetime) -> bool:
        last = self._last_fired_at(signal.dedup_key, history)
        if last is None:
            return False
        elapsed = (now - last).total_seconds()
        return elapsed < signal.throttle_seconds

    def _append_history(self, signal: Signal, fired_at: datetime, telegram_ok: bool) -> None:
        entry = {
            "ts": _iso(fired_at),
            "dedup_key": signal.dedup_key,
            "severity": signal.severity,
            "telegram_ok": telegram_ok,
            "details": signal.details,
        }
        with self.nudge_log.open("a") as f:
            f.write(json.dumps(entry) + "\n")

    # ---------------------------------------------------------- Posting
    def _post_telegram(self, message: str) -> bool:
        if not TG_SEND.exists():
            sys.stderr.write(f"WARN: tg-send.sh missing at {TG_SEND}\n")
            return False
        try:
            r = subprocess.run(
                [str(TG_SEND), "send", "--text", message],
                capture_output=True, text=True, timeout=20,
            )
            return r.returncode == 0
        except Exception as e:
            sys.stderr.write(f"telegram post failed: {e}\n")
            return False

    def _post_audit(self, signal: Signal, fired: bool, telegram_ok: bool) -> None:
        body = {
            "action": f"watcher-{self.name}-" + ("fired" if fired else "throttled"),
            "target": signal.dedup_key,
            "details": {
                "severity": signal.severity,
                "telegram_ok": telegram_ok,
                "throttle_seconds": signal.throttle_seconds,
                **{k: v for k, v in signal.details.items() if isinstance(v, (int, float, str, bool))},
            },
            "source": "watcher",
        }
        try:
            req = urllib.request.Request(
                AUDIT_URL, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"}, method="POST",
            )
            urllib.request.urlopen(req, timeout=5).close()
        except Exception:
            pass  # audit best-effort

    # ----------------------------------------------------------- Main run
    def run(self) -> dict:
        """Execute the watcher cycle: gather → dedup-check → post → log → audit.
        Returns a summary dict for systemd journal."""
        now = _now()
        signals = self.gather_signals()
        history = self._load_history()

        fired = 0
        throttled = 0
        failed = 0
        results = []

        for sig in signals:
            if self._is_throttled(sig, history, now):
                throttled += 1
                self._post_audit(sig, fired=False, telegram_ok=False)
                results.append({"dedup_key": sig.dedup_key, "fired": False, "throttled": True})
                continue

            ok = self._post_telegram(sig.message)
            if ok:
                fired += 1
                self._append_history(sig, now, telegram_ok=True)
                self._post_audit(sig, fired=True, telegram_ok=True)
            else:
                failed += 1
                # Log the failed attempt but don't append to history (so a
                # transient Telegram outage retries on the next tick).
                sys.stderr.write(f"FAIL post for {sig.dedup_key}\n")
            results.append({"dedup_key": sig.dedup_key, "fired": ok, "throttled": False})

        summary = {
            "watcher": self.name,
            "ts": _iso(now),
            "signals_gathered": len(signals),
            "fired": fired,
            "throttled": throttled,
            "failed": failed,
        }
        print(f"watcher-{self.name}: {len(signals)} signals · "
              f"{fired} fired · {throttled} throttled · {failed} failed")
        for r in results:
            status = "FIRED" if r["fired"] else ("throttled" if r["throttled"] else "FAIL")
            print(f"  {status:>10s}  {r['dedup_key']}")
        return summary
