#!/usr/bin/env bash
# graphify-semantic.sh — monthly *semantic* knowledge-graph refresh.
#
# The weekly graphify-rebuild.timer is AST-only (free, structural). Semantic
# extraction (richer INFERRED concept edges) is LLM-driven via the /graphify
# skill, so it costs tokens — this is the affordable, opt-in autonomous cadence.
#
# Safe by default: does NOTHING unless BOTH are true:
#   1. opt-in marker exists:  $AGENT_HOME/state/semantic-rebuild-enabled
#   2. frugal mode is OFF:     $AGENT_HOME/state/frugal-mode absent
#
# To enable:  touch {{TENANT_AGENT_HOME}}/state/semantic-rebuild-enabled
# To make it 3x cheaper: set MOONSHOT_API_KEY in claude-agent.service's
#   Environment (the /graphify skill auto-uses the Kimi K2.6 backend) and
#   `pip install 'graphifyy[kimi]'` in graphify's environment.
#
# When enabled, it dispatches a background agent job to run /graph-rebuild
# (semantic re-extraction of project+memory+scripts, then re-merge).
set -uo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp
LOG_FILE="$AGENT_HOME/logs/graphify-semantic-$(date -u +%Y-%m-%d).log"
DISPATCH="$AGENT_HOME/scripts/dispatch-job.sh"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG_FILE" >&2; }

log "=== graphify-semantic started ==="

# Gate 1: opt-in marker (default OFF — no surprise spend)
if [[ ! -f "$AGENT_HOME/state/semantic-rebuild-enabled" ]]; then
  log "not opted in (no state/semantic-rebuild-enabled) — skipping. touch it to enable."
  exit 0
fi
# Gate 2: frugal mode
if [[ -f "$AGENT_HOME/state/frugal-mode" ]]; then
  log "frugal mode ON — skipping semantic rebuild this cycle."
  exit 0
fi

KIMI_NOTE="Claude subagents"
[[ -n "${MOONSHOT_API_KEY:-}" ]] && KIMI_NOTE="Kimi K2.6 (cheap)"

PROMPT="Run a semantic knowledge-graph refresh now: execute the /graph-rebuild command exactly as defined in CLAUDE.md (semantic re-extraction of the project repo, memory, and scripts via the /graphify skill in --update mode, then re-merge into graphify-out/merged-graph.json). If MOONSHOT_API_KEY is set in your environment, use the Kimi backend for cheaper extraction. When done, report the before/after merged node counts. This is the monthly autonomous semantic cadence."

if [[ -x "$DISPATCH" ]]; then
  "$DISPATCH" --title "Monthly semantic graph rebuild" --prompt "$PROMPT" >> "$LOG_FILE" 2>&1 \
    && log "dispatched semantic rebuild job ($KIMI_NOTE)" \
    || { log "dispatch failed"; [[ -x "$TG_SEND" ]] && "$TG_SEND" send --text "⚠️ Monthly semantic graph rebuild failed to dispatch — see $LOG_FILE" >/dev/null 2>&1 || true; }
else
  log "dispatch-job.sh missing — cannot run semantic rebuild"
fi

log "=== done ==="
