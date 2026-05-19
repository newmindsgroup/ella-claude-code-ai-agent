#!/usr/bin/env python3
"""
disk-space-watcher.py — v2.52.0 Python port of disk-space-watcher.sh.

First migration to BaseWatcher. Behaviorally equivalent to the bash version:
  - Same default thresholds (75% yellow, 85% orange, 95% red)
  - Same windowed dedup keys (mount + threshold + time-bucket)
  - Same Telegram message format
  - Same mount selection (real filesystems, > 1 GB)

The bash version stays in place during the transition window. systemd unit
flipped to call this Python version; if anything breaks, flip the unit back.

Tunable via env vars (same names as bash):
  DISK_YELLOW_PCT (default 75) — info nudge once per ISO week
  DISK_ORANGE_PCT (default 85) — actionable once per day
  DISK_RED_PCT    (default 95) — urgent once per hour
  WATCH_MOUNTS                  — space-separated overrides

Usage:  /usr/bin/python3 /opt/agent/scripts/disk-space-watcher.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Allow importing the sibling module when run from systemd (no PYTHONPATH set)
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _watcher_base import BaseWatcher, Signal  # noqa: E402


YELLOW_PCT = int(os.getenv("DISK_YELLOW_PCT", "75"))
ORANGE_PCT = int(os.getenv("DISK_ORANGE_PCT", "85"))
RED_PCT = int(os.getenv("DISK_RED_PCT", "95"))

# Filesystems that aren't worth watching (tmpfs, container layers, etc.)
SKIP_FSTYPES = {"tmpfs", "devtmpfs", "overlay", "squashfs", "fuse.snapfuse",
                "proc", "sysfs", "cgroup", "cgroup2", "ramfs"}


def _list_mounts() -> list[str]:
    override = os.getenv("WATCH_MOUNTS", "").strip()
    if override:
        return override.split()

    # Parse `df` output. Use --output for stable columns; -B1 for byte sizes.
    try:
        out = subprocess.run(
            ["df", "-B1", "--output=target,fstype,size"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        mounts = []
        for line in out.stdout.splitlines()[1:]:  # skip header
            parts = line.split()
            if len(parts) < 3:
                continue
            target, fstype = parts[0], parts[1]
            try:
                size = int(parts[2])
            except ValueError:
                continue
            if fstype in SKIP_FSTYPES:
                continue
            if size < 1_073_741_824:  # < 1 GiB
                continue
            mounts.append(target)
        return sorted(set(mounts))
    except Exception as e:
        sys.stderr.write(f"df failed: {e}\n")
        return []


def _disk_stats(mount: str) -> dict | None:
    try:
        s = shutil.disk_usage(mount)
        used_pct = round((s.used / s.total) * 100) if s.total else 0
        return {
            "mount": mount,
            "used_pct": used_pct,
            "total_gb": round(s.total / 1_073_741_824, 1),
            "used_gb": round(s.used / 1_073_741_824, 1),
            "avail_gb": round(s.free / 1_073_741_824, 1),
        }
    except (OSError, FileNotFoundError):
        return None


def _format_message(stats: dict, threshold: str, emoji: str) -> str:
    return (
        f"{emoji} Disk {threshold} — {stats['used_pct']}% full\n\n"
        f"Mount: {stats['mount']}\n"
        f"Used: {stats['used_gb']}G of {stats['total_gb']}G ({stats['avail_gb']}G available)\n\n"
        f"Top offenders (run on host):\n"
        f"  du -sh /opt/* 2>/dev/null | sort -h | tail -5\n"
        f"  du -sh /var/log/* 2>/dev/null | sort -h | tail -5"
    )


class DiskSpaceWatcher(BaseWatcher):
    name = "disk-space"

    def gather_signals(self) -> list[Signal]:
        now = datetime.now(timezone.utc)
        today = now.strftime("%Y-%m-%d")
        this_hour = now.strftime("%Y-%m-%dT%H")
        # ISO week (year-week)
        year, week, _ = now.isocalendar()
        this_week = f"{year}-W{week:02d}"

        signals = []
        for mount in _list_mounts():
            stats = _disk_stats(mount)
            if stats is None:
                continue

            pct = stats["used_pct"]
            if pct >= RED_PCT:
                threshold, emoji, bucket = "red", "🚨", this_hour
                throttle = 3600  # 1 hour
            elif pct >= ORANGE_PCT:
                threshold, emoji, bucket = "orange", "⚠️", today
                throttle = 86400  # 1 day
            elif pct >= YELLOW_PCT:
                threshold, emoji, bucket = "yellow", "ℹ️", this_week
                throttle = 7 * 86400  # 1 week
            else:
                continue

            signals.append(Signal(
                dedup_key=f"{mount}:{threshold}:{bucket}",
                message=_format_message(stats, threshold, emoji),
                throttle_seconds=throttle,
                severity={"yellow": "info", "orange": "warning", "red": "critical"}[threshold],
                details={
                    "mount": mount,
                    "used_pct": pct,
                    "threshold": threshold,
                    "total_gb": stats["total_gb"],
                    "avail_gb": stats["avail_gb"],
                },
            ))
        return signals


if __name__ == "__main__":
    sys.exit(0 if DiskSpaceWatcher().run() else 1)
