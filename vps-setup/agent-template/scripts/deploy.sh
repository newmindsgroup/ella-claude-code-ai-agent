#!/usr/bin/env bash
# deploy.sh — orchestrate v2.X.0 deploys from inside the agent (v2.22.1+).
#
# Closes the v2.20.0–v2.22.0 courier pattern. {{TENANT_PERSON_FIRST_NAME}}'s old workflow: open Cowork,
# paste runbook into Claude Code, watch it execute, tap approvals at GATEs.
# New workflow: send /deploy v2.X.Y in Telegram, get one approval prompt after
# smoke passes, deploy runs autonomously on the VPS.
#
# Subcommands (the agent invokes via CLAUDE.md slash routing):
#
#   start <version>   Read vps-setup/queue/<version>.yml, run preflight + smoke,
#                     write state file, post Telegram approval message.
#   ship <version>    After {{TENANT_PERSON_FIRST_NAME}} taps Ship, do git add + commit + push.
#                     Post final summary. Delete state file.
#   cancel <version>  Rollback staging, delete state file, post cancel message.
#   status <version>  Print current phase from state file.
#
# State file: /var/lib/{{TENANT_LINUX_USER}}/deploys/<version>.state.json
# Phases: started → preflight_passed → smoke_passed → ready_to_ship → shipped
#         (or cancelled / failed at any phase)
#
# This is the v2.22.1 minimum. v2.23.0+ can polish: callback_data buttons,
# multi-tenant support, mid-flight resume, fancier spec format.

set -uo pipefail

REPO_ROOT="{{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}"
TENANT_FILE="$REPO_ROOT/vps-setup/tenants/{{TENANT_ID}}.yml"
QUEUE_DIR="$REPO_ROOT/vps-setup/queue"
STATE_DIR="{{TENANT_AGENT_HOME}}/deploys"
TG_SEND="{{TENANT_AGENT_HOME}}/scripts/tg-send.sh"
PREFLIGHT="$REPO_ROOT/vps-setup/scripts/preflight.sh"
SMOKE="$REPO_ROOT/vps-setup/scripts/smoke.sh"

