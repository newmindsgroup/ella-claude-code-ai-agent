#!/usr/bin/env bash
# ops-systemd-install-unit.sh <src-path> <unit-name>
#
# Copies a rendered systemd unit file from an agent-managed location
# into /etc/systemd/system/, runs daemon-reload, and (if the unit is a
# .timer) enables it.
#
# CALLED VIA SUDO:
#   sudo {{TENANT_AGENT_HOME}}/scripts/ops/ops-systemd-install-unit.sh \
#     {{TENANT_AGENT_HOME}}/daniel-personal-brand/vps-setup/agents-config/{{TENANT_LINUX_USER}}/systemd/foo.timer \
#     foo.timer
#
# Src path must live UNDER {{TENANT_AGENT_HOME}}/ (strict — refuses
# arbitrary file copies into /etc/systemd/system/).
# Unit name must end with .service or .timer.
set -euo pipefail

AUDIT_LOG=/var/log/{{TENANT_LINUX_USER}}-agent-ops.log

SRC="${1:-}"
NAME="${2:-}"
[[ -z "$SRC" || -z "$NAME" ]] && { echo "usage: $0 <src-path> <unit-name>" >&2; exit 1; }

# Validate
case "$SRC" in
  {{TENANT_AGENT_HOME}}/*) ;;
  *) echo "ERROR: src must be under {{TENANT_AGENT_HOME}}/ (got: $SRC)" >&2; exit 2 ;;
esac

case "$NAME" in
  *.service|*.timer) ;;
  *) echo "ERROR: unit name must end with .service or .timer (got: $NAME)" >&2; exit 3 ;;
esac

[[ ! -f "$SRC" ]] && { echo "ERROR: $SRC not found" >&2; exit 4; }

audit() { echo "[$(date -u +%FT%TZ)] [systemd-install] $*" | tee -a "$AUDIT_LOG"; }

audit "installing $SRC → /etc/systemd/system/$NAME"
cp "$SRC" "/etc/systemd/system/$NAME"
chmod 644 "/etc/systemd/system/$NAME"

audit "running: systemctl daemon-reload"
systemctl daemon-reload

# Auto-enable timers (they need to be in timers.target.wants/ to fire)
if [[ "$NAME" == *.timer ]]; then
  audit "auto-enabling timer $NAME"
  systemctl enable --now "$NAME"
fi

audit "installed $NAME"
