#!/usr/bin/env bash
# evening-rollup.sh — end-of-day status to Telegram. Mirror of morning-brief, looks back.
set -euo pipefail

cd {{TENANT_AGENT_HOME}}
DATE=$(date +%Y-%m-%d)
DAY=$(date +%A)
LOG_DIR="{{TENANT_AGENT_HOME}}/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/evening-rollup-${DATE}.log"
WORK="$LOG_DIR/rollup-work-${DATE}"
mkdir -p "$WORK"

TG="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"

echo "=== evening-rollup run started at $(date -Iseconds) ===" | tee -a "$LOG"
"$TG" send --md --text $'_Composing your end\\-of\\-day rollup\\.\\.\\._' >>"$LOG" 2>&1

PROMPT=$(cat <<'PEOF'
End of day for {{TENANT_PERSON_FIRST_NAME}}. It is __DAY__, __DATE__ — compose the evening rollup as TWO MarkdownV2 messages.

Write to:
- __WORK__/msg1.md (today's wins + state changes)
- __WORK__/msg2.md (what's still open going into tomorrow + top priority for tomorrow)

Pull data:
- Read {{TENANT_AGENT_HOME}}/tasks/active.json — the task ledger.
- Read today's morning brief log if it exists at {{TENANT_AGENT_HOME}}/logs/morning-brief-__DATE__.log
- Read {{TENANT_AGENT_HOME}}/logs/brief-work-__DATE__/ if present (today's morning brief msgs).
- Pull pipeline movement today via mcp__ghl__search_opportunities (changed status today).
- Pull today's calendar — what happened, what was missed.

msg1.md format (MarkdownV2, escape special chars):
*Day rollup — __DATE__*

`Today's wins`
- one line per task that moved to done today (from active.json events with state=done and ts startsWith __DATE__)

`State changes`
- one line per task that changed state today (created, in_progress, awaiting_review)

If no movement today: write *Quiet day — nothing closed, nothing started.*

msg2.md format:
*Carrying into tomorrow*

`Open tasks` (count + top 3 by oldest updated_at, awaiting_review and in_progress only)

> *Tomorrow's priority:* (single sentence — pick the most-urgent open task or impending deadline)

Voice: {{TENANT_PERSON_FIRST_NAME}}'s brand voice. Sage, direct, factual. No hype. No emojis. Numbers and names.

Entity rule: never mention {{TENANT_ENTITY_TERM_1}}, {{TENANT_ENTITY_TERM_2}}, {{TENANT_ENTITY_TERM_3}}, {{TENANT_ENTITY_TERM_4}}.

After writing both files, output one line: ROLLUP_READY.
PEOF
)

PROMPT="${PROMPT//__DATE__/$DATE}"
PROMPT="${PROMPT//__DAY__/$DAY}"
PROMPT="${PROMPT//__WORK__/$WORK}"

claude --permission-mode dontAsk --print "$PROMPT" >>"$LOG" 2>&1 || {
  "$TG" send --md --text $'\xe2\x9a\xa0\xef\xb8\x8f *Rollup composition failed* \xe2\x80\x94 see log\\.'
  exit 1
}

for i in 1 2; do
  if [[ -f "${WORK}/msg${i}.md" ]]; then
    text=$(cat "${WORK}/msg${i}.md")
    if [[ -n "$text" ]]; then
      "$TG" send --md --text "$text" >>"$LOG" 2>&1
      sleep 2
    fi
  fi
done
echo "=== evening-rollup done at $(date -Iseconds) ===" | tee -a "$LOG"
