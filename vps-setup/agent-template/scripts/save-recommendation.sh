#!/usr/bin/env bash
# save-recommendation.sh — explicitly save a significant agent recommendation to memory.
# Call this after delivering a multi-step plan, key finding, or strategic recommendation.
#
# Usage:
#   bash save-recommendation.sh --text "Recommended X because Y" --tags "topic,area"

set -euo pipefail

text=""
tags="agent-recommendation"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text) text="$2"; shift 2 ;;
    --tags) tags="agent-recommendation,$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$text" ]]; then
  echo "Usage: save-recommendation.sh --text '...' [--tags 'tag1,tag2']" >&2
  exit 1
fi

bash {{TENANT_AGENT_HOME}}/scripts/memory-vault.sh add \
  --type context \
  --text "$text" \
  --tags "$tags" \
  --source "agent-recommendation" \
  --confidence 0.9
