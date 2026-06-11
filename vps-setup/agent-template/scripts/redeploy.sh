#!/usr/bin/env bash
# redeploy.sh — push the latest committed template code to the live agent,
# WITHOUT clobbering tenant state, secrets, or local modifications.
#
# Runs ON THE VPS (the agent can run it, or you over SSH). Pulls the brand repo,
# diff-copies rendered Layer-1 files into the live agent home, refreshes Python
# deps, restarts dashboard-chat. See docs/updating-deployments.md for the model.
#
# THREE-LAYER SAFETY (the whole point):
#   - Layer 1 (template code: scripts/, dashboard/, dashboard-chat/, swarms/,
#     rules/, crontab/, CLAUDE.md) → refreshed, but a file the agent locally
#     modified is BACKED UP + SKIPPED, never silently overwritten.
#   - Layer 2 (tenant config) → regenerated from tenant.yml on render, so values
#     are never lost.
#   - Layer 3 (state + secrets + local overrides: memory/, tasks/, drafts/,
#     goals/, state/, context/, notifications/, logs/, deploys/, obsidian-vault/,
#     .env, .mcp.json, .claude/, scripts/local/, CLAUDE.local.md) → never touched.
#
# Usage (on the VPS, as the {{TENANT_LINUX_USER}} user or via the agent):
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --dry-run    # show changes, touch nothing (DO THIS FIRST)
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh              # safe sync: locally-modified files backed up + skipped
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --force      # overwrite locally-modified files too (after backup)
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --with-agent # ALSO restart claude-agent (applies CLAUDE.md + plugin patches)
#   bash {{TENANT_AGENT_HOME}}/scripts/redeploy.sh --no-pull    # skip git pull (deploy already-pulled code)
#
# Idempotent. Self-update-safe (whole script is read into memory first; closing
# brace at EOF). Only restarts claude-agent with --with-agent (the bun-death
# circuit breaker dislikes casual restarts).
set -uo pipefail
{

AGENT_HOME="{{TENANT_AGENT_HOME}}"
BRAND_REPO_NAME="{{TENANT_BRAND_REPO_NAME}}"
TENANT_ID="{{TENANT_ID}}"
LINUX_USER="{{TENANT_LINUX_USER}}"
REPO="$AGENT_HOME/$BRAND_REPO_NAME"
RENDERED="$REPO/vps-setup/agents-config/$TENANT_ID"
OPS_RESTART="$AGENT_HOME/scripts/ops/ops-service-restart.sh"
MANIFEST="$AGENT_HOME/state/.deploy-manifest"          # Layer-1 baseline hashes (in Layer-3 state/, never synced)
BACKUP_DIR="$AGENT_HOME/backups/redeploy-$(date -u +%Y%m%dT%H%M%SZ)"

# Layer-1 directories to refresh. ops/ is privileged (reported, not copied);
# local/ is a Layer-3 overlay (never synced).
SYNC_DIRS=(scripts dashboard dashboard-chat swarms rules crontab)
# Single Layer-1 files (handled with the same guard).
SYNC_FILES=(CLAUDE.md)

WITH_AGENT=0; DO_PULL=1; DRY_RUN=0; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --with-agent) WITH_AGENT=1 ;;
    --no-pull)    DO_PULL=0 ;;
    --dry-run)    DRY_RUN=1 ;;
    --force)      FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "[redeploy] $*"; }
run() { if [[ $DRY_RUN -eq 1 ]]; then echo "  DRY: $*"; else eval "$*"; fi; }
sha() { [[ -f "$1" ]] && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; } || echo ""; }
base_hash() { grep -F "  $1" "$MANIFEST" 2>/dev/null | tail -1 | awk '{print $1}'; }

[[ ! -d "$REPO" ]] && { echo "FATAL: brand repo not found at $REPO" >&2; exit 1; }
[[ ! -d "$RENDERED" ]] && { echo "FATAL: rendered config not found at $RENDERED — run render-tenant.sh on your Mac + push, then pull here" >&2; exit 1; }

