#!/usr/bin/env bash
# morning-brief.sh — orchestrates the daily Telegram brief.
# Invokes morning-brief.py which produces a single rich HTML message
# (greeting + weather + verse + agent status + LLM-pulled snapshot +
# priorities + pending drafts + goals + deadlines + insight + buttons).
#
# Triggered by morning-brief.timer at {{TENANT_MORNING_BRIEF_TIME}} {{TENANT_TIMEZONE}}.
# Safe to run manually any time.
set -euo pipefail

cd {{TENANT_AGENT_HOME}}

DATE=$(date +%Y-%m-%d)
LOG_DIR="{{TENANT_AGENT_HOME}}/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/morning-brief-${DATE}.log"

echo "=== morning-brief.sh run started at $(date -Iseconds) ===" | tee -a "$LOG"

python3 {{TENANT_AGENT_HOME}}/scripts/morning-brief.py "$@" >>"$LOG" 2>&1 || {
  TG="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"
  "$TG" send --md --text $'\xe2\x9a\xa0\xef\xb8\x8f *Morning brief failed* \xe2\x80\x94 see `'"$LOG"$'`' || true
  exit 1
}

echo "=== morning-brief.sh done at $(date -Iseconds) ===" | tee -a "$LOG"
