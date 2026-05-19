#!/usr/bin/env bash
# signal-edit.sh — log a pattern from Daniel editing a draft.
# Usage: signal-edit.sh --text "Daniel cut X and replaced with Y" [--task TASK_ID] [--platform linkedin|email|newsletter]
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
text="" task_id="" platform=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)     text="$2";     shift 2 ;;
    --task)     task_id="$2";  shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

[[ -z "$text" ]] && { echo "missing --text" >&2; exit 1; }

full_text="Edit signal: $text"
[[ -n "$task_id" ]]  && full_text="${full_text} [draft: ${task_id}]"
[[ -n "$platform" ]] && full_text="${full_text} [platform: ${platform}]"

tags="pattern,editing,voice,drafting"
[[ -n "$platform" ]] && tags="${tags},${platform}"

MEM_DIR="${AGENT_HOME}/memory" bash "${AGENT_HOME}/scripts/memory-vault.sh" add \
  --type pattern \
  --text "$full_text" \
  --tags "$tags" \
  --source "daniel-edit-signal" \
  --confidence 0.99
