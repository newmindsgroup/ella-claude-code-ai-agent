#!/usr/bin/env bash
# graphify-rebuild.sh — weekly safety-net rebuild of the project-repo
# Graphify knowledge graph. AST-only (no LLM, no API cost). Picks up
# any new Python/TypeScript/JS files added since last run, refreshes
# the graph timestamp, regenerates GRAPH_REPORT.md.
#
# CLAUDE.md already instructs the agent to call `graphify update .`
# after code changes — but that's relies on the agent doing it
# proactively. This timer is the safety net for everything else
# (commits via desktop, edits made outside agent sessions).
#
# Memory + scripts graphs are NOT rebuilt here — those need the full
# /graphify pipeline (LLM-driven), which is expensive. Run on-demand
# via the agent's `/graphify` skill.
#
# Schedule: weekly (Sunday 03:00 SD). Cheap to run, max benefit.
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
REPO_PATH="$TENANT_AGENT_HOME/{{TENANT_BRAND_REPO_NAME}}"
LOG_FILE="$TENANT_AGENT_HOME/logs/graphify-rebuild-$(date -u +%Y-%m-%d).log"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG_FILE" >&2; }

log "=== graphify-rebuild started — path: $REPO_PATH ==="

[[ ! -d "$REPO_PATH" ]] && { log "ERROR: repo not found at $REPO_PATH"; exit 1; }

cd "$REPO_PATH"

# Capture stats before + after
BEFORE_NODES=0
BEFORE_LINKS=0
if [[ -f "$REPO_PATH/graphify-out/graph.json" ]]; then
  BEFORE_NODES=$(jq '.nodes | length' "$REPO_PATH/graphify-out/graph.json" 2>/dev/null || echo 0)
  BEFORE_LINKS=$(jq '.links | length' "$REPO_PATH/graphify-out/graph.json" 2>/dev/null || echo 0)
fi
log "before: $BEFORE_NODES nodes, $BEFORE_LINKS links"

# Run the AST-only update. GRAPHIFY_FORCE=1 lets us overwrite even if
# the new graph has fewer nodes (e.g. after a deletion refactor).
if ! GRAPHIFY_FORCE=1 graphify update . >> "$LOG_FILE" 2>&1; then
  log "ERROR: graphify update failed"
  # Notify on failure
  "$TG_SEND" send --text "⚠️ Weekly graphify-rebuild failed. Check $LOG_FILE" 2>/dev/null || true
  exit 1
fi

AFTER_NODES=$(jq '.nodes | length' "$REPO_PATH/graphify-out/graph.json" 2>/dev/null || echo 0)
AFTER_LINKS=$(jq '.links | length' "$REPO_PATH/graphify-out/graph.json" 2>/dev/null || echo 0)

NODE_DELTA=$((AFTER_NODES - BEFORE_NODES))
LINK_DELTA=$((AFTER_LINKS - BEFORE_LINKS))

log "after:  $AFTER_NODES nodes, $AFTER_LINKS links (Δ ${NODE_DELTA:+}$NODE_DELTA nodes, ${LINK_DELTA:+}$LINK_DELTA links)"

# Only notify on significant changes (>10 nodes/links delta) to avoid
# weekly low-value pings.
if [[ ${NODE_DELTA#-} -gt 10 || ${LINK_DELTA#-} -gt 10 ]]; then
  "$TG_SEND" send --text "📊 Graphify weekly rebuild: ${BEFORE_NODES}→${AFTER_NODES} nodes (Δ${NODE_DELTA}), ${BEFORE_LINKS}→${AFTER_LINKS} links (Δ${LINK_DELTA}). Project repo graph refreshed." 2>/dev/null || true
fi

log "=== done ==="
