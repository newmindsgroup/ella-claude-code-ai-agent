#!/usr/bin/env bash
# ops-nginx-reload.sh — validate + reload nginx after a vhost edit.
#
# CALLED VIA SUDO:
#   sudo {{TENANT_AGENT_HOME}}/scripts/ops/ops-nginx-reload.sh
#
# Always runs `nginx -t` first. If config is invalid, refuses to reload
# and exits non-zero. On success, runs `systemctl reload nginx` (zero
# downtime — nginx workers swap gracefully).
set -euo pipefail

AUDIT_LOG=/var/log/{{TENANT_LINUX_USER}}-agent-ops.log
TG_SEND={{TENANT_AGENT_HOME}}/scripts/tg-send.sh

audit() { echo "[$(date -u +%FT%TZ)] [nginx-reload] $*" | tee -a "$AUDIT_LOG"; }

audit "validating nginx config (nginx -t)"
TEST_OUT=$(nginx -t 2>&1)
if [[ $? -ne 0 ]]; then
  audit "FATAL: nginx -t failed: $TEST_OUT"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 nginx config INVALID — refusing to reload. Error: ${TEST_OUT:0:200}" 2>/dev/null || true
  exit 1
fi
audit "nginx config valid"

audit "running: systemctl reload nginx"
if ! systemctl reload nginx; then
  audit "FATAL: nginx reload failed"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 nginx reload FAILED. Check journalctl -u nginx" 2>/dev/null || true
  exit 2
fi

audit "nginx reloaded successfully"
sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "✅ nginx config validated + reloaded (zero downtime)." 2>/dev/null || true
