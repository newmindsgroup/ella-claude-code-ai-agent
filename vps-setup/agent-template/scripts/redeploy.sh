#!/usr/bin/env bash
# redeploy.sh — one-command "push my latest committed code to the live agent".
#
# Runs ON THE VPS (the agent can run it, or you over SSH). Ends the manual
# file-by-file copy ritual: pull the brand repo, copy every rendered file from
# agents-config/<tenant>/ into the live agent home, refresh Python deps, and
# restart the dashboard-chat service.
#
# Why this exists: the live agent runs from {{TENANT_AGENT_HOME}}/ (scripts/,
# dashboard-chat/, etc.), but the SOURCE OF TRUTH is the rendered output in the
# brand repo clone at {{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/vps-setup/
# agents-config/{{TENANT_ID}}/. Without a single deploy step, those drift and
# you chase stale files one at a time. This is that step.
#
# Usage (on the VPS, as the {{TENANT_LINUX_USER}} user or via the agent):
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh                # scripts + dashboard-chat, restart dashboard-chat
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --with-agent   # ALSO restart claude-agent (applies CLAUDE.md + plugin patches)
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --no-pull      # skip git pull (deploy already-pulled code)
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --dry-run      # show what WOULD change, touch nothing
#
# Idempotent. Safe to re-run. Only restarts claude-agent if you pass
# --with-agent (respects the don't-batch-restart-claude-agent rule — that
# restart collides with the bun-death circuit breaker if done casually).

set -uo pipefail

# ── self-update safety ──────────────────────────────────────────────────────
# This script syncs scripts/ — which INCLUDES this file. Bash reads a script
# lazily (line by line as it executes), so if `cp` overwrites redeploy.sh
# mid-run, the next bytes bash reads come from the new file at the old offset →
# parse error. The `{ ... }` group around the entire body forces bash to read
# the WHOLE script into memory before executing a single line, so overwriting
# the file on disk during the run is harmless. The new version takes effect on
# the NEXT invocation. (Closing brace is at EOF.)
{

AGENT_HOME="{{TENANT_AGENT_HOME}}"
BRAND_REPO_NAME="{{TENANT_BRAND_REPO_NAME}}"
TENANT_ID="{{TENANT_ID}}"
LINUX_USER="{{TENANT_LINUX_USER}}"
REPO="$AGENT_HOME/$BRAND_REPO_NAME"
RENDERED="$REPO/vps-setup/agents-config/$TENANT_ID"
OPS_RESTART="$AGENT_HOME/scripts/ops/ops-service-restart.sh"

WITH_AGENT=0
DO_PULL=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --with-agent) WITH_AGENT=1 ;;
    --no-pull)    DO_PULL=0 ;;
    --dry-run)    DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "[redeploy] $*"; }
run() { if [[ $DRY_RUN -eq 1 ]]; then echo "  DRY: $*"; else eval "$*"; fi; }

[[ ! -d "$REPO" ]] && { echo "FATAL: brand repo not found at $REPO" >&2; exit 1; }
[[ ! -d "$RENDERED" ]] && { echo "FATAL: rendered config not found at $RENDERED — run render-tenant.sh on your Mac + push, then pull here" >&2; exit 1; }

# ── 1. Pull latest ─────────────────────────────────────────────────────────
if [[ $DO_PULL -eq 1 ]]; then
  say "git pull in $REPO"
  if [[ $DRY_RUN -eq 0 ]]; then
    git -C "$REPO" stash push -u -q -m "redeploy-autostash-$(date -u +%s)" 2>/dev/null || true
    if git -C "$REPO" pull --ff-only -q origin main; then
      say "  pulled clean"
    else
      say "  WARN: ff-only pull failed; trying to restore local state"
    fi
    git -C "$REPO" stash pop -q 2>/dev/null || true
  fi
else
  say "skipping git pull (--no-pull)"
fi

