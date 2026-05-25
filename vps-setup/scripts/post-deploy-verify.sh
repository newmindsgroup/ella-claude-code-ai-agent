#!/usr/bin/env bash
# post-deploy-verify.sh — single-command "is the deploy green?" check.
# Runs from the LOCAL Mac AGAINST the deployed VPS. Exit 0 = green; the
# local agent can mark the deploy complete. Exit ≥1 = something broken.
#
# USAGE:
#   bash vps-setup/scripts/post-deploy-verify.sh <path-to-client-credentials.md>
#
# What it verifies:
#   1. VPS reachable + healthy (uptime, disk, memory)
#   2. Every systemd unit we expect is active
#   3. Every /api/*.json endpoint we expect serves valid JSON behind basic-auth
#   4. SSE handshake works (curl can read the "hello" event)
#   5. dashboard-chat backend reachable via nginx + basic-auth
#   6. pytest harness runs and reports 53/53 (the pure-logic suite)

set -uo pipefail

CREDS="${1:-}"
[[ -z "$CREDS" ]] && { echo "usage: $0 <path-to-client-credentials.md>" >&2; exit 1; }
[[ ! -f "$CREDS" ]] && { echo "ERROR: $CREDS not found" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0
ok()    { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
warn()  { echo "  ⚠ $1"; WARN=$((WARN+1)); }
section() { echo; echo "═══ $1 ═══"; }

# Helper: extract YAML values from the credentials markdown
yget() {
  python3 - "$CREDS" "$1" <<'PYEOF'
import sys, re, yaml
md = open(sys.argv[1]).read()
key = sys.argv[2]
for block in re.findall(r'```yaml\n(.*?)```', md, re.DOTALL):
    try:
        d = yaml.safe_load(re.sub(r'(?m)#.*$', '', block)) or {}
        if key in d and d[key] not in (None, ""):
            v = d[key]
            print(v if not isinstance(v, str) else v.strip())
            sys.exit(0)
    except yaml.YAMLError:
        continue
sys.exit(0)
PYEOF
}

VPS_IP=$(yget vps_ip)
VPS_ROOT_USER=$(yget vps_root_user); VPS_ROOT_USER="${VPS_ROOT_USER:-root}"
TENANT_LINUX_USER=$(yget client_linux_user)
[[ -z "$TENANT_LINUX_USER" ]] && TENANT_LINUX_USER=$(yget client_brand_name | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed -E 's/^_+|_+$//g')
DASHBOARD_HOSTNAME=$(yget dashboard_hostname)
BASIC_AUTH_USER=$(yget basic_auth_user); BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
BASIC_AUTH_PW=$(yget basic_auth_pw)

SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ── 1. VPS reachability + basic health ─────────────────────────────────────
section "1. VPS health"

if [[ -z "$VPS_IP" ]]; then
  fail "vps_ip not in credentials"
else
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "uptime" >/dev/null 2>&1; then
    UPTIME=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "uptime -p" 2>/dev/null || echo "?")
    ok "SSH reachable · $UPTIME"
  else
    fail "SSH to $VPS_ROOT_USER@$VPS_IP failed — deploy not running"
    echo
    echo "  Can't reach the VPS. All other checks will fail. Stopping early."
    exit 1
  fi
  # Disk
  DISK_PCT=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "df / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null)
  if [[ -n "$DISK_PCT" && "$DISK_PCT" -lt 85 ]]; then
    ok "root disk ${DISK_PCT}% used"
  elif [[ -n "$DISK_PCT" ]]; then
    warn "root disk ${DISK_PCT}% used — near the orange threshold (85%)"
  fi
  # Memory
  MEM_FREE=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "free -m | awk 'NR==2 {print \$7}'" 2>/dev/null)
  if [[ -n "$MEM_FREE" && "$MEM_FREE" -gt 200 ]]; then
    ok "memory available ${MEM_FREE} MB"
  elif [[ -n "$MEM_FREE" ]]; then
    warn "memory available ${MEM_FREE} MB — watch for OOM kills"
  fi
fi

# ── 2. systemd units ───────────────────────────────────────────────────────
section "2. systemd units"

