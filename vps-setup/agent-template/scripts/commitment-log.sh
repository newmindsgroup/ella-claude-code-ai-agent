#!/usr/bin/env bash
# commitment-log.sh — log a promise {{TENANT_PERSON_FIRST_NAME}} made to a person/company.
# Usage: commitment-log.sh --to "Name" --text "promised X by Y" [--deadline DATE] [--task TASK_ID]
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
to="" text="" deadline="" task_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)       to="$2";       shift 2 ;;
    --text)     text="$2";     shift 2 ;;
    --deadline) deadline="$2"; shift 2 ;;
    --task)     task_id="$2";  shift 2 ;;
    *)          shift ;;
  esac
done

[[ -z "$text" ]] && { echo "missing --text" >&2; exit 1; }

full_text="$text"
[[ -n "$to" ]]       && full_text="To ${to}: ${full_text}"
[[ -n "$deadline" ]] && full_text="${full_text} (deadline: ${deadline})"
[[ -n "$task_id" ]]  && full_text="${full_text} [task: ${task_id}]"

tags="commitment"
[[ -n "$to" ]] && tags="${tags},$(echo "$to" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

MEM_DIR="${AGENT_HOME}/memory" bash "${AGENT_HOME}/scripts/memory-vault.sh" add \
  --type commitment \
  --text "$full_text" \
  --tags "$tags" \
  --source "commitment-log" \
  --confidence 0.95
