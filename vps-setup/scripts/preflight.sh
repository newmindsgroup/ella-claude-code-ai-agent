#!/usr/bin/env bash
# preflight.sh — pre-deploy verification for v2.20.0+ tenants.
#
# Closes the bug class surfaced during v2.20.0 deploy: rendered configs hardcoded
# values (cert paths, htpasswd filename, claude binary location, CLAUDE.md install
# target) that didn't match what was on the VPS. This script catches those at
# pre-flight (Phase 1) instead of mid-deploy (Phase 3).
#
# Usage:
#   bash vps-setup/scripts/preflight.sh tenants/example.yml [VPS_HOST]
#
# Args:
#   tenant.yml path  — required. Used to resolve tenant_id and look up the rendered
#                      config under vps-setup/agents-config/{tenant_id}/.
#   VPS_HOST         — optional. SSH target (e.g. root@<your-vps-ip>).
#                      Defaults to PREFLIGHT_VPS_HOST env var, else
#                      root@<your-vps-ip> (Daniel's tenant default).
#
# Exit codes:
#   0  — all checks PASS
#   1  — one or more checks FAIL
#   2  — invalid args or tenant.yml not parseable

set -uo pipefail

TENANT_FILE="${1:-}"
VPS_HOST="${2:-${PREFLIGHT_VPS_HOST:-root@<your-vps-ip>}}"
# v2.22.3: when preflight runs ON the target VPS itself (e.g. invoked by
# /deploy from within the agent), there's no need to SSH back to localhost —
# in fact, the agent user can't ssh to root@self without keys. Set
# PREFLIGHT_LOCAL=1 to run the "remote" checks directly via bash instead.
PREFLIGHT_LOCAL="${PREFLIGHT_LOCAL:-0}"

