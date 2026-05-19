#!/usr/bin/env bash
# bootstrap-mission-control.sh — wire all v0.7.0 Mission Control components
# on a fresh VPS deploy. Runs AFTER render-and-deploy.sh has copied the
# rendered tenant to /opt/<linux_user>/agents/.
#
# Idempotent. Safe to re-run. Each step checks current state before mutating.
#
# USAGE (on the VPS, as root):
#   bash {{TENANT_AGENT_HOME}}/scripts/bootstrap-mission-control.sh
#
# What it does:
#   1. Install Python deps for FastAPI dashboard-chat backend (fastapi, uvicorn,
#      pydantic, pyyaml). User-mode install under the tenant linux_user.
#   2. Create state/ directory + initialize spans.db (empty schema).
#   3. Enable + start systemd units for Mission Control (rules-engine.timer,
#      anomaly-detect.timer, session-parser.timer, dashboard-chat.service).
#   4. Verify each unit reached active state. Fail loudly if any didn't.
#   5. Print a green/red summary.
#
# Reads feature flags from {{TENANT_AGENT_HOME}}/.env-deploy:
#   ENABLE_RULES_ENGINE=true|false       (default true)
#   ENABLE_ANOMALY_DETECTION=true|false  (default true)
#   ENABLE_SESSION_PARSER=true|false     (default true)
#   ENABLE_CIRCUIT_BREAKERS=true|false   (default true)
#
# A flag of "false" leaves the unit installed but disabled — flip the flag and
# re-run to enable later.

set -uo pipefail

TENANT_USER="{{TENANT_LINUX_USER}}"
AGENT_HOME="{{TENANT_AGENT_HOME}}"
USER_HOME="{{TENANT_USER_HOME}}"
ENV_FILE="$AGENT_HOME/.env-deploy"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1"; SKIP=$((SKIP+1)); }
section() { echo; echo "═══ $1 ═══"; }

# Must run as root (or via sudo)
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (or via sudo). systemctl operations need it." >&2
  exit 1
fi

# Source feature flags if present
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi
ENABLE_RULES_ENGINE="${ENABLE_RULES_ENGINE:-true}"
ENABLE_ANOMALY_DETECTION="${ENABLE_ANOMALY_DETECTION:-true}"
ENABLE_SESSION_PARSER="${ENABLE_SESSION_PARSER:-true}"
ENABLE_CIRCUIT_BREAKERS="${ENABLE_CIRCUIT_BREAKERS:-true}"

# ── 1. Python deps for dashboard-chat ──────────────────────────────────────
section "1. Python dependencies"

REQ_FILE="$AGENT_HOME/dashboard-chat/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  if su - "$TENANT_USER" -c "python3 -m pip install --user --quiet --break-system-packages -r '$REQ_FILE'" 2>/dev/null \
  || su - "$TENANT_USER" -c "python3 -m pip install --user --quiet -r '$REQ_FILE'"; then
    ok "FastAPI deps installed for $TENANT_USER"
  else
    fail "pip install failed — check $REQ_FILE syntax + network"
  fi
else
  skip "no dashboard-chat/requirements.txt — skipping"
fi

# pyyaml is needed by rules-engine.py + render-tenant.sh; ensure system-wide
if ! python3 -c "import yaml" 2>/dev/null; then
  apt-get update -qq && apt-get install -y -qq python3-yaml >/dev/null 2>&1 \
    && ok "python3-yaml installed (system)" \
    || fail "python3-yaml install failed — rules engine won't work"
else
  ok "python3-yaml already present"
fi

# sqlite3 is built into Python stdlib; just confirm
if python3 -c "import sqlite3" 2>/dev/null; then
  ok "python3 sqlite3 module present (for spans store)"
else
  fail "python3 sqlite3 NOT available — spans store won't work"
fi

# ── 2. Initialize state directory + spans.db schema ────────────────────────
section "2. State directory + spans.db"

STATE_DIR="$AGENT_HOME/state"
mkdir -p "$STATE_DIR" && chown "$TENANT_USER:$TENANT_USER" "$STATE_DIR" \
  && ok "state/ directory ready ($STATE_DIR)"

if [[ -f "$AGENT_HOME/scripts/_spans.py" ]]; then
  if su - "$TENANT_USER" -c "cd '$AGENT_HOME' && python3 -c 'import sys; sys.path.insert(0, \"scripts\"); import _spans; _spans._ensure_db(_spans.DB_PATH); print(\"ok\")'" 2>&1 | grep -q ok; then
    ok "spans.db schema initialized"
  else
    fail "spans.db init failed — check _spans.py + state/ permissions"
  fi
else
  skip "_spans.py not present — Phase 4 features will not run"
fi

# ── 3. Enable + start systemd units ────────────────────────────────────────
section "3. systemd units"

# Map of unit → feature flag → required-file
declare -A UNITS=(
  ["dashboard-chat.service"]="true:$AGENT_HOME/dashboard-chat/server.py"
  ["rules-engine.timer"]="$ENABLE_RULES_ENGINE:$AGENT_HOME/scripts/rules-engine.py"
  ["anomaly-detect.timer"]="$ENABLE_ANOMALY_DETECTION:$AGENT_HOME/scripts/anomaly-detect.py"
  ["session-parser.timer"]="$ENABLE_SESSION_PARSER:$AGENT_HOME/scripts/session-parser.py"
)

systemctl daemon-reload

for unit in "${!UNITS[@]}"; do
  IFS=":" read -r flag reqfile <<< "${UNITS[$unit]}"
  if [[ "$flag" != "true" ]]; then
    skip "$unit (feature flag disabled)"
    continue
  fi
  if [[ ! -f "$reqfile" ]]; then
    skip "$unit (script missing: $reqfile)"
    continue
  fi
  # Service or timer?
  if [[ "$unit" == *.timer ]]; then
    if systemctl enable --now "$unit" 2>/dev/null; then
      ok "$unit enabled + started"
    else
      fail "$unit enable failed — check journalctl -u $unit"
    fi
  else
    # service — restart to pick up new config
    if systemctl enable "$unit" >/dev/null 2>&1 && systemctl restart "$unit"; then
      sleep 1
      if systemctl is-active --quiet "$unit"; then
        ok "$unit running"
      else
        fail "$unit started but not active — journalctl -u $unit -n 30"
      fi
    else
      fail "$unit enable/restart failed"
    fi
  fi
done

# ── 4. Smoke-test the FastAPI backend ──────────────────────────────────────
section "4. FastAPI smoke test"

if systemctl is-active --quiet dashboard-chat.service; then
  for endpoint in /api/chat/audit /api/chat/rules /api/chat/budget; do
    if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:8001$endpoint"; then
      ok "dashboard-chat reachable at $endpoint"
    else
      fail "dashboard-chat unreachable at $endpoint"
    fi
  done
else
  skip "dashboard-chat.service not active — skipping HTTP smoke"
fi

# ── 5. nginx config reload (if /api/chat/events SSE block is new) ──────────
section "5. nginx reload"

if nginx -t 2>/dev/null; then
  if systemctl reload nginx 2>/dev/null; then
    ok "nginx reloaded"
  else
    fail "nginx reload failed"
  fi
else
  fail "nginx -t shows config errors — fix before reload"
fi

# ── FINAL ──────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
echo " BOOTSTRAP RESULT: $PASS PASS · $FAIL FAIL · $SKIP SKIP"
echo "═══════════════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "✅ Mission Control bootstrapped. Run post-deploy-verify.sh next."
  exit 0
else
  echo "❌ Mission Control bootstrap had $FAIL failures — investigate before continuing."
  exit 1
fi
