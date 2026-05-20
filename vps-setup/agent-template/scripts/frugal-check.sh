#!/usr/bin/env bash
# frugal-check.sh — sourceable guard for LLM-using watchers.
#
# Usage at the top of any watcher that makes claude --print calls:
#   source "$AGENT_HOME/scripts/frugal-check.sh"
#   frugal_guard "watcher-name" || exit 0
#
# When frugal mode is on (spend-guard.sh set the flag because the daily
# LLM ceiling was breached), frugal_guard returns 1 → the watcher exits
# early, skipping its expensive LLM call. Deterministic watchers don't
# need this; only the ones that spend tokens.
#
# Frugal mode auto-clears when the daily budget resets (spend-guard
# removes the flag once today's cost is back under the ceiling).

frugal_guard() {
  local name="${1:-watcher}"
  local agent_home="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
  local flag="$agent_home/state/frugal-mode"
  if [[ -f "$flag" ]]; then
    echo "[$(date -u +%FT%TZ)] [frugal] $name skipped — daily LLM spend ceiling reached (frugal mode on)" >&2
    return 1
  fi
  return 0
}
