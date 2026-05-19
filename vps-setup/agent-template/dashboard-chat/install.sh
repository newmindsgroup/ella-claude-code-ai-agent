#!/usr/bin/env bash
# install.sh — bootstrap the dashboard-chat backend on the VPS.
# Run as root.
set -euo pipefail

TENANT_USER="{{TENANT_LINUX_USER}}"
TENANT_GROUP="{{TENANT_LINUX_GROUP}}"
AGENT_HOME="{{TENANT_AGENT_HOME}}"
DASH_DIR="${AGENT_HOME}/dashboard-chat"

if [[ "${EUID:-$UID}" -ne 0 ]]; then
    echo "Run as root." >&2; exit 1
fi

echo "[install] python deps"
apt-get update -y
apt-get install -y python3 python3-pip
pip3 install --break-system-packages -r "${DASH_DIR}/requirements.txt"

echo "[install] dirs + ownership"
mkdir -p "${DASH_DIR}"
touch "${DASH_DIR}/history.jsonl"
chown -R "${TENANT_USER}:${TENANT_GROUP}" "${DASH_DIR}"
chmod 755 "${DASH_DIR}"
chmod 644 "${DASH_DIR}/history.jsonl"

echo "[install] systemd unit"
cp /etc/systemd/system/dashboard-chat.service /etc/systemd/system/dashboard-chat.service.bak 2>/dev/null || true
install -m 0644 "$(dirname "$0")/../systemd/dashboard-chat.service" /etc/systemd/system/dashboard-chat.service
systemctl daemon-reload
systemctl enable dashboard-chat.service
systemctl restart dashboard-chat.service
sleep 2
systemctl --no-pager status dashboard-chat.service | head -20 || true

echo "[install] smoke test"
sleep 1
curl -fsS http://127.0.0.1:8001/api/chat/health || { echo "[install] health check failed" >&2; exit 1; }

echo
echo "[install] OK — chat backend listening on 127.0.0.1:8001"
echo "[install] add the nginx-snippet.conf into the {{TENANT_DASHBOARD_HOSTNAME}} vhost and reload nginx."
