#!/usr/bin/env bash
# health.sh — single-command stack health for a tenant. Designed to answer
# "is the stack healthy enough to ship right now?" in under 30 seconds.
#
# Aggregates: preflight + smoke + service-active checks + bun process tree +
# watchdog state file recency + cert expiry + version-pin drift.
#
# Run from anywhere: developer Mac (default), or on the VPS itself with
# HEALTH_LOCAL=1 (matches preflight's PREFLIGHT_LOCAL convention).
#
# Usage:
#   bash vps-setup/scripts/health.sh tenants/example.yml [VPS_HOST]
#
# Output: TAP-style PASS/WARN/FAIL per check, single-line summary at the end.
# Exit codes:
#   0  — all PASS
#   1  — at least one FAIL
#   2  — invalid args

set -uo pipefail

TENANT_FILE="${1:-}"
VPS_HOST="${2:-${HEALTH_VPS_HOST:-root@<your-vps-ip>}}"
HEALTH_LOCAL="${HEALTH_LOCAL:-0}"

[[ -z "$TENANT_FILE" ]] && { echo "usage: $0 <tenant.yml> [VPS_HOST]" >&2; exit 2; }
[[ ! -f "$TENANT_FILE" ]] && { echo "tenant file not found: $TENANT_FILE" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
WARN=0
FAIL=0
ok()   { echo "[ ok ] $*"; PASS=$((PASS+1)); }
warn() { echo "[warn] $*"; WARN=$((WARN+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
note() { echo "       $*"; }

# Tenant fields we care about for health checks.
yaml_scalar() {
  python3 -c "
import sys, re
key = sys.argv[1]; path = sys.argv[2]
for line in open(path):
    m = re.match(r'^' + re.escape(key) + r'\s*:\s*(.*?)\s*(?:#.*)?\$', line)
    if m:
        v = m.group(1).strip()
        if (v.startswith('\"') and v.endswith('\"')) or (v.startswith(\"'\") and v.endswith(\"'\")):
            v = v[1:-1]
        print(v); break
" "$1" "$TENANT_FILE"
}

TENANT_ID=$(yaml_scalar tenant_id)
LINUX_USER=$(yaml_scalar linux_user)
LINUX_USER="${LINUX_USER:-$TENANT_ID}"
DASHBOARD_HOSTNAME=$(yaml_scalar dashboard_hostname)
BASIC_AUTH_USER=$(yaml_scalar dashboard_basic_auth_user)
BASIC_AUTH_USER="${BASIC_AUTH_USER:-$LINUX_USER}"
TLS_CERT_PATH=$(yaml_scalar tls_cert_path)

run_on_vps() {
  if [[ "$HEALTH_LOCAL" == "1" ]]; then
    bash -c "$1"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$VPS_HOST" "$1"
  fi
}

echo "health: tenant=$TENANT_ID dashboard=$DASHBOARD_HOSTNAME ($([ "$HEALTH_LOCAL" == "1" ] && echo "local" || echo "via $VPS_HOST"))"
echo "----"

# 1. Preflight (delegate — preflight already does the deep file/path/git checks).
echo "[ .. ] preflight..."
if PREFLIGHT_LOCAL="$HEALTH_LOCAL" bash "$REPO_ROOT/vps-setup/scripts/preflight.sh" "$TENANT_FILE" "$VPS_HOST" 2>&1 | tail -1 | grep -q '0 FAIL'; then
  ok "preflight clean (12+ checks)"
else
  bad "preflight had FAILs — run preflight.sh directly to see them"
fi

# 2. Five core systemd services active.
SERVICES=(claude-agent.service dashboard-chat.service telemetry-calc.timer nginx telegram-poller-watchdog.timer deploy-timeout-sweep.timer)
for svc in "${SERVICES[@]}"; do
  if run_on_vps "systemctl is-active --quiet $svc" 2>/dev/null; then
    ok "$svc: active"
  else
    bad "$svc: NOT active"
  fi
done

# 3. bun process is in the claude-agent.service cgroup (the v2.20.0+ silent-wedge
#    indicator). When this fails, the watchdog will catch it within 5 min — but
#    health.sh surfaces it immediately so you don't tap /deploy and lose taps.
if run_on_vps "systemctl status --no-pager -l claude-agent.service 2>/dev/null | grep -qE 'bun run.*claude-plugins-official/telegram'"; then
  ok "Telegram bun poller running in claude-agent cgroup"
else
  warn "Telegram bun poller ABSENT — watchdog will restart within 5 min, but inbound Telegram (incl. /deploy taps) won't work until then"
fi

# 4. Watchdog circuit-breaker state — if 3+ restarts in last 30 min, surface it.
HISTORY_FILE="/var/lib/$LINUX_USER/watchdog-restart-history.txt"
HISTORY_FALLBACK="/opt/$LINUX_USER/agents/watchdog-restart-history.txt"
RECENT_RESTARTS=$(run_on_vps "
  for f in '$HISTORY_FILE' '$HISTORY_FALLBACK'; do
    [ -f \"\$f\" ] && {
      now=\$(date +%s); cutoff=\$((now - 1800))
      count=0
      while IFS= read -r ts; do
        [ -z \"\$ts\" ] && continue
        ts_epoch=\$(date -d \"\$ts\" +%s 2>/dev/null) || continue
        [ \"\$ts_epoch\" -ge \"\$cutoff\" ] && count=\$((count+1))
      done < \"\$f\"
      echo \"\$count\"; exit 0
    }
  done
  echo 0
" 2>/dev/null || echo "0")
if [[ "${RECENT_RESTARTS:-0}" -ge 3 ]]; then
  bad "watchdog restarted claude-agent $RECENT_RESTARTS times in last 30min — circuit breaker territory; investigate bun-death root cause"
elif [[ "${RECENT_RESTARTS:-0}" -ge 1 ]]; then
  warn "watchdog restarted claude-agent $RECENT_RESTARTS time(s) in last 30min — bun-death may be recurring"
else
  ok "watchdog history clean (0 restarts in last 30min)"
fi

# 5. Cert expiry. Check the cert file's notAfter date — if <30 days out, warn.
if [[ -n "$TLS_CERT_PATH" ]]; then
  CERT_EXPIRY=$(run_on_vps "openssl x509 -in '$TLS_CERT_PATH' -noout -enddate 2>/dev/null | cut -d= -f2")
  if [[ -n "$CERT_EXPIRY" ]]; then
    # Use python — portable across macOS BSD date and GNU date.
    DAYS_LEFT=$(python3 -c "
import sys, datetime
try:
    d = datetime.datetime.strptime(sys.argv[1].strip(), '%b %d %H:%M:%S %Y %Z')
    print(int((d - datetime.datetime.utcnow()).total_seconds() // 86400))
except Exception:
    print('')
" "$CERT_EXPIRY" 2>/dev/null)
    if [[ -z "$DAYS_LEFT" ]]; then
      warn "TLS cert expiry parse failed (raw: $CERT_EXPIRY)"
    elif [[ $DAYS_LEFT -lt 0 ]]; then
      bad "TLS cert EXPIRED $((-DAYS_LEFT)) days ago: $CERT_EXPIRY"
    elif [[ $DAYS_LEFT -lt 14 ]]; then
      bad "TLS cert expires in $DAYS_LEFT days ($CERT_EXPIRY) — rotate now"
    elif [[ $DAYS_LEFT -lt 60 ]]; then
      warn "TLS cert expires in $DAYS_LEFT days ($CERT_EXPIRY) — plan rotation"
    else
      ok "TLS cert valid for $DAYS_LEFT more days (until $CERT_EXPIRY)"
    fi
  else
    warn "could not read TLS cert expiry from $TLS_CERT_PATH"
  fi
fi

# 6. Version-pin drift (vps-setup/versions.json — added in v2.23.0).
PIN_FILE="$REPO_ROOT/vps-setup/versions.json"
if [[ -f "$PIN_FILE" ]]; then
  for tool in claude bun; do
    pinned=$(jq -r ".${tool}.version // empty" "$PIN_FILE" 2>/dev/null)
    [[ -z "$pinned" ]] && continue
    actual=$(run_on_vps "$tool --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1" || echo "")
    if [[ -z "$actual" ]]; then
      warn "$tool: pinned to $pinned but couldn't read runtime version on VPS"
    elif [[ "$actual" == "$pinned" ]]; then
      ok "$tool: $actual matches pin"
    else
      warn "$tool: pinned $pinned, runtime $actual (drift)"
    fi
  done
else
  note "no version pin file at $PIN_FILE (v2.23.0+ feature)"
fi

# 7. MCP env drift detection (v2.25.1+). Cowork-side and Agent-side ghl-mcp
#    must point at the same GHL location with the same API key. If they
#    diverge, drafts created by Cowork won't reach the same accounts the
#    Agent is reading. Cowork config is local; Agent config is on the VPS.
COWORK_MCP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [[ -f "$COWORK_MCP_CFG" ]] && [[ "$HEALTH_LOCAL" != "1" ]]; then
  cowork_loc=$(python3 -c "
import json, sys
try:
    d = json.load(open('$COWORK_MCP_CFG'))
    env = d.get('mcpServers', {}).get('ghl-mcp', {}).get('env', {})
    print(env.get('GHL_LOCATION_ID',''))
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null)
  cowork_key_prefix=$(python3 -c "
import json
try:
    d = json.load(open('$COWORK_MCP_CFG'))
    env = d.get('mcpServers', {}).get('ghl-mcp', {}).get('env', {})
    print(env.get('GHL_API_KEY','')[:14])
except Exception:
    print('')
" 2>/dev/null)
  agent_loc=$(run_on_vps "sudo -u $LINUX_USER -H python3 -c \"import json; d=json.load(open('/opt/$LINUX_USER/agents/.mcp.json')); print(d.get('mcpServers',{}).get('ghl',{}).get('env',{}).get('GHL_LOCATION_ID',''))\" 2>/dev/null" || echo "")
  agent_key_prefix=$(run_on_vps "sudo -u $LINUX_USER -H python3 -c \"import json; d=json.load(open('/opt/$LINUX_USER/agents/.mcp.json')); print(d.get('mcpServers',{}).get('ghl',{}).get('env',{}).get('GHL_API_KEY','')[:14])\" 2>/dev/null" || echo "")
  if [[ -z "$cowork_loc" ]] || [[ -z "$agent_loc" ]]; then
    warn "MCP env: could not read GHL_LOCATION_ID from one or both configs (Cowork=$cowork_loc Agent=$agent_loc)"
  elif [[ "$cowork_loc" == "$agent_loc" ]] && [[ "$cowork_key_prefix" == "$agent_key_prefix" ]]; then
    ok "MCP env: Cowork and Agent both target $cowork_loc (key prefix matches)"
  else
    bad "MCP env DRIFT: Cowork=$cowork_loc/$cowork_key_prefix... Agent=$agent_loc/$agent_key_prefix... — drafts and reads will hit different GHL locations"
  fi
fi

# 8. Smoke (delegate, suppressed output unless FAIL).
echo "[ .. ] smoke..."
if [[ -n "${BASIC_AUTH_PW:-}" ]]; then
  smoke_summary=$(bash "$REPO_ROOT/vps-setup/scripts/smoke.sh" "$DASHBOARD_HOSTNAME" "$BASIC_AUTH_USER" "$BASIC_AUTH_PW" 2>&1 | tail -1)
  if [[ "$smoke_summary" == *"0 FAIL"* ]]; then
    ok "smoke: $smoke_summary"
  else
    bad "smoke: $smoke_summary"
  fi
else
  note "BASIC_AUTH_PW not set — skipping smoke (set env var or use server-credentials/)"
fi

echo "----"
echo "health: $PASS PASS / $WARN WARN / $FAIL FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
