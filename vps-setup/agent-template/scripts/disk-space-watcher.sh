#!/usr/bin/env bash
# disk-space-watcher.sh — proactive Telegram nudge when a disk crosses
# usage thresholds. Runs locally against this VPS for now; same script
# can be repointed at a remote host via SSH (see "remote check" below).
#
# Why: The agent stack runs on this VPS. If /opt fills up, agents stop.
# The whisper.cpp models alone are ~500MB; bun-cache + claude-cache +
# WordPress sites elsewhere can compound. Catching disk pressure at 85%
# gives lead time to clean up; 95% is the no-more-warnings threshold.
#
# Mounts watched (default): all real filesystems (no tmpfs, devtmpfs).
# Override with WATCH_MOUNTS env var (space-separated paths).
#
# Thresholds:
#   yellow  — 75% — info-level nudge once per ISO week
#   orange  — 85% — actionable nudge once per day
#   red     — 95% — urgent nudge once per hour, max 3 per day
#
# Each (mount, threshold) pair gets its own dedup key so crossing back
# under a threshold (e.g. cleanup) and back over does NOT re-fire within
# the same window — by design, prevents flap-spam.
#
# Dedup at {{TENANT_AGENT_HOME}}/notifications/disk-space-nudges.jsonl
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/disk-space-nudges.jsonl"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$NUDGE_LOG")"
touch "$NUDGE_LOG"

[[ ! -x "$TG_SEND" ]] && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

# Tunables
YELLOW_PCT="${DISK_YELLOW_PCT:-75}"
ORANGE_PCT="${DISK_ORANGE_PCT:-85}"
RED_PCT="${DISK_RED_PCT:-95}"

now_epoch=$(date -u +%s)
today=$(date -u +%Y-%m-%d)
this_hour=$(date -u +%Y-%m-%dT%H)
this_week=$(date -u +%G-W%V)

# Build the mount list. Default: all rw, non-tmpfs, mounted filesystems
# with capacity > 1GB. Excludes overlayfs from docker, snap mounts.
if [[ -z "${WATCH_MOUNTS:-}" ]]; then
  mapfile -t MOUNTS < <(df -B1 --output=target,fstype,size 2>/dev/null \
    | tail -n +2 \
    | awk '$2 !~ /^(tmpfs|devtmpfs|overlay|squashfs|fuse\.snapfuse)$/ && $3 > 1073741824 { print $1 }' \
    | sort -u)
else
  # shellcheck disable=SC2206
  MOUNTS=( $WATCH_MOUNTS )
fi

nudged_this_run=0

for mount in "${MOUNTS[@]}"; do
  # Use df -BM for MiB units, --output for stable column shape.
  read -r mount_path used_pct <<< "$(df --output=target,pcent "$mount" 2>/dev/null | tail -1 | awk '{print $1, $2}')"
  used_pct="${used_pct%\%}"
  [[ -z "$used_pct" ]] && continue

  # Pick the most-severe threshold crossed
  threshold=""
  emoji=""
  cooldown_key=""
  if   [[ $used_pct -ge $RED_PCT ]];    then threshold="red";    emoji="🚨"; cooldown_key="$mount:red:$this_hour"
  elif [[ $used_pct -ge $ORANGE_PCT ]]; then threshold="orange"; emoji="⚠️"; cooldown_key="$mount:orange:$today"
  elif [[ $used_pct -ge $YELLOW_PCT ]]; then threshold="yellow"; emoji="ℹ️"; cooldown_key="$mount:yellow:$this_week"
  else continue
  fi

  # Already nudged for this (mount, threshold, window)?
  if grep -q "\"$cooldown_key\"" "$NUDGE_LOG"; then
    continue
  fi

  # Get human-readable size info
  read -r total used avail <<< "$(df -BG --output=size,used,avail "$mount" 2>/dev/null | tail -1 | awk '{print $1, $2, $3}')"

  msg=$(printf "%s Disk %s — %s%% full\n\nMount: %s\nUsed: %s of %s (%s available)\n\nTop offenders (run on host):\n  du -sh /opt/* 2>/dev/null | sort -h | tail -5\n  du -sh /var/log/* 2>/dev/null | sort -h | tail -5" \
    "$emoji" "$threshold" "$used_pct" "$mount_path" "$used" "$total" "$avail")

  if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
    printf '{"key":"%s","sent_at":"%s","mount":"%s","used_pct":%d,"threshold":"%s"}\n' \
      "$cooldown_key" "$(date -u +%FT%TZ)" "$mount_path" "$used_pct" "$threshold" \
      >> "$NUDGE_LOG"
    nudged_this_run=$((nudged_this_run + 1))
  fi
done

echo "disk-space-watcher: $nudged_this_run nudges sent at $(date -u +%FT%TZ) — checked ${#MOUNTS[@]} mounts"