# ── 2. Diff + copy rendered files into the live agent home ─────────────────
# We sync scripts/ and dashboard-chat/ (the surfaces that drift). We do NOT
# touch tasks/, state/, logs/, notifications/, deploys/ — those are live data.
# We also SKIP scripts/ops/ — those wrappers are root-owned + sudoers-gated by
# design (the agent must not be able to rewrite its own privileged wrappers).
# Pending ops/ changes are reported at the end with the exact privileged
# command, never silently attempted (that just errors on root-owned files).
CHANGED=0
sync_dir() {
  local sub="$1"
  local src="$RENDERED/$sub"
  local dst="$AGENT_HOME/$sub"
  [[ ! -d "$src" ]] && { say "  ($sub not in rendered output — skip)"; return; }
  mkdir -p "$dst"
  # Copy each file; report which changed. Exclude ops/ (privileged, see below).
  while IFS= read -r -d '' f; do
    local rel="${f#$src/}"
    local target="$dst/$rel"
    if [[ ! -f "$target" ]] || ! cmp -s "$f" "$target"; then
      say "  changed: $sub/$rel"
      CHANGED=$((CHANGED+1))
      if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$(dirname "$target")"
        cp "$f" "$target"
      fi
    fi
  done < <(find "$src" -type f -not -path "*/ops/*" -print0)
}

say "syncing scripts/ + dashboard-chat/ (excluding privileged ops/ wrappers)"
sync_dir "scripts"
sync_dir "dashboard-chat"
say "  $CHANGED file(s) changed"

# ── 2b. Detect pending ops/ wrapper changes (privileged — report, don't copy) ─
OPS_SRC="$RENDERED/scripts/ops"
OPS_DST="$AGENT_HOME/scripts/ops"
OPS_PENDING=()
if [[ -d "$OPS_SRC" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#$OPS_SRC/}"
    if [[ ! -f "$OPS_DST/$rel" ]] || ! cmp -s "$f" "$OPS_DST/$rel"; then
      OPS_PENDING+=("$rel")
    fi
  done < <(find "$OPS_SRC" -type f -print0)
fi

# ── 3. Python deps for the FastAPI backend ─────────────────────────────────
REQ="$AGENT_HOME/dashboard-chat/requirements.txt"
if [[ -f "$REQ" ]]; then
  say "pip install dashboard-chat deps"
  run "pip3 install --break-system-packages -q -r '$REQ' 2>/dev/null || pip3 install --user --break-system-packages -q -r '$REQ' || true"
fi

# ── 4. Restart dashboard-chat (always — it runs the Python we just synced) ──
if [[ $CHANGED -gt 0 || $DRY_RUN -eq 0 ]]; then
  say "restarting dashboard-chat"
  if [[ -x "$OPS_RESTART" ]]; then
    run "sudo '$OPS_RESTART' dashboard-chat --no-block 2>/dev/null || sudo '$OPS_RESTART' dashboard-chat"
  else
    run "sudo systemctl restart dashboard-chat.service"
  fi
fi

# ── 5. Optionally restart claude-agent (CLAUDE.md / plugin patch changes) ──
if [[ $WITH_AGENT -eq 1 ]]; then
  say "restarting claude-agent (--with-agent) — applies CLAUDE.md + channel-plugin patches"
  if [[ -x "$OPS_RESTART" ]]; then
    run "sudo '$OPS_RESTART' claude-agent"
  else
    run "sudo systemctl restart claude-agent.service"
  fi
else
  say "claude-agent NOT restarted (pass --with-agent if you changed CLAUDE.md or the channel plugin)"
fi

# ── 6. Report pending privileged ops/ updates (operator runs these as root) ─
if [[ ${#OPS_PENDING[@]} -gt 0 ]]; then
  say ""
  say "⚠ ${#OPS_PENDING[@]} privileged ops/ wrapper(s) have pending changes (root-owned, not auto-synced):"
  for rel in "${OPS_PENDING[@]}"; do
    say "    scripts/ops/$rel"
  done
  say "  These are sudoers-gated by design. To apply, run as root (or with your sudo password):"
  for rel in "${OPS_PENDING[@]}"; do
    say "    sudo cp '$OPS_SRC/$rel' '$OPS_DST/$rel'"
  done
fi

say "done. $CHANGED file(s) synced.$([ ${#OPS_PENDING[@]} -gt 0 ] && echo " ${#OPS_PENDING[@]} ops wrapper(s) pending (see above).")"

}  # end self-update safety group — see top of file
