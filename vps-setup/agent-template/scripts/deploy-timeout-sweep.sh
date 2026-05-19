#!/usr/bin/env bash
# deploy-timeout-sweep.sh — auto-cancel deploys stuck in ready_to_ship for >2hr.
#
# v2.24.1: closes the "{{TENANT_PERSON_FIRST_NAME}} started a /deploy and walked away" failure mode.
# Without this, a state file at ready_to_ship can sit indefinitely — {{TENANT_PERSON_FIRST_NAME}}
# comes back the next day, taps Ship on a smoke result that's now stale.
#
# Runs every 30 min via deploy-timeout-sweep.timer. Iterates state files in
# {{TENANT_AGENT_HOME}}/deploys/, finds any in phase=ready_to_ship with
# updated_at older than 2hr, calls deploy.sh cancel, posts a Telegram ping.
#
# Idempotent: a state file that's already cancelled OR younger than 2hr is
# left alone. Logs every action to /var/log/{{TENANT_LINUX_USER}}-deploy-timeout.log.

set -uo pipefail

STATE_DIR="{{TENANT_AGENT_HOME}}/deploys"
DEPLOY_SH="{{TENANT_AGENT_HOME}}/scripts/deploy.sh"
TG_SEND="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"
LOG="/var/log/{{TENANT_LINUX_USER}}-deploy-timeout.log"
TIMEOUT_SEC=$((2 * 60 * 60))   # 2 hours

# If the state dir doesn't exist yet, nothing to sweep — exit silent.
[[ ! -d "$STATE_DIR" ]] && exit 0

# Try to write to the standard log; fall back to /tmp if permission-denied.
log() {
  local target="$LOG"
  if ! { : >> "$target"; } 2>/dev/null; then
    target="/tmp/$(basename "$LOG")"
  fi
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$target" >&2
}

# MarkdownV2 escape helper for the Telegram ping.
mdv2_esc() {
  sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' \
      -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' \
      -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' \
      -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' \
      -e 's/}/\\}/g' -e 's/\./\\./g' -e 's/!/\\!/g' <<< "$1"
}

now_epoch=$(date +%s)
swept=0

shopt -s nullglob
for f in "$STATE_DIR"/*.state.json; do
  phase=$(jq -r '.phase // ""' "$f" 2>/dev/null)
  [[ "$phase" != "ready_to_ship" ]] && continue

  updated=$(jq -r '.updated_at // ""' "$f" 2>/dev/null)
  [[ -z "$updated" ]] && { log "WARN: $f has no updated_at; skipping"; continue; }

  updated_epoch=$(date -d "$updated" +%s 2>/dev/null || echo 0)
  age=$((now_epoch - updated_epoch))

  if [[ $age -gt $TIMEOUT_SEC ]]; then
    version=$(jq -r '.version // ""' "$f")
    [[ -z "$version" ]] && { log "WARN: $f has no version; skipping"; continue; }

    hours=$((age / 3600))
    minutes=$(( (age % 3600) / 60 ))
    log "auto-cancelling $version — phase=ready_to_ship for ${hours}h${minutes}m (>2h threshold)"

    # Delegate to deploy.sh cancel — same code path as a manual cancel, posts
    # its own Telegram message via tg_md inside cmd_cancel.
    if bash "$DEPLOY_SH" cancel "$version" >/dev/null 2>&1; then
      log "  $version cancelled cleanly via deploy.sh"
    else
      log "  $version cancel returned non-zero — state may be inconsistent"
    fi

    # Distinct timeout-specific Telegram ping (in addition to deploy.sh cancel's
    # own ping) so {{TENANT_PERSON_FIRST_NAME}} knows it was the auto-sweep, not a manual cancel.
    bash "$TG_SEND" send --md --text "⏰ *Auto\-cancelled deploy* \`$(mdv2_esc "$version")\` — sat in \`ready_to_ship\` for ${hours}h${minutes}m\, exceeded 2hr timeout\. State cleared\. Re\-run \`/deploy $(mdv2_esc "$version")\` if you still want to ship\." >/dev/null 2>&1 || \
      log "  $version Telegram timeout-ping failed (tg-send.sh)"

    swept=$((swept + 1))
  fi
done
shopt -u nullglob

[[ $swept -gt 0 ]] && log "sweep complete: $swept stale deploy(s) cancelled"
exit 0
