"""
test_watchers.py — verify the BaseWatcher migration (v2.52.0).

These tests run locally without hitting the VPS — they import the watcher
module directly, monkeypatch the Telegram + audit paths, and verify the
dedup + throttle + signal-gathering logic.
"""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


# Import path setup — let pytest find the agent-template scripts even though
# they aren't on the default Python path.
REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))


@pytest.fixture
def tmp_watcher_dir(tmp_path, monkeypatch):
    """Redirect the watcher's notifications dir to a tempdir so tests don't
    pollute real state."""
    # Module not yet imported — set env-equivalents before import
    notif = tmp_path / "notifications"
    notif.mkdir()
    monkeypatch.setenv("WATCHER_TEST_NUDGE_DIR", str(notif))

    # Patch the module-level NUDGE_DIR constant after import
    import importlib
    import _watcher_base  # noqa
    importlib.reload(_watcher_base)
    monkeypatch.setattr(_watcher_base, "NUDGE_DIR", notif)
    return tmp_path


def _make_dummy_watcher(signals_to_return):
    """Make a one-shot dummy watcher class for testing the base behavior."""
    import _watcher_base
    Signal = _watcher_base.Signal

    class Dummy(_watcher_base.BaseWatcher):
        name = "test-dummy"
        def gather_signals(self):
            return [Signal(**s) for s in signals_to_return]

    return Dummy


def test_base_watcher_fires_first_signal(tmp_watcher_dir, monkeypatch):
    """A fresh signal with no history should fire."""
    fired = []
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_telegram",
                        lambda self, msg: fired.append(msg) or True)
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_audit",
                        lambda *a, **kw: None)

    Cls = _make_dummy_watcher([
        {"dedup_key": "x:hour-A", "message": "hello", "throttle_seconds": 3600},
    ])
    summary = Cls().run()
    assert summary["fired"] == 1
    assert summary["throttled"] == 0
    assert fired == ["hello"]


def test_base_watcher_throttles_duplicate(tmp_watcher_dir, monkeypatch):
    """Same dedup_key within throttle window should be skipped on second run."""
    fired = []
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_telegram",
                        lambda self, msg: fired.append(msg) or True)
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_audit",
                        lambda *a, **kw: None)

    Cls = _make_dummy_watcher([
        {"dedup_key": "x:hour-A", "message": "hello", "throttle_seconds": 3600},
    ])
    # First run fires
    Cls().run()
    # Second run should throttle (same dedup key, same hour)
    summary = Cls().run()
    assert summary["fired"] == 0
    assert summary["throttled"] == 1
    # Telegram only got the first message
    assert len(fired) == 1


def test_base_watcher_different_keys_both_fire(tmp_watcher_dir, monkeypatch):
    """Different dedup_keys should both fire."""
    fired = []
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_telegram",
                        lambda self, msg: fired.append(msg) or True)
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_audit",
                        lambda *a, **kw: None)

    Cls = _make_dummy_watcher([
        {"dedup_key": "x:A", "message": "a", "throttle_seconds": 3600},
        {"dedup_key": "x:B", "message": "b", "throttle_seconds": 3600},
    ])
    summary = Cls().run()
    assert summary["fired"] == 2
    assert summary["throttled"] == 0
    assert sorted(fired) == ["a", "b"]


def test_base_watcher_failed_telegram_not_logged(tmp_watcher_dir, monkeypatch):
    """When Telegram fails, the signal should NOT be added to history (so
    next run retries)."""
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_telegram",
                        lambda self, msg: False)  # simulate failure
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_audit",
                        lambda *a, **kw: None)

    Cls = _make_dummy_watcher([
        {"dedup_key": "x:flake", "message": "flake", "throttle_seconds": 3600},
    ])
    # First run fails to post
    s1 = Cls().run()
    assert s1["fired"] == 0
    assert s1["failed"] == 1
    # Second run with same dedup should still try (not throttled, because
    # history was not appended on failure)
    monkeypatch.setattr("_watcher_base.BaseWatcher._post_telegram",
                        lambda self, msg: True)  # now Telegram is back
    s2 = Cls().run()
    assert s2["fired"] == 1


def test_disk_space_watcher_thresholds(tmp_watcher_dir, monkeypatch):
    """DiskSpaceWatcher picks the most-severe threshold crossed."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "disk_space_watcher",
        SCRIPTS_DIR / "disk-space-watcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # The freshly-imported module pulls `_watcher_base` into its own namespace.
    # Re-monkeypatch NUDGE_DIR on that reference (tmp_watcher_dir's monkeypatch
    # acted on the test-module's import, not mod's).
    monkeypatch.setattr(mod._watcher_base if hasattr(mod, "_watcher_base") else sys.modules["_watcher_base"],
                        "NUDGE_DIR", tmp_watcher_dir / "notifications")

    # Mock the mount + stats lookups
    monkeypatch.setattr(mod, "_list_mounts", lambda: ["/test-mount"])
    # 92% used should trigger ORANGE
    monkeypatch.setattr(mod, "_disk_stats", lambda m: {
        "mount": "/test-mount", "used_pct": 92,
        "total_gb": 100.0, "used_gb": 92.0, "avail_gb": 8.0,
    })
    w = mod.DiskSpaceWatcher()
    signals = w.gather_signals()
    assert len(signals) == 1
    assert "orange" in signals[0].dedup_key
    assert signals[0].severity == "warning"
    assert "92% full" in signals[0].message
