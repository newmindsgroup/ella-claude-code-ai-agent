#!/usr/bin/env bash
# install-memory-timers.sh — installs memory-extract and memory-consolidate systemd timers
# Must be run as root (or with sudo)
#
# Usage: sudo bash {{TENANT_AGENT_HOME}}/scripts/install-memory-timers.sh

set -euo pipefail

[[ "$(id -u)" != "0" ]] && { echo "Run as root: sudo bash $0" >&2; exit 1; }

SRC="{{TENANT_AGENT_HOME}}/daniel-personal-brand/vps-setup/agents-config/{{TENANT_LINUX_USER}}/systemd"
DEST="/etc/systemd/system"

for f in memory-extract.service memory-extract.timer memory-consolidate.service memory-consolidate.timer; do
  cp "$SRC/$f" "$DEST/$f"
  echo "  installed $f"
done

systemctl daemon-reload

systemctl enable --now memory-extract.timer
systemctl enable --now memory-consolidate.timer

echo ""
echo "Done. Timers active:"
systemctl status memory-extract.timer memory-consolidate.timer --no-pager | grep -E "Active|Trigger"
