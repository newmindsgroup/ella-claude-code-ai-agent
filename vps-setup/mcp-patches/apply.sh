#!/usr/bin/env bash
# apply.sh — re-apply every local MCP patch in this directory to both the
# Cowork copy (Mac) and the Agent copy (VPS). Idempotent: skips a patch if
# the change is already in the working tree.
#
# Usage:
#   bash vps-setup/mcp-patches/apply.sh
#   bash vps-setup/mcp-patches/apply.sh --cowork-only   # skip VPS
#   bash vps-setup/mcp-patches/apply.sh --vps-only      # skip Mac copy
set -uo pipefail

PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COWORK_REPO="$HOME/mcp-servers/GoHighLevel-MCP"
VPS_HOST="root@<your-vps-ip>"
VPS_REPO="/opt/{{TENANT_LINUX_USER}}/agents/ghl-mcp"
VPS_USER="${VPS_USER:-example-tenant}"

mode="${1:-}"

apply_to_local() {
  local repo="$1"
  if [[ ! -d "$repo/.git" ]]; then
    echo "  SKIP: $repo (not a git repo)"
    return 0
  fi
  local applied=0 skipped=0
  for p in "$PATCH_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    local name=$(basename "$p")
    if (cd "$repo" && git apply --check "$p") 2>/dev/null; then
      (cd "$repo" && git apply "$p") && {
        echo "  APPLIED $name"
        applied=$((applied+1))
      }
    else
      # check if it's already been applied (idempotent skip)
      if (cd "$repo" && git apply --reverse --check "$p") 2>/dev/null; then
        echo "  SKIP $name — already applied"
        skipped=$((skipped+1))
      else
        echo "  CONFLICT $name — manual review required"
      fi
    fi
  done
  echo "  summary for $repo: applied=$applied skipped=$skipped"
}

apply_to_vps() {
  local p
  for p in "$PATCH_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    local name=$(basename "$p")
    # Pipe patch over SSH to git apply on VPS
    if ssh "$VPS_HOST" "sudo -u $VPS_USER -H bash -c 'cd $VPS_REPO && git apply --check'" < "$p" 2>/dev/null; then
      ssh "$VPS_HOST" "sudo -u $VPS_USER -H bash -c 'cd $VPS_REPO && git apply'" < "$p" && \
        echo "  VPS APPLIED $name"
    elif ssh "$VPS_HOST" "sudo -u $VPS_USER -H bash -c 'cd $VPS_REPO && git apply --reverse --check'" < "$p" 2>/dev/null; then
      echo "  VPS SKIP $name — already applied"
    else
      echo "  VPS CONFLICT $name — manual review required"
    fi
  done
}

rebuild_local() {
  if [[ -d "$COWORK_REPO" ]] && [[ -f "$COWORK_REPO/package.json" ]]; then
    echo "Rebuilding Cowork MCP (npm run build)..."
    (cd "$COWORK_REPO" && npm run build 2>&1 | tail -3)
  fi
}

rebuild_vps() {
  echo "Rebuilding Agent MCP on VPS (npm run build)..."
  ssh "$VPS_HOST" "sudo -u $VPS_USER -H bash -c 'cd $VPS_REPO && npm run build 2>&1 | tail -3'"
  echo "Restarting claude-agent.service to load fresh MCP children..."
  ssh "$VPS_HOST" "systemctl restart claude-agent.service && sleep 2 && systemctl is-active claude-agent.service"
}

case "$mode" in
  --cowork-only)
    echo "=== Cowork (Mac) ==="
    apply_to_local "$COWORK_REPO"
    rebuild_local
    ;;
  --vps-only)
    echo "=== Agent (VPS) ==="
    apply_to_vps
    rebuild_vps
    ;;
  *)
    echo "=== Cowork (Mac) ==="
    apply_to_local "$COWORK_REPO"
    rebuild_local
    echo ""
    echo "=== Agent (VPS) ==="
    apply_to_vps
    rebuild_vps
    ;;
esac

echo ""
echo "Done. If you applied changes to the Cowork copy, also restart Claude Desktop"
echo "(Cmd+Q + reopen) so the running MCP server child loads the new dist/."
