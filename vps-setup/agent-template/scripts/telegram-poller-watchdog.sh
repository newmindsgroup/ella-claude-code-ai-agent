#!/usr/bin/env bash
# telegram-poller-watchdog.sh — restart claude-agent.service if its --channels
# Telegram poller has silently wedged.
#
# Closes the silent-wedge gap surfaced during v2.20.0 deploy: the Claude CLI
# process stayed alive but the bun-based grammy poller sub-process disappeared
# from the cgroup, so Telegram messages were marked read but never reached the
# agent prompt. {{TENANT_PERSON_FIRST_NAME}} sent "what's on my plate today?" and got nothing back.
#
# Detection: the agent's cgroup MUST contain a process whose command line
# matches "bun run --cwd .*claude-plugins-official/telegram". If not, the
# poller has died.
#
# Recovery: systemctl restart claude-agent.service, wait 30s, re-check. If
# still absent, escalate via Telegram (assuming OUTBOUND tg-send still works
# even when the inbound poller is dead — the bot API connection is per-call,
# not persistent) and exit non-zero so systemd marks this watchdog run as
# failed for visibility.
#
# Runs every 5 min via telegram-poller-watchdog.timer.

set -uo pipefail

LOG_FILE="/var/log/{{TENANT_LINUX_USER}}-telegram-watchdog.log"
HISTORY_FILE="/var/lib/{{TENANT_LINUX_USER}}/watchdog-restart-history.txt"
SERVICE="claude-agent.service"
TG_SEND="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"

# Circuit breaker: if the watchdog has restarted $SERVICE >=N times in the last
# WINDOW seconds, suspend further restarts and escalate. Protects against an
# unbounded restart loop when the underlying bun-death root cause hasn't been
# fixed yet (each restart costs ~$0.07 in CLAUDE.md cache rewrite).
RESTART_THRESHOLD=3
RESTART_WINDOW_SEC=$((30 * 60))   # 30 minutes
HISTORY_CAP=100                   # keep state file bounded

# Match any "bun run" process whose command references the telegram plugin path.
# The actual command line is something like:
#   bun run --cwd /opt/.../claude-plugins-official/telegram/0.0.6 --shell=bun --silent start
POLLER_RE='bun run.*claude-plugins-official/telegram'

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE" >&2
}

# True if the poller is in $SERVICE's cgroup.
poller_alive() {
  # systemctl status -- the CGroup block lists every PID under the service.
  systemctl status --no-pager -l "$SERVICE" 2>/dev/null | grep -qE "$POLLER_RE"
}

# Count restart timestamps in $HISTORY_FILE that fall within the last
# $RESTART_WINDOW_SEC seconds. Tolerant of missing/empty file.
count_recent_restarts() {
  [[ -f "$HISTORY_FILE" ]] || { echo 0; return; }
  local now_epoch cutoff_epoch ts ts_epoch count
  now_epoch=$(date +%s)
  cutoff_epoch=$((now_epoch - RESTART_WINDOW_SEC))
  count=0
  while IFS= read -r ts; do
    [[ -z "$ts" ]] && continue
    ts_epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
    [[ $ts_epoch -ge $cutoff_epoch ]] && count=$((count+1))
  done < "$HISTORY_FILE"
  echo "$count"
}

# Append a restart timestamp + cap the file to prevent unbounded growth.
record_restart() {
  mkdir -p "$(dirname "$HISTORY_FILE")"
  date -u +%FT%TZ >> "$HISTORY_FILE"
  if [[ $(wc -l < "$HISTORY_FILE") -gt $HISTORY_CAP ]]; then
    tail -n "$HISTORY_CAP" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && \
      mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
  fi
}

# v2.23.0: capture a diagnostic snapshot when bun-death is detected. Goal is
# to accumulate 7+ days of evidence about WHY bun keeps dying — currently
# masked by the watchdog. Each death gets one block in the diagnostics log;
# eventually a pattern emerges (OOM kill, network timeout, signal from parent,
# etc.) that points at the real fix.
DIAG_FILE="/var/log/{{TENANT_LINUX_USER}}-bun-death-diagnostics.log"
DIAG_CAP_LINES=20000   # cap the diagnostics log too

