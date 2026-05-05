#!/usr/bin/env bash
# render-and-deploy.sh — render the agent template + deploy to the VPS in one command.
#
# Replaces this 4-step manual ritual:
#   1. bash vps-setup/scripts/render-tenant.sh tenants/<tenant>.yml
#   2. ssh vps "git pull && cp vps-setup/agents-config/<tenant>/CLAUDE.md /opt/<tenant>/agents/CLAUDE.md"
#   3. ssh vps "truncate -s 0 /var/lib/<tenant>/watchdog-restart-history.txt"  (avoid circuit-breaker collision)
#   4. ssh vps "systemctl restart claude-agent.service && journalctl -u claude-agent.service -n 30"
#
# Usage:
#   bash vps-setup/scripts/render-and-deploy.sh tenants/<tenant>.yml [--dry-run] [--no-restart] [--vps-host root@host]
#
# Flags:
#   --dry-run     Render + show diff. Don't touch the VPS.
#   --no-restart  Render + copy to VPS but skip the service restart (for batched changes).
#   --vps-host    Override the SSH target. Default: parsed from tenant.yml's vps_host field.
#
# Idempotent. Safe to re-run. Refuses to restart if the rendered CLAUDE.md
# is byte-identical to what's already on the VPS (no-op fast path).
#
# Operating-principles compliance:
#   - Truncates the watchdog-restart-history file before manual restart so we
#     don't trip the bun-death circuit breaker (per feedback_watchdog_breaker_collision).
#   - Always shows a diff before deploying so you can spot-check.
#   - Tails 20 lines of journalctl after restart to verify clean startup.
#   - No force-push, no rm -rf, no destructive ops.

set -euo pipefail

# ---------- arg parsing ----------
TENANT_YML=""
DRY_RUN=0
NO_RESTART=0
VPS_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) NO_RESTART=1; shift ;;
    --vps-host) VPS_HOST="$2"; shift 2 ;;
    --help|-h) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    -*) echo "[ERR] unknown flag: $1" >&2; exit 1 ;;
    *) TENANT_YML="$1"; shift ;;
  esac
done