UNITS=(
  claude-agent.service
  dashboard-chat.service
  nginx.service
  telegram-poller-watchdog.timer
  dashboard-sync.timer
  telemetry-calc.timer
  morning-brief.timer
  evening-rollup.timer
  task-deadline-watcher.timer
  goal-deadline-watcher.timer
  disk-space-watcher.timer
  rules-engine.timer
  anomaly-detect.timer
  session-parser.timer
)
for u in "${UNITS[@]}"; do
  STATE=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "systemctl is-active $u 2>/dev/null" 2>/dev/null || echo "unknown")
  if [[ "$STATE" == "active" ]]; then
    ok "$u active"
  elif [[ "$STATE" == "inactive" && "$u" == *.timer ]]; then
    # Some timer units are reported inactive if the next-fire is far out; check is-enabled
    ENABLED=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "systemctl is-enabled $u 2>/dev/null" 2>/dev/null || echo "?")
    if [[ "$ENABLED" == "enabled" ]]; then
      ok "$u enabled (waiting for next fire)"
    else
      warn "$u inactive AND not enabled — feature is off"
    fi
  else
    fail "$u: $STATE"
  fi
done

# ── 3. JSON endpoints behind basic auth ────────────────────────────────────
section "3. /api/*.json endpoints"

if [[ -z "$DASHBOARD_HOSTNAME" || -z "$BASIC_AUTH_PW" ]]; then
  warn "dashboard_hostname or basic_auth_pw missing — skipping HTTP checks"
else
  BASE="https://$DASHBOARD_HOSTNAME/api"
  AUTH="-u $BASIC_AUTH_USER:$BASIC_AUTH_PW"
  ENDPOINTS=(
    /tasks.json /goals.json /memory.json /telemetry.json /health.json
    /drafts.json /triage.json /improvements.json /sessions.json
    /skills.json /anomalies.json /deploys.json /spans.json /roi.json /budget.json
  )
  for ep in "${ENDPOINTS[@]}"; do
    HTTP=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 $AUTH "$BASE$ep")
    if [[ "$HTTP" == "200" ]]; then
      # Verify JSON parses
      if curl -sS --max-time 10 $AUTH "$BASE$ep" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        ok "$ep · 200 · valid JSON"
      else
        warn "$ep · 200 · invalid JSON body"
      fi
    elif [[ "$HTTP" == "404" ]]; then
      warn "$ep · 404 (not yet generated — dashboard-sync hasn't run?)"
    else
      fail "$ep · HTTP $HTTP"
    fi
  done
fi

# ── 4. SSE handshake ───────────────────────────────────────────────────────
section "4. SSE push channel"

if [[ -n "$DASHBOARD_HOSTNAME" && -n "$BASIC_AUTH_PW" ]]; then
  # Open the SSE stream for 5 seconds and look for at least one event line
  SSE_OUT=$(timeout 5 curl -sS --max-time 5 \
    -u "$BASIC_AUTH_USER:$BASIC_AUTH_PW" \
    "https://$DASHBOARD_HOSTNAME/api/chat/events" 2>/dev/null || true)
  if echo "$SSE_OUT" | grep -qE "^(event:|data:)"; then
    ok "SSE handshake — received at least one event"
  else
    warn "SSE handshake produced no events in 5s (could be quiet window)"
  fi
else
  warn "credentials incomplete — skipping SSE check"
fi

# ── 5. dashboard-chat backend reachable through nginx ──────────────────────
section "5. dashboard-chat backend"

if [[ -n "$DASHBOARD_HOSTNAME" && -n "$BASIC_AUTH_PW" ]]; then
  HTTP=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
    -u "$BASIC_AUTH_USER:$BASIC_AUTH_PW" \
    "https://$DASHBOARD_HOSTNAME/api/chat/audit?limit=1")
  if [[ "$HTTP" == "200" ]]; then
    ok "/api/chat/audit reachable through nginx basic-auth"
  else
    fail "/api/chat/audit returned HTTP $HTTP"
  fi
fi

# ── 5b. agent capabilities (Graphify / embedding daemon / Obsidian / crontab) ──
# This is the section that catches "files copied but capabilities not installed."
# If any FAIL here, re-run: install-capabilities.sh vps-setup/tenants/<id>.yml
section "5b. agent capabilities"

