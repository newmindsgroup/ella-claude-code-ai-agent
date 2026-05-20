#!/usr/bin/env bash
# jobs-status.sh — show running + recently-finished background jobs.
# Backs the /jobs Telegram command. Read-only.
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp
ACTIVE_DIR="$AGENT_HOME/jobs/active"
DONE_DIR="$AGENT_HOME/jobs/done"

now=$(date -u +%s)
age() {  # humanize seconds-ago from an ISO timestamp
  local iso="$1" then
  then=$(date -d "$iso" +%s 2>/dev/null || echo "$now")
  local d=$((now - then))
  if   [[ $d -lt 60 ]];   then echo "${d}s ago"
  elif [[ $d -lt 3600 ]]; then echo "$((d/60))m ago"
  else echo "$((d/3600))h ago"; fi
}

echo "🔄 Background jobs"
echo

running=$(find "$ACTIVE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$running" -gt 0 ]]; then
  echo "Running ($running):"
  for f in "$ACTIVE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    title=$(jq -r '.title' "$f")
    started=$(jq -r '.started_at' "$f")
    executor=$(jq -r '.executor' "$f")
    echo "  ⏳ $title — $executor, started $(age "$started")"
  done
  echo
else
  echo "Running: none"
  echo
fi

# Last 5 finished
recent=$(ls -t "$DONE_DIR"/*.json 2>/dev/null | head -5)
if [[ -n "$recent" ]]; then
  echo "Recently finished:"
  for f in $recent; do
    title=$(jq -r '.title' "$f")
    status=$(jq -r '.status' "$f")
    finished=$(jq -r '.finished_at // .started_at' "$f")
    case "$status" in
      done) icon="✅" ;; timeout) icon="⏱️" ;; *) icon="⚠️" ;;
    esac
    echo "  $icon $title — $status, $(age "$finished")"
  done
fi
