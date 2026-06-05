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
#   bash vps-setup/scripts/render-and-deploy.sh tenants/<tenant>.yml [--dry-run] [--no-restart] [--no-extras] [--vps-host root@host]
#
# Flags:
#   --dry-run     Render + show diff. Don't touch the VPS.
#   --no-restart  Render + copy to VPS but skip the service restart (for batched changes).
#   --no-extras   Only deploy CLAUDE.md (legacy mode). Skips scripts/, .claude/commands/,
#                 dashboard/, and skills-bundle/ sync.
#   --vps-host    Override the SSH target. Default: parsed from tenant.yml's vps_host field.
#
# What gets deployed by default (in this order):
#   1. CLAUDE.md → {AGENT_HOME}/CLAUDE.md          (restart on change)
#   2. scripts/*.{sh,py} → {AGENT_HOME}/scripts/   (no restart needed)
#   3. .claude/commands/*.md → {AGENT_HOME}/.claude/commands/ (no restart)
#   4. skills-bundle/* → {AGENT_HOME}/{AGENT_SKILLS_DIR}/ (no restart)
#   5. dashboard/index.html → /var/www/{DASHBOARD_HOSTNAME}/index.html (no restart)
#
# The agent service is restarted ONLY if CLAUDE.md changed — script/dashboard
# changes are picked up on next agent turn / next dashboard-sync timer tick.
#
# Idempotent. Safe to re-run. Per-file diff-vs-deployed so unchanged files
# don't trigger spurious writes. If everything is byte-identical, exits clean
# with "no-op".
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
NO_EXTRAS=0
VPS_HOST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-restart) NO_RESTART=1; shift ;;
    --no-extras) NO_EXTRAS=1; shift ;;
    --vps-host) VPS_HOST="$2"; shift 2 ;;
    --help|-h) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    -*) echo "[ERR] unknown flag: $1" >&2; exit 1 ;;
    *) TENANT_YML="$1"; shift ;;
  esac
done

[[ -z "${TENANT_YML}" ]] && { echo "usage: $0 <tenant.yml> [--dry-run] [--no-restart] [--no-extras] [--vps-host root@host]" >&2; exit 1; }
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
AGENT_SKILLS_DIR=$(read_tenant_field "agent_skills_dir")
DASHBOARD_HOSTNAME=$(read_tenant_field "dashboard_hostname")
TENANT_VPS_HOST=$(read_tenant_field "vps_host")

[[ -z "${TENANT_ID}" ]] && { err "missing tenant_id in ${TENANT_YML}"; exit 1; }
[[ -z "${LINUX_USER}" ]] && LINUX_USER="${TENANT_ID}"
[[ -z "${AGENT_HOME}" ]] && AGENT_HOME="/opt/${LINUX_USER}/agents"
[[ -z "${AGENT_SKILLS_DIR}" ]] && AGENT_SKILLS_DIR="agent-skills"
[[ -z "${VPS_HOST}" ]] && VPS_HOST="${TENANT_VPS_HOST}"

if [[ -z "${VPS_HOST}" && "${DRY_RUN}" -eq 0 ]]; then
  err "no VPS host. Either set vps_host in ${TENANT_YML} or pass --vps-host root@host"
  exit 1
fi

step "render-and-deploy — tenant: ${TENANT_ID}"
dim "  linux user:  ${LINUX_USER}"
dim "  agent home:  ${AGENT_HOME}"
dim "  skills dir:  ${AGENT_HOME}/${AGENT_SKILLS_DIR}"
dim "  dashboard:   ${DASHBOARD_HOSTNAME:-<unset>}"
dim "  vps host:    ${VPS_HOST:-<dry-run>}"
[[ "${DRY_RUN}" -eq 1 ]] && warn "DRY RUN — no VPS changes will be made"
[[ "${NO_RESTART}" -eq 1 ]] && warn "NO RESTART — service will not be restarted"
[[ "${NO_EXTRAS}" -eq 1 ]] && warn "NO EXTRAS — only CLAUDE.md will be deployed (legacy mode)"

# ---------- step 1: render template ----------
step "1/6 rendering template"
bash "${REPO_ROOT}/vps-setup/scripts/render-tenant.sh" "${TENANT_YML}" >/dev/null
RENDERED_DIR="${REPO_ROOT}/vps-setup/agents-config/${TENANT_ID}"
RENDERED_CLAUDE="${RENDERED_DIR}/CLAUDE.md"
[[ ! -f "${RENDERED_CLAUDE}" ]] && { err "render did not produce ${RENDERED_CLAUDE}"; exit 1; }
ok "rendered: ${RENDERED_DIR}/ ($(wc -l <"${RENDERED_CLAUDE}") lines in CLAUDE.md)"

# ---------- step 2: diff CLAUDE.md vs deployed ----------
step "2/6 diffing CLAUDE.md vs deployed"