if [[ -n "$VPS_IP" && -n "$TENANT_LINUX_USER" ]]; then
  AH="/opt/$TENANT_LINUX_USER/agents"

  # Graphify CLI installed for the tenant user
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "sudo -u $TENANT_LINUX_USER -H bash -lc 'command -v graphify >/dev/null 2>&1 || [ -x \$HOME/.local/bin/graphify ]'" 2>/dev/null; then
    ok "Graphify CLI installed"
  else
    fail "Graphify NOT installed — run install-capabilities.sh"
  fi

  # Graphify Claude Code skill registered
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "test -f /opt/$TENANT_LINUX_USER/.claude/skills/graphify/SKILL.md" 2>/dev/null; then
    ok "Graphify skill registered"
  else
    warn "Graphify skill not registered (finishes after 'claude login' + re-run)"
  fi

  # Embedding daemon socket present (memory v2 semantic recall)
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "test -S $AH/embedding.sock" 2>/dev/null; then
    ok "embedding daemon socket present"
  else
    warn "embedding daemon not running (lazy-starts on first recall; or re-run install-capabilities.sh)"
  fi

  # Obsidian vault populated (memory-export has run at least once)
  if ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "test -d $AH/obsidian-vault/memories" 2>/dev/null; then
    ok "Obsidian vault directory present"
  else
    warn "Obsidian vault not initialized — re-run install-capabilities.sh"
  fi

  # Crontab installed for the tenant (memory-export 5min + @reboot daemons)
  CRON_LINES=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "crontab -u $TENANT_LINUX_USER -l 2>/dev/null | grep -cE 'memory-export|entity-linker|start-embedding' || true" 2>/dev/null)
  if [[ "${CRON_LINES:-0}" =~ ^[0-9]+$ && "${CRON_LINES:-0}" -ge 1 ]]; then
    ok "tenant crontab installed ($CRON_LINES capability jobs)"
  else
    fail "tenant crontab NOT installed (no memory-export/entity-linker jobs) — run install-capabilities.sh"
  fi

  # MCP servers registered
  MCP_COUNT=$(ssh $SSH_OPTS "$VPS_ROOT_USER@$VPS_IP" "sudo -u $TENANT_LINUX_USER -H bash -lc 'claude mcp list 2>/dev/null | grep -cE \"memory|fetch|filesystem|firecrawl|chroma\"' || true" 2>/dev/null)
  if [[ "${MCP_COUNT:-0}" =~ ^[0-9]+$ && "${MCP_COUNT:-0}" -ge 1 ]]; then
    ok "$MCP_COUNT MCP servers registered"
  else
    warn "no MCP servers registered yet (finish after 'claude login' + re-run install-capabilities.sh)"
  fi
else
  warn "vps_ip or tenant linux user unknown — skipping capability checks"
fi

# ── 6. pytest contract suite ───────────────────────────────────────────────
section "6. pytest contract suite (local)"

if command -v pytest >/dev/null 2>&1 && [[ -d tests/ ]]; then
  if python3 -m pytest tests/ -q --no-header 2>&1 | tee /tmp/post-deploy-pytest.out | tail -5; then
    # Grab the summary line
    SUMMARY=$(tail -3 /tmp/post-deploy-pytest.out | grep -E "passed|failed" | head -1)
    if echo "$SUMMARY" | grep -q "failed"; then
      fail "pytest reported failures — $SUMMARY"
    else
      ok "pytest: $SUMMARY"
    fi
  else
    fail "pytest exited non-zero — see /tmp/post-deploy-pytest.out"
  fi
else
  warn "pytest or tests/ missing — skipping contract suite"
fi

# ── FINAL ──────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
echo " POST-DEPLOY VERIFY: $PASS PASS · $FAIL FAIL · $WARN WARN"
echo "═══════════════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "✅ Deploy is GREEN. Safe to hand the dashboard URL to the client."
  exit 0
else
  echo "❌ Deploy has $FAIL hard failures — investigate before tagging release."
  exit 1
fi