# ── 1. Pull latest ─────────────────────────────────────────────────────────
if [[ $DO_PULL -eq 1 ]]; then
  say "git pull in $REPO"
  if [[ $DRY_RUN -eq 0 ]]; then
    git -C "$REPO" stash push -u -q -m "redeploy-autostash-$(date -u +%s)" 2>/dev/null || true
    git -C "$REPO" pull --ff-only -q origin main && say "  pulled clean" || say "  WARN: ff-only pull failed; restoring local state"
    git -C "$REPO" stash pop -q 2>/dev/null || true
    # If the stash pop conflicted, git leaves conflict markers IN the working
    # tree — and we'd then sync those broken files into the live agent dirs
    # and publish a broken dashboard. Rendered files are generated output, so
    # HEAD is always the correct resolution: take HEAD for any unmerged path
    # and drop the now-stale stash entry.
    unmerged=$(git -C "$REPO" diff --name-only --diff-filter=U 2>/dev/null)
    if [[ -n "$unmerged" ]]; then
      say "  WARN: stash pop conflicted — resolving to HEAD (rendered files are generated):"
      while IFS= read -r f; do
        say "    $f"
        git -C "$REPO" checkout HEAD -- "$f" 2>/dev/null || true
      done <<< "$unmerged"
      git -C "$REPO" stash drop -q 2>/dev/null || true
    fi
  fi
else
  say "skipping git pull (--no-pull)"
fi

# ── 2. Safe sync with local-modification guard ─────────────────────────────
CHANGED=0; CONFLICTS=0; INSTALLED=0
NEW_MANIFEST="$(mktemp)"

# Decide + apply for a single file. The baseline manifest pins the hash of the
# last TEMPLATE version we deployed — never the live version — so a conflict
# persists across runs until the operator resolves it with --force.
sync_one() {
  local src="$1" target="$2" rel="$3"
  local new live base; new="$(sha "$src")"; live="$(sha "$target")"; base="$(base_hash "$rel")"

  if [[ ! -f "$target" ]]; then
    say "  install: $rel (new capability)"; INSTALLED=$((INSTALLED+1))
    if [[ $DRY_RUN -eq 0 ]]; then mkdir -p "$(dirname "$target")"; cp "$src" "$target"; fi
    echo "$new  $rel" >> "$NEW_MANIFEST"; return
  fi
  if [[ "$live" == "$new" ]]; then echo "$new  $rel" >> "$NEW_MANIFEST"; return; fi   # already current

  # live differs from new. Local-modified unless live matches the recorded
  # baseline. No baseline = we have no proof the live file came from us → treat
  # as modified (never clobber a file we can't vouch for) unless --force.
  local locally_modified=1
  [[ -n "$base" && "$live" == "$base" ]] && locally_modified=0

  if [[ $locally_modified -eq 1 && $FORCE -eq 0 ]]; then
    say "  ⚠ CONFLICT: $rel locally modified — backed up + SKIPPED (use --force to overwrite)"
    CONFLICTS=$((CONFLICTS+1))
    if [[ $DRY_RUN -eq 0 ]]; then mkdir -p "$(dirname "$BACKUP_DIR/$rel")"; cp "$target" "$BACKUP_DIR/$rel"; fi
    # Pin baseline to the OLD template version (if any) so the conflict persists
    # until resolved — do NOT adopt the live version as the new baseline.
    [[ -n "$base" ]] && echo "$base  $rel" >> "$NEW_MANIFEST"
    return
  fi

  # Safe to overwrite (live==base, or --force). Back up first if it was modified.
  if [[ $locally_modified -eq 1 ]]; then
    say "  overwrite (--force): $rel (local change backed up)"
    [[ $DRY_RUN -eq 0 ]] && { mkdir -p "$(dirname "$BACKUP_DIR/$rel")"; cp "$target" "$BACKUP_DIR/$rel"; }
  else
    say "  update: $rel"
  fi
  CHANGED=$((CHANGED+1))
  [[ $DRY_RUN -eq 0 ]] && { mkdir -p "$(dirname "$target")"; cp "$src" "$target"; }
  echo "$new  $rel" >> "$NEW_MANIFEST"
}