CLAUDE_CHANGED=0
TMPDEPLOYED=$(mktemp)
trap 'rm -f "${TMPDEPLOYED}"' EXIT

if [[ "${DRY_RUN}" -eq 1 ]]; then
  if [[ -n "${VPS_HOST}" ]]; then
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
  else
    warn "no VPS host; showing rendered head"
    head -10 "${RENDERED_CLAUDE}"
  fi
  step "DRY RUN complete — exiting without VPS changes"
  exit 0
fi

if scp -q "${VPS_HOST}:${AGENT_HOME}/CLAUDE.md" "${TMPDEPLOYED}" 2>/dev/null; then
  if diff -q "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" >/dev/null 2>&1; then
    ok "CLAUDE.md byte-identical to deployed — no copy + no restart needed"
  else
    CLAUDE_CHANGED=1
    ok "CLAUDE.md differs from deployed:"
    diff -u "${TMPDEPLOYED}" "${RENDERED_CLAUDE}" | head -50 || true
  fi
else
  CLAUDE_CHANGED=1
  warn "could not fetch ${AGENT_HOME}/CLAUDE.md from VPS — will deploy"
fi

# ---------- step 3: copy CLAUDE.md (if changed) ----------
if [[ "${CLAUDE_CHANGED}" -eq 1 ]]; then
  step "3/6 copying CLAUDE.md to VPS"
  scp -q "${RENDERED_CLAUDE}" "${VPS_HOST}:/tmp/CLAUDE.md.staged"
  ssh "${VPS_HOST}" "
    set -e
    install -m 644 -o '${LINUX_USER}' -g '${LINUX_USER}' \
      /tmp/CLAUDE.md.staged '${AGENT_HOME}/CLAUDE.md'
    rm -f /tmp/CLAUDE.md.staged
    echo \"deployed: \$(wc -l < ${AGENT_HOME}/CLAUDE.md) lines, mtime \$(stat -c %y ${AGENT_HOME}/CLAUDE.md)\"
  "
  ok "CLAUDE.md copied"
else
  step "3/6 CLAUDE.md unchanged — skip copy"
fi

# ---------- step 4: sync ancillary artifacts ----------
if [[ "${NO_EXTRAS}" -eq 1 ]]; then
  step "4/6 ancillary sync skipped per --no-extras"
