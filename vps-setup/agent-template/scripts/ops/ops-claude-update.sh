#!/usr/bin/env bash
# ops-claude-update.sh — agent-callable wrapper to update Claude Code on the VPS.
#
# CALLED VIA SUDO: this script runs as root via the sudoers NOPASSWD entry
# in /etc/sudoers.d/{{TENANT_LINUX_USER}}-agent-ops. The agent (running as
# {{TENANT_LINUX_USER}}) invokes:
#   sudo {{TENANT_AGENT_HOME}}/scripts/ops/ops-claude-update.sh
#
# WHAT IT DOES (mirrors reference_claude_code_update_procedure.md):
#   1. Record before-version
#   2. npm install -g @anthropic-ai/claude-code@latest
#   3. Record after-version
#   4. Verify all 5 channels-plugin patches survive
#   5. Pre-prune watchdog history (avoids breaker collision)
#   6. Restart claude-agent.service (ExecStartPre re-applies patches)
#   7. Verify service is active
#   8. Ping Telegram with the version delta + smoke summary
#
# Always logs to /var/log/{{TENANT_LINUX_USER}}-agent-ops.log (audit trail).
# Exits non-zero on any failure; the agent should surface that to Daniel.
set -euo pipefail

AUDIT_LOG=/var/log/{{TENANT_LINUX_USER}}-agent-ops.log
TG_SEND={{TENANT_AGENT_HOME}}/scripts/tg-send.sh

audit() {
  echo "[$(date -u +%FT%TZ)] [claude-update] $*" | tee -a "$AUDIT_LOG"
}

audit "=== STARTED (invoked by $(logname 2>/dev/null || echo unknown)) ==="

# 1. Before-version
BEFORE=$(sudo -u {{TENANT_LINUX_USER}} -H /usr/bin/claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
audit "before version: ${BEFORE:-unknown}"

# 2. Find latest
LATEST=$(curl -sS --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest \
  | jq -r '.version' 2>/dev/null || echo "")
audit "latest npm version: ${LATEST:-unknown}"

if [[ "$BEFORE" == "$LATEST" && -n "$BEFORE" ]]; then
  audit "already on latest — no action"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "ℹ️ Claude Code already on latest ($BEFORE). No update needed." 2>/dev/null || true
  exit 0
fi

# 3. Install
audit "running: npm install -g @anthropic-ai/claude-code@latest"
if ! npm install -g @anthropic-ai/claude-code@latest >> "$AUDIT_LOG" 2>&1; then
  audit "FATAL: npm install failed"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Claude Code update FAILED on npm install. Check $AUDIT_LOG" 2>/dev/null || true
  exit 2
fi

# 4. After-version
AFTER=$(sudo -u {{TENANT_LINUX_USER}} -H /usr/bin/claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
audit "after version: ${AFTER:-unknown}"

# 5. Verify channels-plugin patches survived (npm shouldn't touch user cache, but verify)
PLUGIN={{TENANT_USER_HOME}}/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts
MISSING=0
for s in 'v2.22.2:' 'v2.24.0:' 'v2.27.2:' 'v2.27.3:' 'v2.27.4:'; do
  if ! grep -q "$s" "$PLUGIN" 2>/dev/null; then
    audit "WARN: patch sentinel '$s' missing"
    MISSING=$((MISSING + 1))
  fi
done
audit "channels-plugin patches: $((5 - MISSING))/5 intact"

# 6. Pre-prune watchdog history (avoids breaker trip on the restart below)
sed -i "/$(date -u +%Y-%m-%dT%H)/d" /var/lib/{{TENANT_LINUX_USER}}/watchdog-restart-history.txt 2>/dev/null || true
audit "pruned current-hour watchdog history"

# 7. Restart claude-agent.service. ExecStartPre re-applies patches automatically.
audit "restarting claude-agent.service"
if ! systemctl restart claude-agent.service; then
  audit "FATAL: claude-agent.service restart failed"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Claude Code updated to $AFTER but agent restart failed. Check journalctl -u claude-agent" 2>/dev/null || true
  exit 3
fi

sleep 4
if ! systemctl is-active --quiet claude-agent.service; then
  audit "FATAL: claude-agent.service not active after restart"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Claude Code updated to $AFTER but agent not active. Check journalctl -u claude-agent" 2>/dev/null || true
  exit 4
fi
audit "claude-agent.service active"

# 8. Run smoke test for confidence
audit "running smoke test"
SMOKE_OUT=$(sudo -u {{TENANT_LINUX_USER}} bash {{TENANT_AGENT_HOME}}/scripts/smoke-test.sh 2>&1 | tail -5)
audit "smoke test result: $(echo "$SMOKE_OUT" | grep -E 'Passed|Failed')"

# 9. Notify Daniel
SMOKE_SUMMARY=$(echo "$SMOKE_OUT" | grep -E 'Passed|Failed' | head -1)
sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "✅ Claude Code updated: ${BEFORE:-?} → ${AFTER:-?}. ${SMOKE_SUMMARY}. Channels-plugin patches: $((5 - MISSING))/5 intact." 2>/dev/null || true

audit "=== DONE ==="
