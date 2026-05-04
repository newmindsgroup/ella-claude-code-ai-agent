#!/usr/bin/env bash
# task-update.sh — quick convenience wrapper for sub-agents
# Usage: task-update.sh ID STATE "message"
set -euo pipefail
ID="${1:?missing task id}"; STATE="${2:?missing state}"; MSG="${3:-}"
exec {{TENANT_AGENT_HOME}}/scripts/task-ledger.sh state --id "$ID" --state "$STATE" --msg "$MSG"