say "syncing Layer-1 (${SYNC_DIRS[*]} + ${SYNC_FILES[*]}); guarding local edits, skipping ops/ + local/"
for sub in "${SYNC_DIRS[@]}"; do
  src="$RENDERED/$sub"; [[ ! -d "$src" ]] && continue
  while IFS= read -r -d '' f; do
    rel="${f#$RENDERED/}"
    sync_one "$f" "$AGENT_HOME/$rel" "$rel"
  done < <(find "$src" -type f -not -path "*/ops/*" -not -path "*/local/*" -print0)
done
for file in "${SYNC_FILES[@]}"; do
  [[ -f "$RENDERED/$file" ]] && sync_one "$RENDERED/$file" "$AGENT_HOME/$file" "$file"
done

# Persist the updated baseline (skip on dry-run so nothing changes).
if [[ $DRY_RUN -eq 0 ]]; then mkdir -p "$(dirname "$MANIFEST")"; mv "$NEW_MANIFEST" "$MANIFEST"; else rm -f "$NEW_MANIFEST"; fi
say "  $CHANGED updated · $INSTALLED installed · $CONFLICTS conflict(s) backed up"

# ── 2b. Pending privileged ops/ wrapper changes (root-owned — report, never copy) ─
OPS_SRC="$RENDERED/scripts/ops"; OPS_DST="$AGENT_HOME/scripts/ops"; OPS_PENDING=()
if [[ -d "$OPS_SRC" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#$OPS_SRC/}"
    { [[ ! -f "$OPS_DST/$rel" ]] || ! cmp -s "$f" "$OPS_DST/$rel"; } && OPS_PENDING+=("$rel")
  done < <(find "$OPS_SRC" -type f -print0)
fi

# ── 3. Python deps for the FastAPI backend ─────────────────────────────────
REQ="$AGENT_HOME/dashboard-chat/requirements.txt"
[[ -f "$REQ" ]] && { say "pip install dashboard-chat deps"; run "pip3 install --break-system-packages -q -r '$REQ' 2>/dev/null || pip3 install --user --break-system-packages -q -r '$REQ' || true"; }

# ── 4. Restart dashboard-chat (runs the Python we just synced) ─────────────
if [[ $CHANGED -gt 0 || $INSTALLED -gt 0 || $DRY_RUN -eq 1 ]]; then
  say "restarting dashboard-chat"
  if [[ -x "$OPS_RESTART" ]]; then run "sudo '$OPS_RESTART' dashboard-chat --no-block 2>/dev/null || sudo '$OPS_RESTART' dashboard-chat"
  else run "sudo systemctl restart dashboard-chat.service"; fi
fi

# ── 5. Optionally restart claude-agent (CLAUDE.md / plugin patch changes) ──
if [[ $WITH_AGENT -eq 1 ]]; then
  say "restarting claude-agent (--with-agent) — applies CLAUDE.md + channel-plugin patches"
  if [[ -x "$OPS_RESTART" ]]; then run "sudo '$OPS_RESTART' claude-agent"; else run "sudo systemctl restart claude-agent.service"; fi
else
  say "claude-agent NOT restarted (pass --with-agent if CLAUDE.md or the channel plugin changed)"
fi

# ── 6. Report conflicts + pending privileged updates ───────────────────────
if [[ $CONFLICTS -gt 0 ]]; then
  say ""
  say "⚠ $CONFLICTS locally-modified file(s) were preserved (backed up to $BACKUP_DIR), NOT overwritten."
  say "  Review them. To accept the template version for those files, re-run with --force."
fi
if [[ ${#OPS_PENDING[@]} -gt 0 ]]; then
  say ""
  say "⚠ ${#OPS_PENDING[@]} privileged ops/ wrapper(s) have pending changes (root-owned, not auto-synced):"
  for rel in "${OPS_PENDING[@]}"; do say "    sudo cp '$OPS_SRC/$rel' '$OPS_DST/$rel'"; done
fi

say "done. $CHANGED updated, $INSTALLED installed, $CONFLICTS preserved.$([ ${#OPS_PENDING[@]} -gt 0 ] && echo " ${#OPS_PENDING[@]} ops wrapper(s) pending.")"

}  # end self-update safety group — see top of file