[[ -z "${TENANT_YML}" ]] && { echo "usage: $0 <tenant.yml> [--dry-run] [--no-restart] [--vps-host root@host]" >&2; exit 1; }
[[ ! -f "${TENANT_YML}" ]] && { echo "[ERR] tenant file not found: ${TENANT_YML}" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------- pretty printing ----------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[0;31m' C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
else
  C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi
ok()    { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*" >&2; }
err()   { printf "${C_RED}[ERR]${C_RESET}   %s\n" "$*" >&2; }
step()  { printf "\n${C_BOLD}${C_CYAN}=== %s ===${C_RESET}\n" "$*"; }
dim()   { printf "${C_DIM}%s${C_RESET}\n" "$*"; }

# ---------- read tenant.yml ----------
read_tenant_field() {
  local key="$1"
  python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" \
    "${TENANT_YML}" "${key}" 2>/dev/null || echo ""
}

TENANT_ID=$(read_tenant_field "tenant_id")
LINUX_USER=$(read_tenant_field "linux_user")
AGENT_HOME=$(read_tenant_field "agent_home")
TENANT_VPS_HOST=$(read_tenant_field "vps_host")

[[ -z "${TENANT_ID}" ]] && { err "missing tenant_id in ${TENANT_YML}"; exit 1; }
[[ -z "${LINUX_USER}" ]] && LINUX_USER="${TENANT_ID}"
[[ -z "${AGENT_HOME}" ]] && AGENT_HOME="/opt/${LINUX_USER}/agents"
[[ -z "${VPS_HOST}" ]] && VPS_HOST="${TENANT_VPS_HOST}"

if [[ -z "${VPS_HOST}" && "${DRY_RUN}" -eq 0 ]]; then
  err "no VPS host. Either set vps_host in ${TENANT_YML} or pass --vps-host root@host"
  exit 1
fi

step "render-and-deploy — tenant: ${TENANT_ID}"
dim "  linux user: ${LINUX_USER}"
dim "  agent home: ${AGENT_HOME}"
dim "  vps host:   ${VPS_HOST:-<dry-run>}"
[[ "${DRY_RUN}" -eq 1 ]] && warn "DRY RUN — no VPS changes will be made"
[[ "${NO_RESTART}" -eq 1 ]] && warn "NO RESTART — service will not be restarted"

# ---------- step 1: render template ----------
step "1/5 rendering template"
bash "${REPO_ROOT}/vps-setup/scripts/render-tenant.sh" "${TENANT_YML}" >/dev/null
RENDERED_CLAUDE="${REPO_ROOT}/vps-setup/agents-config/${TENANT_ID}/CLAUDE.md"
[[ ! -f "${RENDERED_CLAUDE}" ]] && { err "render did not produce ${RENDERED_CLAUDE}"; exit 1; }
ok "rendered: ${RENDERED_CLAUDE} ($(wc -l <"${RENDERED_CLAUDE}") lines)"

# ---------- step 2: diff against current VPS state ----------
step "2/5 diffing rendered vs deployed"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  if [[ -n "${VPS_HOST}" ]]; then
    # Try to fetch current; if we can't, just show the rendered file
    TMPDEPLOYED=$(mktemp)
    if scp -q "${VPS_HOST}:${AGENT_HOME}/CLAUDE.md" "${TMPDEPLOYED}" 2>/dev/null; then
      if diff -u "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" >/dev/null 2>&1; then
        ok "rendered CLAUDE.md is identical to deployed — no-op"
      else
        warn "diff vs deployed:"
        diff -u "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" | head -60 || true
      fi
    else
      warn "could not reach VPS for diff; showing rendered head"
      head -10 "${RENDERED_CLAUDE}"
    fi
    rm -f "${TMPDEPLOYED}"
  else
    warn "no VPS host; showing rendered head"
    head -10 "${RENDERED_CLAUDE}"
  fi
  step "DRY RUN complete — exiting without VPS changes"
  exit 0
fi

# Fetch current deployed CLAUDE.md from VPS
TMPDEPLOYED=$(mktemp)
trap 'rm -f "${TMPDEPLOYED}"' EXIT

if scp -q "${VPS_HOST}:${AGENT_HOME}/CLAUDE.md" "${TMPDEPLOYED}" 2>/dev/null; then
  if diff -q "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" >/dev/null 2>&1; then
    ok "rendered CLAUDE.md is byte-identical to deployed — no copy + no restart needed"
    step "render-and-deploy complete (no-op)"
    exit 0
  fi
  ok "diff exists between rendered and deployed:"
  diff -u "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" | head -50 || true
else
  warn "could not fetch ${AGENT_HOME}/CLAUDE.md from VPS — proceeding to deploy"
fi

# ---------- step 3: copy to VPS ----------
step "3/5 copying rendered CLAUDE.md to VPS"

scp -q "${RENDERED_CLAUDE}" "${VPS_HOST}:/tmp/CLAUDE.md.staged"
ssh "${VPS_HOST}" "
  set -e
  install -m 644 -o '${LINUX_USER}' -g '${LINUX_USER}' \
    /tmp/CLAUDE.md.staged '${AGENT_HOME}/CLAUDE.md'
  rm -f /tmp/CLAUDE.md.staged
  echo \"deployed: \$(wc -l < ${AGENT_HOME}/CLAUDE.md) lines, mtime \$(stat -c %y ${AGENT_HOME}/CLAUDE.md)\"
"
ok "copied"

if [[ "${NO_RESTART}" -eq 1 ]]; then
  step "render-and-deploy complete — restart skipped per --no-restart"
  exit 0
fi

# ---------- step 4: pre-prune watchdog + restart ----------
step "4/5 pre-prune watchdog history + restart claude-agent.service"

ssh "${VPS_HOST}" "
  set -e
  # Pre-prune the watchdog history so manual restart doesn't trip the
  # circuit breaker (per operating-principles #5 / feedback_watchdog_breaker_collision).
  if [[ -f /var/lib/${LINUX_USER}/watchdog-restart-history.txt ]]; then
    OLD_LINES=\$(wc -l < /var/lib/${LINUX_USER}/watchdog-restart-history.txt)
    truncate -s 0 /var/lib/${LINUX_USER}/watchdog-restart-history.txt
    echo \"watchdog history pruned (was \${OLD_LINES} entries)\"
  fi
  systemctl restart claude-agent.service
  sleep 6
  STATUS=\$(systemctl is-active claude-agent.service)
  echo \"service status after restart: \${STATUS}\"
  if [[ \"\${STATUS}\" != \"active\" ]]; then
    echo \"[ERR] service failed to come up cleanly\" >&2
    journalctl -u claude-agent.service -n 30 --no-pager
    exit 1
  fi
"
ok "restarted clean"

# ---------- step 5: verify clean startup ----------
step "5/5 verifying clean startup (last 20 journal lines)"

ssh "${VPS_HOST}" "
  journalctl -u claude-agent.service -n 20 --no-pager
"

step "render-and-deploy complete"
ok "tenant: ${TENANT_ID}"
ok "rendered + copied + restarted"
dim "  to verify the agent's behavior changes: send a test prompt via your bot"
