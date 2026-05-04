#!/usr/bin/env bash
# deploy-resume-nudge.sh — on claude-agent.service start, scan deploys/ for
# any state files in `ready_to_ship` and Telegram-nudge so deploys aren't
# orphaned across an agent restart.
#
# v2.25.0+. Wired as ExecStartPost on claude-agent.service. Runs after the
# new claude session is up. Outbound Telegram (curl-based via tg-send.sh)
# works even before the bun poller comes back, so the ping reaches Daniel
# regardless of inbound channel state.
#
# Idempotent via a `last_resume_nudge_at` field added to the state file —
# we don't re-ping the same deploy on every restart cycle. Only nudge if
# more than 30 minutes have passed since the last nudge for this version.
#
# This complements deploy-timeout-sweep.timer (which auto-cancels after
# 2hr): if Daniel's been gone for an hour and the agent restarted, the
# nudge tells him "still here, waiting"; if the deploy hits 2hr untapped,
# the sweep cancels it cleanly.

set -uo pipefail

STATE_DIR="{{TENANT_AGENT_HOME}}/deploys"
TG_SEND="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"
LOG="/var/log/{{TENANT_LINUX_USER}}-deploy-resume.log"
RENUDGE_THRESHOLD_SEC=$((30 * 60))  # don't re-ping the same version more often than 30min

[[ ! -d "$STATE_DIR" ]] && exit 0

log() {
  local target="$LOG"
  if ! { : >> "$target"; } 2>/dev/null; then
    target="/tmp/$(basename "$LOG")"
  fi
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$target" >&2
}

mdv2_esc() {
  sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' \
      -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' \
      -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' \
      -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' \
      -e 's/}/\\}/g' -e 's/\./\\./g' -e 's/!/\\!/g' <<< "$1"
}

now_epoch=$(date +%s)
nudged=0

shopt -s nullglob
for f in "$STATE_DIR"/*.state.json; do
  phase=$(jq -r '.phase // ""' "$f" 2>/dev/null)
  [[ "$phase" != "ready_to_ship" ]] && continue

  version=$(jq -r '.version // ""' "$f" 2>/dev/null)
  [[ -z "$version" ]] && continue

  # When did we last nudge this deploy? If <30min ago, skip — Daniel just
  # got a ping; agent probably just restarted briefly (watchdog cycle).
  last_nudge=$(jq -r '.last_resume_nudge_at // ""' "$f" 2>/dev/null)
  if [[ -n "$last_nudge" ]]; then
    last_epoch=$(date -d "$last_nudge" +%s 2>/dev/null || echo 0)
    if [[ $((now_epoch - last_epoch)) -lt $RENUDGE_THRESHOLD_SEC ]]; then
      log "skipping nudge for $version — last nudged $(( (now_epoch - last_epoch) / 60 ))min ago"
      continue
    fi
  fi

  # Compute deploy age (since started_at).
  started_at=$(jq -r '.started_at // .updated_at // ""' "$f" 2>/dev/null)
  age_min=""
  if [[ -n "$started_at" ]]; then
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo 0)
    [[ "$started_epoch" -gt 0 ]] && age_min=$(( (now_epoch - started_epoch) / 60 ))
  fi

  log "nudging Telegram for $version (ready_to_ship, age=${age_min:-?}min)"

  age_str=""
  [[ -n "$age_min" ]] && age_str=" \(started ${age_min}min ago\)"

  if bash "$TG_SEND" send --md \
       --callback-buttons "✅ Ship|deploy:ship:$version,🛑 Cancel|deploy:cancel:$version" \
       --text "📌 *Reminder\: deploy ready to ship\!* \`$(mdv2_esc "$version")\` is in \`ready\_to\_ship\` state${age_str}\. Smoke passed earlier\, just waiting for your tap\.

Tap *Ship* to commit \+ push\, or *Cancel* to abort\. Auto\-cancels after 2hr\." \
       >/dev/null 2>&1; then
    # Update last_resume_nudge_at so we don't re-ping on the next restart cycle
    # if it happens within 30min.
    new_state=$(jq --arg ts "$(date -u +%FT%TZ)" '. + {last_resume_nudge_at: $ts}' "$f")
    echo "$new_state" > "$f.tmp" && mv "$f.tmp" "$f"
    nudged=$((nudged + 1))
  else
    log "  Telegram nudge for $version FAILED — tg-send.sh returned non-zero"
  fi
done
shopt -u nullglob

[[ $nudged -gt 0 ]] && log "resume sweep complete: $nudged Telegram reminder(s) sent"
exit 0
