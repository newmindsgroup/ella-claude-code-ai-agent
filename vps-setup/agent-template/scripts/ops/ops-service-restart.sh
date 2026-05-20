#!/usr/bin/env bash
# ops-service-restart.sh <service-name> — restart any agent-managed systemd
# service. Strict allowlist; refuses unknown service names.
#
# Used for: claude-agent, {{TENANT_LINUX_USER}}-web, nginx, dashboard-chat, any watcher.
# NOT for: ssh, cron, anything system-critical outside the agent stack.
#
# CALLED VIA SUDO:
#   sudo {{TENANT_AGENT_HOME}}/scripts/ops/ops-service-restart.sh <name>
set -euo pipefail

AUDIT_LOG=/var/log/{{TENANT_LINUX_USER}}-agent-ops.log
TG_SEND={{TENANT_AGENT_HOME}}/scripts/tg-send.sh

SVC="${1:-}"
[[ -z "$SVC" ]] && { echo "usage: $0 <service-name> [--no-block]" >&2; exit 1; }

# v2.47.1: optional --no-block returns immediately after systemd accepts the
# start request (vs the default blocking until ExecStart completes). Used by
# the FastAPI Run-now endpoint so dashboard buttons don't hit a 30s timeout
# on LLM-driven skills.
NO_BLOCK_FLAG=""
if [[ "${2:-}" == "--no-block" ]]; then
  NO_BLOCK_FLAG="--no-block"
fi

# Strict allowlist — exact match OR template-instance match for agent-skill@*
ALLOWED=(
  claude-agent
  dashboard-chat
  {{TENANT_LINUX_USER}}-web
  nginx
  morning-brief
  evening-rollup
  task-deadline-watcher
  goal-deadline-watcher
  stalled-deal-watcher
  disk-space-watcher
  hot-lead-inbox-watcher
  calendar-conflict-watcher
  graphify-rebuild
  telegram-poller-watchdog
  deploy-timeout-sweep
  telemetry-calc
  rules-engine
  anomaly-detect
  session-parser
  roi-digest
)

# Strip optional .service / .timer suffix for comparison
NORM="${SVC%.service}"
NORM="${NORM%.timer}"

OK=0
for a in "${ALLOWED[@]}"; do
  if [[ "$NORM" == "$a" ]]; then OK=1; break; fi
done
# Also allow agent-skill@<anything>
if [[ "$NORM" == agent-skill@* ]]; then OK=1; fi

if [[ $OK -eq 0 ]]; then
  echo "ERROR: service '$SVC' not in allowlist" >&2
  echo "Allowed: ${ALLOWED[*]} or agent-skill@*" >&2
  exit 2
fi

audit() { echo "[$(date -u +%FT%TZ)] [service-restart] $*" | tee -a "$AUDIT_LOG"; }

audit "restarting $SVC (allowlist match)"

# Pre-prune watchdog if restarting claude-agent (collision avoidance)
if [[ "$NORM" == "claude-agent" ]]; then
  sed -i "/$(date -u +%Y-%m-%dT%H)/d" /var/lib/{{TENANT_LINUX_USER}}/watchdog-restart-history.txt 2>/dev/null || true
  audit "pre-pruned watchdog history (claude-agent restart)"
fi

if ! systemctl restart $NO_BLOCK_FLAG "$SVC"; then
  audit "FATAL: restart of $SVC failed"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Service restart FAILED: $SVC" 2>/dev/null || true
  exit 3
fi

sleep 2
if ! systemctl is-active --quiet "$SVC"; then
  # Some oneshot services exit immediately and aren't "active" — check if they at least ran
  STATE=$(systemctl is-active "$SVC" 2>&1)
  audit "WARN: $SVC state after restart: $STATE (oneshot units exit, this can be OK)"
fi
audit "$SVC restart complete"
