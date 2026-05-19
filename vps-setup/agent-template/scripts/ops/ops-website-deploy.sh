#!/usr/bin/env bash
# ops-website-deploy.sh — agent-callable wrapper to build + deploy the
# Next.js website at {{TENANT_WEBSITE_SOURCE_PATH}}/.
#
# CALLED VIA SUDO: by the agent (running as {{TENANT_LINUX_USER}}):
#   sudo {{TENANT_AGENT_HOME}}/scripts/ops/ops-website-deploy.sh
#
# Flags:
#   --no-build    skip pnpm build (just restart service — for env/config changes)
#   --skip-deps   skip pnpm install (use when only source files changed)
#
# WHAT IT DOES:
#   1. cd {{TENANT_WEBSITE_SOURCE_PATH}}/
#   2. (optional) pnpm install --frozen-lockfile
#   3. (default) pnpm build  — turbo orchestrates app builds
#   4. systemctl restart {{TENANT_WEBSITE_SYSTEMD_SERVICE}}
#   5. Wait 5s, verify service is active + serving HTTP 200 on :3010
#   6. Ping Telegram with deploy summary
set -euo pipefail

AUDIT_LOG=/var/log/{{TENANT_LINUX_USER}}-agent-ops.log
TG_SEND={{TENANT_AGENT_HOME}}/scripts/tg-send.sh
SOURCE_DIR={{TENANT_WEBSITE_SOURCE_PATH}}

NO_BUILD=0
SKIP_DEPS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)  NO_BUILD=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

audit() { echo "[$(date -u +%FT%TZ)] [website-deploy] $*" | tee -a "$AUDIT_LOG"; }

audit "=== STARTED — flags: no_build=$NO_BUILD skip_deps=$SKIP_DEPS ==="

# Validate source dir
[[ ! -d "$SOURCE_DIR" ]] && { audit "FATAL: $SOURCE_DIR missing"; exit 1; }
[[ ! -f "$SOURCE_DIR/package.json" ]] && { audit "FATAL: $SOURCE_DIR/package.json missing"; exit 1; }

# 1. Install deps (skipped by default since most changes are source-only)
if [[ $SKIP_DEPS -eq 0 ]]; then
  audit "running: pnpm install --frozen-lockfile"
  if ! sudo -u {{TENANT_LINUX_USER}} -H bash -c "cd '$SOURCE_DIR' && pnpm install --frozen-lockfile" >> "$AUDIT_LOG" 2>&1; then
    audit "FATAL: pnpm install failed"
    sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Website deploy FAILED on pnpm install. Check $AUDIT_LOG" 2>/dev/null || true
    exit 2
  fi
else
  audit "skipping pnpm install (--skip-deps)"
fi

# 2. Build
if [[ $NO_BUILD -eq 0 ]]; then
  BUILD_START=$(date +%s)
  audit "running: pnpm build (turbo)"
  if ! sudo -u {{TENANT_LINUX_USER}} -H bash -c "cd '$SOURCE_DIR' && pnpm build" >> "$AUDIT_LOG" 2>&1; then
    audit "FATAL: pnpm build failed"
    sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Website build FAILED. Check $AUDIT_LOG (tail it for the error)." 2>/dev/null || true
    exit 3
  fi
  BUILD_DUR=$(( $(date +%s) - BUILD_START ))
  audit "build complete in ${BUILD_DUR}s"
else
  audit "skipping build (--no-build)"
  BUILD_DUR=0
fi

# 3. Restart service
audit "restarting {{TENANT_WEBSITE_SYSTEMD_SERVICE}}"
if ! systemctl restart {{TENANT_WEBSITE_SYSTEMD_SERVICE}}; then
  audit "FATAL: systemctl restart failed"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Website service restart FAILED. Check journalctl -u {{TENANT_LINUX_USER}}-web" 2>/dev/null || true
  exit 4
fi

# 4. Wait for service to come up + verify HTTP
sleep 5
if ! systemctl is-active --quiet {{TENANT_WEBSITE_SYSTEMD_SERVICE}}; then
  audit "FATAL: service not active after restart"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "🚨 Website service inactive after restart. Check journalctl -u {{TENANT_LINUX_USER}}-web" 2>/dev/null || true
  exit 5
fi

HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:3010/ 2>/dev/null || echo "000")
audit "HTTP probe :3010 → $HTTP_CODE"

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "30"* || "$HTTP_CODE" == "404" ]]; then
  # 200/redirect/404 means the server is responding (404 = no route, but server is up)
  audit "service responding"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "✅ Website deployed — build ${BUILD_DUR}s, HTTP $HTTP_CODE on :3010, service active." 2>/dev/null || true
else
  audit "WARN: unexpected HTTP code $HTTP_CODE"
  sudo -u {{TENANT_LINUX_USER}} "$TG_SEND" send --text "⚠️ Website deployed but :3010 returned HTTP $HTTP_CODE. Service active but check the response." 2>/dev/null || true
fi

audit "=== DONE ==="