[[ -z "$TENANT_FILE" ]] && { echo "usage: $0 <tenant.yml> [VPS_HOST]" >&2; exit 2; }
[[ ! -f "$TENANT_FILE" ]] && { echo "tenant file not found: $TENANT_FILE" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Output helpers.
PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
note() { echo "       $*"; }

# Extract a top-level scalar from tenant.yml without requiring pyyaml.
yaml_scalar() {
  local key="$1" file="$2"
  python3 -c "
import sys, re
key = sys.argv[1]; path = sys.argv[2]
for line in open(path):
    m = re.match(r'^' + re.escape(key) + r'\s*:\s*(.*?)\s*(?:#.*)?$', line)
    if m:
        v = m.group(1).strip()
        if (v.startswith('\"') and v.endswith('\"')) or (v.startswith(\"'\") and v.endswith(\"'\")):
            v = v[1:-1]
        print(v); break
" "$key" "$file"
}

TENANT_ID=$(yaml_scalar tenant_id "$TENANT_FILE")
LINUX_USER=$(yaml_scalar linux_user "$TENANT_FILE")
AGENT_HOME=$(yaml_scalar agent_home "$TENANT_FILE")
DASHBOARD_HOSTNAME=$(yaml_scalar dashboard_hostname "$TENANT_FILE")
TLS_CERT_PATH=$(yaml_scalar tls_cert_path "$TENANT_FILE")
TLS_KEY_PATH=$(yaml_scalar tls_key_path "$TENANT_FILE")

[[ -z "$TENANT_ID" ]] && { echo "FATAL: tenant_id missing from $TENANT_FILE" >&2; exit 2; }
LINUX_USER="${LINUX_USER:-$TENANT_ID}"
AGENT_HOME="${AGENT_HOME:-/opt/$LINUX_USER/agents}"

RENDERED="vps-setup/agents-config/$TENANT_ID"
NGINX_VHOST="$RENDERED/nginx/dashboard.conf"
CHAT_SERVER="$RENDERED/dashboard-chat/server.py"

echo "preflight: tenant=$TENANT_ID host=$VPS_HOST hostname=$DASHBOARD_HOSTNAME"
echo "----"

# ---------------------------------------------------------------------------
# Local repo checks (fast — no SSH yet).
# ---------------------------------------------------------------------------

# 1) Rendered config artifacts exist.
if [[ -f "$NGINX_VHOST" ]]; then
  ok "rendered nginx vhost present: $NGINX_VHOST"
else
  bad "rendered nginx vhost MISSING: $NGINX_VHOST"
fi

if [[ -f "$CHAT_SERVER" ]]; then
  ok "rendered dashboard-chat server.py present: $CHAT_SERVER"
else
  bad "rendered dashboard-chat server.py MISSING: $CHAT_SERVER"
fi

# 2) No unresolved {{TENANT_*}} placeholders in the rendered config (excluding
#    placeholder-format references inside comments — pattern is {{TENANT_*}} with the literal asterisk).
UNRESOLVED=$(grep -rn '{{TENANT_' "$RENDERED" 2>/dev/null | grep -v '{{TENANT_\*}}' | grep -vE '^[^:]+:[0-9]+:\s*#' || true)
if [[ -z "$UNRESOLVED" ]]; then
  ok "rendered config has no unresolved placeholders"
else
  bad "rendered config has unresolved placeholders:"
  echo "$UNRESOLVED" | head -5 | sed 's/^/       /'
fi

# 3) Local git is clean (or only modified files we expect).
GIT_DIRTY=$(git status --porcelain | grep -vE "^\?\?\s+vps-setup/runbooks/" || true)
if [[ -z "$GIT_DIRTY" ]]; then
  ok "git working tree clean (ignoring unrelated working-tree drift)"
else
  WC=$(echo "$GIT_DIRTY" | wc -l | tr -d ' ')
  bad "git working tree has $WC modified files outside the runbooks/ allow-list"
  echo "$GIT_DIRTY" | head -5 | sed 's/^/       /'
fi

# 4) Local clone is synced with origin.
git fetch -q origin main 2>/dev/null || true
BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
if [[ "$BEHIND" == "0" ]]; then
  ok "local clone in sync with origin/main"
elif [[ "$BEHIND" == "?" ]]; then
  note "could not determine git sync (no network or no upstream)"
else
  bad "local clone is $BEHIND commits behind origin/main — run: git pull --ff-only origin main"
fi

# ---------------------------------------------------------------------------
# Extract the paths the rendered config WILL try to use on the VPS.
# ---------------------------------------------------------------------------

if [[ -f "$NGINX_VHOST" ]]; then
  VHOST_CERT=$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ {print $2}' "$NGINX_VHOST" | head -1 | tr -d ';')
  VHOST_KEY=$(awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/ {print $2}' "$NGINX_VHOST" | head -1 | tr -d ';')
  VHOST_HTPASSWD=$(awk '/^[[:space:]]*auth_basic_user_file[[:space:]]/ {print $2}' "$NGINX_VHOST" | head -1 | tr -d ';')
else
  VHOST_CERT=""; VHOST_KEY=""; VHOST_HTPASSWD=""
fi

# Cross-check vhost paths against tenant.yml declarations.
if [[ -n "$VHOST_CERT" && -n "$TLS_CERT_PATH" && "$VHOST_CERT" != "$TLS_CERT_PATH" ]]; then
  bad "vhost ssl_certificate ($VHOST_CERT) != tenant.yml tls_cert_path ($TLS_CERT_PATH) — re-run render-tenant.sh"
fi
if [[ -n "$VHOST_KEY" && -n "$TLS_KEY_PATH" && "$VHOST_KEY" != "$TLS_KEY_PATH" ]]; then
  bad "vhost ssl_certificate_key ($VHOST_KEY) != tenant.yml tls_key_path ($TLS_KEY_PATH) — re-run render-tenant.sh"
fi

# ---------------------------------------------------------------------------
# Remote VPS checks. When PREFLIGHT_LOCAL=1 (preflight running on the target
# VPS itself), wrap commands in bash -c instead of ssh — the agent user
# can't ssh to root@self without keys, and there's no point routing through
# the network when the target IS local.
# ---------------------------------------------------------------------------

run_on_vps() {
  if [[ "$PREFLIGHT_LOCAL" == "1" ]]; then
    bash -c "$1"
  else
    ssh -o BatchMode=yes "$VPS_HOST" "$1"
  fi
}

if [[ "$PREFLIGHT_LOCAL" == "1" ]]; then
  ok "running on target VPS directly (PREFLIGHT_LOCAL=1) — skipping SSH reachability check"
else
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$VPS_HOST" 'echo ok' >/dev/null 2>&1; then
    bad "VPS $VPS_HOST unreachable via SSH (no key auth) — run ssh-copy-id first"
    echo "----"
    echo "preflight: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
  ok "VPS $VPS_HOST reachable via SSH"
fi

# 5) Cert + key files exist on VPS. Note: we deliberately drop the `test -r`
# check — keys live at /etc/ssl/private/*.key (mode 600, root-only) and
# htpasswd files at /etc/nginx/.htpasswd-* (mode 640, root:www-data).
# When preflight runs as a non-root user (PREFLIGHT_LOCAL=1 inside /deploy),
# `test -r` returns false even though nginx (www-data) can read them fine.
# The smoke test already validates "is the dashboard actually serving" so a
# permission regression would be caught there, not here. This check is just
# "is the path on disk."
if [[ -n "$VHOST_CERT" ]]; then
  if run_on_vps "test -f '$VHOST_CERT'"; then
    ok "ssl_certificate exists on VPS: $VHOST_CERT"
  else
    bad "ssl_certificate MISSING on VPS: $VHOST_CERT"
  fi
fi
if [[ -n "$VHOST_KEY" ]]; then
  # The key dir (e.g. /etc/ssl/private/) is typically mode 700 root:root, so
  # a non-root caller (PREFLIGHT_LOCAL=1 from /deploy as the tenant user)
  # can't even traverse it to test -f. Detect the case and degrade to a
  # note instead of a FAIL — smoke catches a missing-key regression via
  # HTTPS handshake failure, which is the truer signal anyway.
  if run_on_vps "test -f '$VHOST_KEY'" 2>/dev/null; then
    ok "ssl_certificate_key exists on VPS: $VHOST_KEY"
  elif [[ "$PREFLIGHT_LOCAL" == "1" ]] && [[ "$(id -u)" != "0" ]]; then
    note "ssl_certificate_key not directly readable by $(id -un) — skipping (smoke validates via HTTPS handshake)"
  else
    bad "ssl_certificate_key MISSING on VPS: $VHOST_KEY"
  fi
fi

# 6) htpasswd file exists. Same `-r` caveat as above — file is mode 640
# root:www-data, only root and www-data can read it directly.
if [[ -n "$VHOST_HTPASSWD" ]]; then
  if run_on_vps "test -f '$VHOST_HTPASSWD'"; then
    ok "auth_basic_user_file exists on VPS: $VHOST_HTPASSWD"
  else
    bad "auth_basic_user_file MISSING on VPS: $VHOST_HTPASSWD"
  fi
fi

# 7) `claude` binary reachable.
CLAUDE_BIN_PATH=$(run_on_vps 'which claude 2>/dev/null || true')
if [[ -n "$CLAUDE_BIN_PATH" ]]; then
  ok "claude binary on VPS: $CLAUDE_BIN_PATH"
  # Confirm dashboard-chat server.py either auto-detects via shutil.which OR matches this path.
  if [[ -f "$CHAT_SERVER" ]]; then
    if grep -q "shutil.which.*claude" "$CHAT_SERVER"; then
      ok "dashboard-chat server.py auto-detects claude via shutil.which"
    elif grep -qE "^CLAUDE_BIN[[:space:]]*=.*$CLAUDE_BIN_PATH" "$CHAT_SERVER"; then
      ok "dashboard-chat server.py CLAUDE_BIN matches VPS path"
    else
      bad "dashboard-chat server.py CLAUDE_BIN does not auto-detect AND does not match $CLAUDE_BIN_PATH"
    fi
  fi
else
  bad "claude binary not on VPS PATH"
fi

# 8) CLAUDE.md install target. Find the agent's actual cwd and confirm the
#    tenant's CLAUDE.md install path is $cwd/CLAUDE.md (not parent dir).
# NOTE: `pgrep -af 'claude --channels'` matches the SSH wrapper bash too
# (its argv contains the literal string we're grepping for). Filter to
# command lines that start with the `claude` binary — that's the actual
# claude process, not its tmux parent or our remote-shell wrapper.
AGENT_PID=$(run_on_vps "pgrep -af 'claude --channels' | awk '\$2 == \"claude\"' | head -1 | awk '{print \$1}'" 2>/dev/null || true)
if [[ -n "$AGENT_PID" ]]; then
  REAL_CWD=$(run_on_vps "readlink /proc/$AGENT_PID/cwd 2>/dev/null || true")
  if [[ -n "$REAL_CWD" ]]; then
    EXPECTED="$REAL_CWD/CLAUDE.md"
    if run_on_vps "test -f '$EXPECTED'"; then
      ok "CLAUDE.md present at agent's cwd: $EXPECTED"
    else
      bad "CLAUDE.md MISSING at agent's cwd: $EXPECTED — runbook may install to wrong path"
    fi
    # Warn if a stale duplicate exists at the parent dir.
    PARENT_DUP="$(dirname "$REAL_CWD")/CLAUDE.md"
    if run_on_vps "test -f '$PARENT_DUP'"; then
      bad "stale CLAUDE.md at parent dir: $PARENT_DUP — Claude Code will load both, doubling the prompt"
    fi
  else
    bad "could not resolve agent cwd from /proc/$AGENT_PID/cwd"
  fi
else
  bad "no claude --channels process running on VPS — claude-agent.service may be down"
fi

# ---------------------------------------------------------------------------
echo "----"
echo "preflight: $PASS PASS / $FAIL FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