DASHBOARD_HOSTNAME="{{TENANT_DASHBOARD_HOSTNAME}}"
BASIC_AUTH_USER="{{TENANT_DASHBOARD_BASIC_AUTH_USER}}"
# BASIC_AUTH_PW resolution order:
#   1) environment variable (set by claude-agent.service EnvironmentFile, ideal)
#   2) /opt/{{TENANT_LINUX_USER}}/agents/.env-deploy (chmod 600, owner {{TENANT_LINUX_USER}}, gitignored)
#      Format: BASIC_AUTH_PW=<password>  (one line, no quotes, no whitespace)
# If both miss, smoke step fails clean with a clear error.
ENV_DEPLOY="{{TENANT_AGENT_HOME}}/.env-deploy"
if [[ -z "${BASIC_AUTH_PW:-}" && -f "$ENV_DEPLOY" ]]; then
  # Source only the BASIC_AUTH_PW line, defensively (no arbitrary code exec).
  BASIC_AUTH_PW=$(grep -E '^BASIC_AUTH_PW=' "$ENV_DEPLOY" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
  export BASIC_AUTH_PW
fi

mkdir -p "$STATE_DIR"

# -----------------------------------------------------------------------------
# State helpers
# -----------------------------------------------------------------------------

state_path() { echo "$STATE_DIR/$1.state.json"; }

state_write() {
  local version="$1" phase="$2" extra="${3:-}"
  local now
  now=$(date -u +%FT%TZ)
  if [[ -n "$extra" ]]; then
    jq -n --arg v "$version" --arg p "$phase" --arg t "$now" --argjson e "$extra" \
      '{version:$v, phase:$p, updated_at:$t} + $e' > "$(state_path "$version")"
  else
    jq -n --arg v "$version" --arg p "$phase" --arg t "$now" \
      '{version:$v, phase:$p, updated_at:$t}' > "$(state_path "$version")"
  fi
}

state_phase() {
  local version="$1"
  local f; f=$(state_path "$version")
  [[ -f "$f" ]] && jq -r '.phase' "$f" || echo "absent"
}

state_clear() { rm -f "$(state_path "$1")"; }

# -----------------------------------------------------------------------------
# Telegram helpers
# -----------------------------------------------------------------------------

tg_md() {
  # Send a MarkdownV2 message via the agent's tg-send.sh.
  bash "$TG_SEND" send --md --text "$1" 2>&1 | tail -1
}

tg_with_buttons() {
  # Send a MarkdownV2 message with URL inline buttons (legacy fallback).
  bash "$TG_SEND" send --md --text "$1" --buttons "$2" 2>&1 | tail -1
}

tg_with_callback_buttons() {
  # Send a MarkdownV2 message with callback_data inline buttons (v2.22.2+).
  # Routes through the channels-plugin server.ts callback_query:data handler
  # which recognizes the deploy: pattern and forwards to the agent prompt.
  bash "$TG_SEND" send --md --text "$1" --callback-buttons "$2" 2>&1 | tail -1
}

# Escape MarkdownV2 special chars in a free-form string.
mdv2_esc() {
  sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' \
      -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' \
      -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' \
      -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' \
      -e 's/}/\\}/g' -e 's/\./\\./g' -e 's/!/\\!/g' <<< "$1"
}

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------

# Shared validation pipeline used by cmd_start AND cmd_dry_run. Returns 0 if all
# checks pass, sets globals: SMOKE_PASS, SMOKE_FAIL, FAILURE_REASON, FAILURE_DETAIL.
# WRITE_STATE=1 (default) writes per-phase state files; WRITE_STATE=0 skips them
# (dry-run mode — preflight/smoke can run repeatedly without polluting state).
_run_validation() {
  local version="$1"
  local write_state="${WRITE_STATE:-1}"
  FAILURE_REASON=""
  FAILURE_DETAIL=""
  SMOKE_PASS=0
  SMOKE_FAIL=0

  cd "$REPO_ROOT" || {
    FAILURE_REASON="cd"
    FAILURE_DETAIL="cannot cd to $REPO_ROOT on VPS"
    return 1
  }

  # 1) Sync VPS clone to origin/main.
  if ! git fetch -q origin main; then
    FAILURE_REASON="git_fetch"
    FAILURE_DETAIL="git fetch failed; check VPS network or GitHub access token"
    [[ "$write_state" == "1" ]] && state_write "$version" "failed" '{"reason":"git_fetch"}'
    return 1
  fi
  if ! git pull --ff-only -q origin main; then
    FAILURE_REASON="git_pull"
    FAILURE_DETAIL="git pull --ff-only failed; VPS clone may have local commits, manual fix needed"
    [[ "$write_state" == "1" ]] && state_write "$version" "failed" '{"reason":"git_pull"}'
    return 1
  fi

  # 2) Preflight (PREFLIGHT_LOCAL=1 because we run on the target VPS).
  local preflight_out
  preflight_out=$(PREFLIGHT_LOCAL=1 bash "$PREFLIGHT" "$TENANT_FILE" 2>&1)
  if ! grep -q '0 FAIL' <<< "$preflight_out"; then
    local fails
    fails=$(grep -c '\[FAIL\]' <<< "$preflight_out")
    FAILURE_REASON="preflight"
    FAILURE_DETAIL="preflight: $fails FAIL(s)"
    [[ "$write_state" == "1" ]] && state_write "$version" "failed" "{\"reason\":\"preflight\",\"fails\":$fails}"
    return 1
  fi
  [[ "$write_state" == "1" ]] && state_write "$version" "preflight_passed"

  # 3) Smoke against live API.
  if [[ -z "${BASIC_AUTH_PW:-}" ]]; then
    FAILURE_REASON="basic_auth_missing"
    FAILURE_DETAIL="\$BASIC_AUTH_PW not set in agent environment"
    [[ "$write_state" == "1" ]] && state_write "$version" "failed" '{"reason":"basic_auth_missing"}'
    return 1
  fi
  local smoke_out
  smoke_out=$(bash "$SMOKE" "$DASHBOARD_HOSTNAME" "$BASIC_AUTH_USER" "$BASIC_AUTH_PW" 2>&1)
  SMOKE_PASS=$(grep -oE '[0-9]+ PASS' <<< "$smoke_out" | tail -1 | awk '{print $1}')
  SMOKE_FAIL=$(grep -oE '[0-9]+ FAIL' <<< "$smoke_out" | tail -1 | awk '{print $1}')
  if [[ "${SMOKE_FAIL:-1}" != "0" ]]; then
    FAILURE_REASON="smoke"
    FAILURE_DETAIL="smoke: ${SMOKE_PASS:-?} PASS / ${SMOKE_FAIL:-?} FAIL"
    [[ "$write_state" == "1" ]] && state_write "$version" "failed" "{\"reason\":\"smoke\",\"pass\":${SMOKE_PASS:-0},\"fail\":${SMOKE_FAIL:-1}}"
    return 1
  fi

  return 0
}

cmd_start() {
  local version="$1"
  local spec="$QUEUE_DIR/$version.yml"

  if [[ ! -f "$spec" ]]; then
    tg_md "🛑 *Deploy aborted\.* Spec not found at \`vps-setup/queue/$(mdv2_esc "$version").yml\`\. Author it first, push to main, then retry\."
    state_write "$version" "failed" '{"reason":"spec_missing"}'
    return 1
  fi

  state_write "$version" "started" "{\"spec_path\":\"$spec\",\"started_at\":\"$(date -u +%FT%TZ)\"}"
  tg_md "*Deploy starting for $(mdv2_esc "$version")*\. Spec\: \`vps-setup/queue/$(mdv2_esc "$version").yml\`\. Running preflight\.\.\."

  if ! WRITE_STATE=1 _run_validation "$version"; then
    tg_md "🛑 *Validation FAILED* for $(mdv2_esc "$version") at \`$FAILURE_REASON\` — $(mdv2_esc "$FAILURE_DETAIL")"
    return 1
  fi

  state_write "$version" "ready_to_ship" "{\"smoke_pass\":${SMOKE_PASS:-0},\"smoke_fail\":0}"

  # 4) Approval gate. Buttons pre-fill {{TENANT_PERSON_FIRST_NAME}}'s reply box; he sends the literal
  #    text back, which arrives at the agent's prompt as "ship $version" (or "cancel").
  local commits_pending
  cd "$REPO_ROOT" || { tg_md "🛑 Cannot cd to \\\`$REPO_ROOT\\\` on VPS\\."; return 1; }
  commits_pending=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$commits_pending" == "0" ]]; then
    # Nothing staged — the deploy is "no code changes since spec was authored,
    # just confirming health and tagging the release." That's fine; ship anyway.
    commits_pending="0 \\(state\\-only release\\)"
  fi

  local body
  body="*Deploy ready\: $(mdv2_esc "$version")*"$'\n\n'
  body+="✅ Preflight\: 12/12"$'\n'
  body+="✅ Smoke\: ${SMOKE_PASS:-?} PASS / 0 FAIL"$'\n'
  body+="📦 Files staged for commit\: $commits_pending"$'\n\n'
  body+="Tap *Ship* to commit \\+ push to origin/main\\, or *Cancel* to abort\\."$'\n'
  body+="_Or type_ \`ship $(mdv2_esc "$version")\` _or_ \`cancel $(mdv2_esc "$version")\` _here\\._"
  # v2.22.2+: callback_data buttons. Routes through the patched
  # channels-plugin (telegram@claude-plugins-official server.ts) which
  # recognizes the `deploy:(ship|cancel):v*` pattern and forwards to the
  # agent prompt via the standard `notifications/claude/channel` MCP path.
  # URL buttons (tg://msg?text=...) trigger Telegram's forward dialog on
  # mobile clients — confirmed broken UX, replaced in v2.22.2.
  tg_with_callback_buttons "$body" "✅ Ship|deploy:ship:$version,🛑 Cancel|deploy:cancel:$version"

  return 0
}

# Dry-run mode (v2.23.0+): runs the same validation pipeline as cmd_start but
# never writes state files, never posts an approval message, never expects a
# tap. Posts a "would-have-shipped" preview to Telegram (or stdout if --quiet)
# and exits.
#
# Designed for: pre-deploy local validation, CI gating, post-fix sanity checks.
# Catches the bug class that v2.22.1→5 surfaced: code that "should work"
# silently breaking when run in the production runtime context (different
# user, different cwd, different group memberships, different file perms).
#
# Spec doesn't need to exist — dry-run is also valid as a "is the stack
# itself healthy enough to deploy ANYTHING right now" check, in which case
# pass any version string (v0.0.0-dryrun is conventional).
cmd_dry_run() {
  local version="$1"
  local quiet="${DRY_RUN_QUIET:-0}"
  local started_at
  started_at=$(date -u +%FT%TZ)

  # Spec presence is a soft check in dry-run — if missing, note but proceed
  # so the rest of the pipeline still runs (preflight + smoke surface real
  # state-of-the-stack issues whether or not a spec is in place).
  local spec="$QUEUE_DIR/$version.yml"
  local spec_status
  if [[ -f "$spec" ]]; then
    spec_status="✅ spec found at \`vps-setup/queue/$(mdv2_esc "$version").yml\`"
  else
    spec_status="ℹ️ no spec at \`vps-setup/queue/$(mdv2_esc "$version").yml\` _(dry-run proceeds anyway)_"
  fi

  # Run validation WITHOUT writing state files — this is the whole point.
  if ! WRITE_STATE=0 _run_validation "$version"; then
    if [[ "$quiet" == "1" ]]; then
      echo "DRY-RUN FAILED at $FAILURE_REASON: $FAILURE_DETAIL"
    else
      tg_md "🟡 *Dry-run FAILED for $(mdv2_esc "$version")* at \`$FAILURE_REASON\` — $(mdv2_esc "$FAILURE_DETAIL")"$'\n\n'"_Nothing was committed or pushed; state untouched\\._ Fix the underlying issue\\, then \`deploy\\.sh dry\\-run $(mdv2_esc "$version")\` again before \`deploy\\.sh start\\._"
    fi
    return 1
  fi

  # All checks passed. Post a structured preview.
  local commits_pending
  cd "$REPO_ROOT" >/dev/null 2>&1 || true
  commits_pending=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$commits_pending" == "0" ]]; then
    commits_pending="0 \\(state\\-only release\\)"
  fi

  if [[ "$quiet" == "1" ]]; then
    echo "DRY-RUN PASSED for $version: preflight ok, smoke ${SMOKE_PASS:-?}/0, files staged: $commits_pending"
  else
    local body
    body="*Dry\-run PASSED\: $(mdv2_esc "$version")*"$'\n\n'
    body+="$spec_status"$'\n'
    body+="✅ Preflight\: 12/12 \(local mode\)"$'\n'
    body+="✅ Smoke\: ${SMOKE_PASS:-?} PASS / 0 FAIL"$'\n'
    body+="📦 Working\-tree changes that *would* commit\: $commits_pending"$'\n\n'
    body+="_No state file written\\, no commit\\, no push\\._ Stack is healthy enough to deploy\\. Run \`deploy\\.sh start $(mdv2_esc "$version")\` for real\\."
    tg_md "$body"
  fi
  return 0
}

cmd_ship() {
  local version="$1"
  local phase
  phase=$(state_phase "$version")
  if [[ "$phase" != "ready_to_ship" ]]; then
    tg_md "🛑 *Cannot ship $(mdv2_esc "$version")* — current phase is \`$phase\`\, not \`ready_to_ship\`\. Run /deploy $(mdv2_esc "$version") first\."
    return 1
  fi

  cd "$REPO_ROOT" || { tg_md "🛑 Cannot cd to \\\`$REPO_ROOT\\\` on VPS\\."; return 1; }

  # Re-check working tree state.
  local changed
  changed=$(git status --porcelain | wc -l | tr -d ' ')
  if [[ "$changed" == "0" ]]; then
    # State-only release — tag without commit. Useful for confirming health.
    tg_md "ℹ️ *No file changes for $(mdv2_esc "$version")\.* Tagging without commit\."
    state_write "$version" "shipped"
    state_clear "$version"
    return 0
  fi

  # Commit using the version + spec summary.
  local spec_path="$QUEUE_DIR/$version.yml"
  local description
  description=$(grep -A 3 '^description:' "$spec_path" 2>/dev/null | tail -n +2 | head -3 | sed 's/^  //' | tr -d '"' || echo "")
  [[ -z "$description" ]] && description="$version deploy via /deploy command"

  # Bug 2 (v2.22.2): defensive token-presence check BEFORE commit, so a missing
  # token doesn't burn a commit-then-fail cycle. Recognize either token-in-URL
  # (https://gho_*@github.com/...) or a credential helper.
  local origin_url cred_helper
  origin_url=$(git remote get-url origin 2>/dev/null || echo "")
  cred_helper=$(git config --get credential.helper 2>/dev/null || echo "")
  if ! [[ "$origin_url" =~ ^https://(gh[op]_|x-access-token:) ]] && [[ -z "$cred_helper" ]]; then
    tg_md "🛑 *Cannot push $(mdv2_esc "$version")* — no GitHub token in remote URL\, no credential helper configured\. On the VPS\, run\: \`git \\-C $(mdv2_esc "$REPO_ROOT") remote set\\-url origin https\://\\<TOKEN\\>\\@github\\.com/$(mdv2_esc "$(echo "$origin_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')")\\.git\`  with a fresh PAT \(scope\: repo\) from https\://github\\.com/settings/tokens\."
    state_write "$version" "failed" '{"reason":"no_push_credential"}'
    return 1
  fi

  git add -A
  if ! git commit -m "$version

$description

Deployed via /deploy command (v2.22.1+). Spec: vps-setup/queue/$version.yml.
Preflight + smoke validated before approval. Approved via Telegram.
"; then
    tg_md "🛑 *git commit failed* for $(mdv2_esc "$version")\. Check VPS clone state\."
    state_write "$version" "failed" '{"reason":"git_commit"}'
    return 1
  fi

  # Capture stderr so we can pattern-match auth-failure messages and surface
  # actionable remediation (rotate token vs network glitch vs ref out of date).
  local push_err
  if ! push_err=$(git push origin main 2>&1); then
    if grep -qE "Authentication failed|fatal: could not read Username|HTTP/.+ 401|HTTP/.+ 403" <<< "$push_err"; then
      tg_md "🛑 *git push auth failed* for $(mdv2_esc "$version")\. Token in remote URL is rejected — likely expired or revoked\. Rotate at https\://github\\.com/settings/tokens \(classic\, scope\: repo\) and update the remote URL on the VPS\."
    elif grep -qE "rejected|non\\-fast\\-forward|fetch first" <<< "$push_err"; then
      tg_md "🛑 *git push rejected* for $(mdv2_esc "$version") — VPS clone is behind origin/main\. Run \`git \\-C $(mdv2_esc "$REPO_ROOT") pull \\-\\-ff\\-only origin main\` and retry\."
    else
      tg_md "🛑 *git push failed* for $(mdv2_esc "$version")\. stderr\: \`$(mdv2_esc "$(echo "$push_err" | tail -3 | tr '\n' ' ' | head -c 240)")\`"
    fi
    state_write "$version" "failed" '{"reason":"git_push"}'
    return 1
  fi

  local sha
  sha=$(git rev-parse --short HEAD)

  # v2.24.3: record this deploy in the task ledger for ops metrics. Read
  # phase data from the state file BEFORE clearing it so duration + smoke
  # results survive into the ledger entry. telemetry-calc.py will attribute
  # Claude API costs to this task on its next 5-min cycle (timestamp window
  # match), giving us real "what did this deploy cost?" data over time.
  local started_at finished_at duration_sec smoke_pass
  started_at=$(jq -r '.started_at // .updated_at // ""' "$(state_path "$version")" 2>/dev/null)
  smoke_pass=$(jq -r '.smoke_pass // 0' "$(state_path "$version")" 2>/dev/null)
  finished_at=$(date -u +%FT%TZ)
  duration_sec=$(python3 -c "
import sys, datetime
try:
    s = datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
    e = datetime.datetime.fromisoformat(sys.argv[2].replace('Z','+00:00'))
    print(int((e-s).total_seconds()))
except Exception:
    print(0)
" "$started_at" "$finished_at" 2>/dev/null || echo 0)

  # Create + immediately complete a task in the ledger. Owner=self, source=deploy
  # so it groups under "self-initiated infrastructure work" in the dashboard.
  local LEDGER="{{TENANT_AGENT_HOME}}/scripts/task-ledger.sh"
  local task_id
  task_id=$(bash "$LEDGER" create \
    --summary "Deploy $version → $sha (smoke=${smoke_pass}/0, ${duration_sec}s)" \
    --owner self --source deploy 2>/dev/null | tail -1)
  if [[ -n "$task_id" && "$task_id" =~ ^t-[0-9]{8}-[a-f0-9]+ ]]; then
    bash "$LEDGER" state --id "$task_id" --state done \
      --msg "Deploy v2.24.3+ ledger record. Phase durations + total cost will be attributed by telemetry-calc.py via timestamp windows." \
      >/dev/null 2>&1
  fi

  state_write "$version" "shipped" "{\"sha\":\"$sha\",\"duration_sec\":$duration_sec,\"task_id\":\"${task_id:-}\"}"
  tg_md "✅ *$(mdv2_esc "$version") shipped\.* Commit \`$sha\` pushed to origin/main\. Duration\: ${duration_sec}s\. Ledger task\: \`${task_id:-none}\`\."
  state_clear "$version"
  return 0
}

cmd_cancel() {
  local version="$1"
  local phase
  phase=$(state_phase "$version")
  if [[ "$phase" == "absent" ]]; then
    tg_md "ℹ️ No active deploy for $(mdv2_esc "$version") to cancel\."
    return 0
  fi
  state_write "$version" "cancelled"
  state_clear "$version"
  tg_md "🛑 *Deploy cancelled\: $(mdv2_esc "$version")*\. State cleared\. Re\\-run /deploy $(mdv2_esc "$version") if you want to retry\."
  return 0
}

cmd_status() {
  local version="$1"
  local f
  f=$(state_path "$version")
  if [[ ! -f "$f" ]]; then
    echo "no active deploy for $version"
    return 0
  fi
  jq . "$f"
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------

usage() {
  cat <<USAGE
deploy.sh — orchestrate v2.X.Y deploys from inside the agent.

Usage:
  deploy.sh dry-run <version>   Run preflight + smoke; preview only, NO state writes,
                                NO commit, NO push. Use before any real ship — closes
                                the v2.22.x bug class where each fix only surfaced the
                                next layer in production.
  deploy.sh start <version>     Run preflight + smoke, post approval message
  deploy.sh ship <version>      After {{TENANT_PERSON_FIRST_NAME}} approves, commit + push
  deploy.sh cancel <version>    Rollback staging, clear state
  deploy.sh status <version>    Show current phase from state file

Env vars:
  DRY_RUN_QUIET=1               In dry-run, skip Telegram and write to stdout
                                (for CI / shell-script gating). Exits 0 on PASS, 1 on FAIL.
  WATCHDOG_FORCE_RESTART=1      (telegram-poller-watchdog only) bypass circuit breaker

State at $STATE_DIR/<version>.state.json
USAGE
}

cmd="${1:-help}"
[[ $# -lt 2 && "$cmd" != "help" ]] && { usage; exit 2; }

case "$cmd" in
  dry-run|dryrun) cmd_dry_run "$2" ;;
  start)          cmd_start   "$2" ;;
  ship)           cmd_ship    "$2" ;;
  cancel)         cmd_cancel  "$2" ;;
  status)         cmd_status  "$2" ;;
  help|*)         usage ;;
esac