capture_bun_death_diagnostics() {
  # If this fails (e.g. no write access to /var/log) silently fall back to
  # /tmp — better to have the data somewhere than nowhere.
  local target="$DIAG_FILE"
  if ! { : > "$target"; } 2>/dev/null && [[ ! -f "$target" ]]; then
    target="/tmp/bun-death-diagnostics.log"
  fi

  {
    echo "================================================================================"
    echo "[$(date -u +%FT%TZ)] bun-death detected; pre-restart snapshot"
    echo "================================================================================"
    echo "--- claude-agent.service status ---"
    systemctl status --no-pager -l "$SERVICE" 2>&1 | head -20
    echo ""
    echo "--- last 50 journal lines for $SERVICE ---"
    journalctl -u "$SERVICE" -n 50 --no-pager 2>&1 || echo "(journalctl unavailable)"
    echo ""
    echo "--- kernel ring buffer last 30 (OOM check) ---"
    if dmesg --since "10 minutes ago" 2>/dev/null | tail -30 | grep -q .; then
      dmesg --since "10 minutes ago" 2>/dev/null | tail -30
    else
      # kernel.dmesg_restrict=1 blocks dmesg even for root on some kernels.
      # journalctl -k pulls the same data via the journal subsystem.
      journalctl -k --since "10 minutes ago" -n 30 --no-pager 2>&1 | tail -30 || echo "(neither dmesg nor journalctl -k available)"
    fi
    echo ""
    echo "--- memory pressure ---"
    free -h 2>&1
    echo ""
    echo "--- top by RSS (bun + node + claude) ---"
    ps -eo pid,user,rss,vsz,cmd --sort=-rss 2>&1 | grep -E "bun|node|claude" | head -8
    echo ""
    echo "--- system load ---"
    uptime 2>&1
    echo ""
    echo "--- bun-related cgroup processes (should be empty since poller dead) ---"
    systemctl status --no-pager "$SERVICE" 2>/dev/null | grep -E "bun|node" || echo "(none)"
    echo ""
  } >> "$target" 2>&1

  # Cap diagnostics log to prevent unbounded growth.
  if [[ -f "$target" ]] && [[ $(wc -l < "$target") -gt $DIAG_CAP_LINES ]]; then
    tail -n $((DIAG_CAP_LINES / 2)) "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  fi
}

# Send the circuit-breaker alert via Telegram.
escalate_circuit_breaker() {
  local recent="$1"
  if [[ ! -x "$TG_SEND" ]]; then
    log "tg-send not executable — cannot send circuit breaker alert"
    return
  fi
  runuser -u {{TENANT_LINUX_USER}} -- bash "$TG_SEND" send --md --text \
    "🚨 *Watchdog circuit breaker tripped\.* Telegram poller has died ${recent}\+ times in 30 min\. Auto\-restart suspended\. Manual investigation required \— most likely bun process dying for a separate reason\. Run: \`journalctl \-u claude\-agent\.service \-\-since \"30 min ago\"\` to investigate\." \
    || log "tg-send circuit-breaker escalation FAILED — manual intervention needed urgently"
}

main() {
  if ! systemctl is-active --quiet "$SERVICE"; then
    log "$SERVICE not active — out of scope for the poller watchdog (claude-agent itself is down)"
    exit 0
  fi

  if poller_alive; then
    # Healthy. Silent exit so journalctl stays quiet on the ~288 daily runs.
    exit 0
  fi

  # Circuit breaker check — bypass with WATCHDOG_FORCE_RESTART=1 for manual
  # operator override (e.g. after fixing the root cause and clearing history).
  if [[ "${WATCHDOG_FORCE_RESTART:-}" != "1" ]]; then
    local recent
    recent=$(count_recent_restarts)
    if [[ $recent -ge $RESTART_THRESHOLD ]]; then
      log "circuit breaker TRIPPED — $recent restarts in last 30 min, suggesting recurring bun-death root cause; NOT restarting"
      escalate_circuit_breaker "$recent"
      # Non-zero so systemd marks this watchdog run failed for visibility.
      exit 1
    fi
  fi

  # Record BEFORE restarting — if the script crashes mid-restart (OOM, TERM,
  # etc.) we still want this attempt to count toward the breaker threshold.
  record_restart

  # v2.23.0: capture diagnostic snapshot BEFORE the restart so 7+ days of
  # observation builds a real picture of why bun keeps dying. Without this,
  # each death is invisible — the watchdog "fixes" it before anyone can see
  # why. Append-only log; tail it after a week.
  capture_bun_death_diagnostics

  log "Telegram poller absent in $SERVICE cgroup — restarting service"
  systemctl restart "$SERVICE"
  sleep 30

  if poller_alive; then
    log "Telegram poller restored after restart"
    exit 0
  fi

  log "Telegram poller STILL absent 30s after restart — escalating"
  if [[ -x "$TG_SEND" ]]; then
    runuser -u {{TENANT_LINUX_USER}} -- bash "$TG_SEND" send --md --text \
      "*Watchdog alert*\: \`$SERVICE\` restarted but Telegram poller still absent\. Manual intervention needed\." \
      || log "tg-send escalation also failed"
  fi
  # Non-zero exit so systemd marks this watchdog run as failed and the timer's
  # next-run UI flags it. Don't keep restarting in a loop — manual intervention
  # is the right move at this point.
  exit 1
}

main