else
  step "4/6 syncing scripts, slash commands, skills, dashboard"

  # Build a tarball of all the syncable artifacts (only ones that exist).
  TARBALL=$(mktemp -t render-deploy-XXXXXX.tar.gz)
  trap 'rm -f "${TMPDEPLOYED}" "${TARBALL}"' EXIT

  TAR_ARGS=()
  [[ -d "${RENDERED_DIR}/scripts" ]] && TAR_ARGS+=( "scripts" )
  [[ -d "${RENDERED_DIR}/.claude/commands" ]] && TAR_ARGS+=( ".claude/commands" )
  [[ -d "${RENDERED_DIR}/skills-bundle" ]] && TAR_ARGS+=( "skills-bundle" )

  if [[ ${#TAR_ARGS[@]} -gt 0 ]]; then
    # COPYFILE_DISABLE=1 + --no-xattrs suppress macOS BSD-tar from packing
    # com.apple.provenance xattrs that GNU tar on the VPS noisily warns about.
    # --exclude='._*' drops AppleDouble resource forks if they ever appear locally.
    (cd "${RENDERED_DIR}" && COPYFILE_DISABLE=1 tar --no-xattrs --exclude='._*' -czf "${TARBALL}" "${TAR_ARGS[@]}" 2>/dev/null) || true
    SIZE_KB=$(du -k "${TARBALL}" | awk '{print $1}')
    dim "  tarball: ${SIZE_KB}KB, ${#TAR_ARGS[@]} top-level dirs"

    scp -q "${TARBALL}" "${VPS_HOST}:/tmp/agent-sync.tar.gz"

    # Remote: extract to scratch, then per-file diff + install. Tracks change count.
    ssh "${VPS_HOST}" "
      set -e
      TEMP_DIR=\$(mktemp -d)
      tar xzf /tmp/agent-sync.tar.gz -C \"\${TEMP_DIR}\"

      SCRIPT_CHANGED=0
      CMD_CHANGED=0
      SKILL_CHANGED=0

      # scripts/*.sh, scripts/*.py
      if [[ -d \"\${TEMP_DIR}/scripts\" ]]; then
        mkdir -p '${AGENT_HOME}/scripts'
        for f in \"\${TEMP_DIR}/scripts\"/*; do
          [[ -f \"\$f\" ]] || continue
          base=\$(basename \"\$f\")
          target='${AGENT_HOME}/scripts/'\"\${base}\"
          MODE=644
          [[ \"\${base}\" == *.sh ]] && MODE=755
          [[ \"\${base}\" == *.py ]] && MODE=755
          if [[ ! -f \"\$target\" ]] || ! diff -q \"\$f\" \"\$target\" >/dev/null 2>&1; then
            install -m \${MODE} -o '${LINUX_USER}' -g '${LINUX_USER}' \"\$f\" \"\$target\"
            SCRIPT_CHANGED=\$((SCRIPT_CHANGED+1))
          fi
        done
      fi

      # .claude/commands/*.md (first slash command in either repo lives here)
      if [[ -d \"\${TEMP_DIR}/.claude/commands\" ]]; then
        mkdir -p '${AGENT_HOME}/.claude/commands'
        chown '${LINUX_USER}:${LINUX_USER}' '${AGENT_HOME}/.claude/commands'
        for f in \"\${TEMP_DIR}/.claude/commands\"/*; do
          [[ -f \"\$f\" ]] || continue
          base=\$(basename \"\$f\")
          target='${AGENT_HOME}/.claude/commands/'\"\${base}\"
          if [[ ! -f \"\$target\" ]] || ! diff -q \"\$f\" \"\$target\" >/dev/null 2>&1; then
            install -m 644 -o '${LINUX_USER}' -g '${LINUX_USER}' \"\$f\" \"\$target\"
            CMD_CHANGED=\$((CMD_CHANGED+1))
          fi
        done
      fi

      # skills-bundle/* → {AGENT_SKILLS_DIR}/<skill>/
      if [[ -d \"\${TEMP_DIR}/skills-bundle\" ]]; then
        mkdir -p '${AGENT_HOME}/${AGENT_SKILLS_DIR}'
        for d in \"\${TEMP_DIR}/skills-bundle\"/*/; do
          [[ -d \"\$d\" ]] || continue
          name=\$(basename \"\$d\")
          target_dir='${AGENT_HOME}/${AGENT_SKILLS_DIR}/'\"\${name}\"
          if [[ ! -d \"\$target_dir\" ]] || ! diff -rq \"\$d\" \"\$target_dir\" >/dev/null 2>&1; then
            mkdir -p \"\$target_dir\"
            cp -R \"\$d\"/* \"\$target_dir/\"
            chown -R '${LINUX_USER}:${LINUX_USER}' \"\$target_dir\"
            SKILL_CHANGED=\$((SKILL_CHANGED+1))
          fi
        done
      fi

      rm -rf \"\${TEMP_DIR}\" /tmp/agent-sync.tar.gz
      echo \"  scripts: \${SCRIPT_CHANGED} updated\"
      echo \"  /commands: \${CMD_CHANGED} updated\"
      echo \"  skills:  \${SKILL_CHANGED} updated\"
    "
  else
    dim "  no scripts/, .claude/commands/, or skills-bundle/ in render — nothing to sync"
  fi

  # Dashboard index.html: distinct target (/var/www) + ownership (www-data)
  if [[ -f "${RENDERED_DIR}/dashboard/index.html" && -n "${DASHBOARD_HOSTNAME}" ]]; then
    scp -q "${RENDERED_DIR}/dashboard/index.html" "${VPS_HOST}:/tmp/index.html.staged"
    ssh "${VPS_HOST}" "
      set -e
      TARGET='/var/www/${DASHBOARD_HOSTNAME}/index.html'
      if [[ ! -f \"\$TARGET\" ]] || ! diff -q /tmp/index.html.staged \"\$TARGET\" >/dev/null 2>&1; then
        install -m 644 -o www-data -g www-data /tmp/index.html.staged \"\$TARGET\"
        echo \"  dashboard: updated (\$(wc -l < \"\$TARGET\") lines)\"
      else
        echo '  dashboard: unchanged'
      fi
      rm -f /tmp/index.html.staged
    "
  elif [[ -z "${DASHBOARD_HOSTNAME}" ]]; then
    dim "  dashboard: skipped (no dashboard_hostname in tenant.yml)"
  fi
fi

# ---------- step 5: pre-prune watchdog + restart (only if CLAUDE.md changed) ----------
if [[ "${CLAUDE_CHANGED}" -eq 0 ]]; then
  step "render-and-deploy complete — CLAUDE.md unchanged, no restart needed"
  ok "tenant: ${TENANT_ID}"
  exit 0
fi

if [[ "${NO_RESTART}" -eq 1 ]]; then
  step "render-and-deploy complete — restart skipped per --no-restart"
  exit 0
fi

step "5/6 pre-prune watchdog history + restart claude-agent.service"

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

# ---------- step 6: verify clean startup ----------
step "6/6 verifying clean startup (last 20 journal lines)"

ssh "${VPS_HOST}" "
  journalctl -u claude-agent.service -n 20 --no-pager
"

step "render-and-deploy complete"
ok "tenant: ${TENANT_ID}"
ok "rendered + copied + restarted"
dim "  to verify the agent's behavior changes: send a test prompt via your bot"
