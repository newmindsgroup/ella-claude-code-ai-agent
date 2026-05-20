#!/usr/bin/env bash
# dispatch-job.sh — fire-and-forget background job runner.
#
# THE delegation-first primitive. The chief-of-staff calls this for any
# real work, gets a job ID back INSTANTLY, tells {{TENANT_PERSON_FIRST_NAME}}
# "working on it", and stays free to keep talking. The job runs in a fully
# detached process (survives the agent's turn ending and even a claude-agent
# restart, since setsid breaks it out of the service's process group). When
# it finishes it updates its record + pings Telegram with the result.
#
# This is different from the Agent tool (Task), which BLOCKS the main thread.
# Use the Agent tool only when the result is needed in the same reply AND is
# fast. Use dispatch-job.sh for everything else — research, content,
# multi-step ops, website builds, analysis.
#
# Usage:
#   dispatch-job.sh --title "Research Acme Corp" --prompt "Full research brief…"
#   dispatch-job.sh --title "Build pricing page section" --prompt "…" --executor content-agent
#   dispatch-job.sh --title "Content swarm: Q3 newsletter" --cmd "bash {{TENANT_AGENT_HOME}}/scripts/swarm-router.sh content --brief '…'"
#
# Modes:
#   --prompt "…"     run `claude --print` with the prompt (optionally as a sub-agent persona)
#   --cmd "…"        run an arbitrary shell command (swarm-router, hermes-dispatch, a script)
#   --executor NAME  (with --prompt) prepend a sub-agent directive so the job adopts that persona
#
# Concurrency guard: refuses to launch if MAX_JOBS (default 3) are already
# running — prevents runaway parallel claude sessions burning budget. Aligns
# with the Charter's spend discipline.
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
# Run from a directory we can always access — avoids `find: Failed to restore
# initial working directory` when invoked from a dir the agent user can't read
# (e.g. /root during admin testing). Production CWD is already AGENT_HOME.
cd "$AGENT_HOME" 2>/dev/null || cd /tmp
JOBS_DIR="$AGENT_HOME/jobs"
ACTIVE_DIR="$JOBS_DIR/active"
DONE_DIR="$JOBS_DIR/done"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"
MAX_JOBS="${DISPATCH_MAX_JOBS:-3}"
JOB_TIMEOUT_SEC="${DISPATCH_JOB_TIMEOUT_SEC:-1800}"  # 30 min hard cap per job

mkdir -p "$ACTIVE_DIR" "$DONE_DIR"

TITLE=""; PROMPT=""; CMD=""; EXECUTOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    TITLE="$2"; shift 2 ;;
    --prompt)   PROMPT="$2"; shift 2 ;;
    --cmd)      CMD="$2"; shift 2 ;;
    --executor) EXECUTOR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$TITLE" ]] && { echo "ERROR: --title required" >&2; exit 1; }
[[ -z "$PROMPT" && -z "$CMD" ]] && { echo "ERROR: need --prompt or --cmd" >&2; exit 1; }

# Phase 4 frugal-mode guard: block new LLM (--prompt) jobs when the daily
# spend ceiling has been breached. Deterministic --cmd jobs still allowed.
if [[ -n "$PROMPT" && -f "$AGENT_HOME/state/frugal-mode" ]]; then
  echo "ERROR: frugal mode on (daily LLM ceiling reached) — refusing new --prompt job." >&2
  echo "FRUGAL"; exit 3
fi

# ── Concurrency guard ───────────────────────────────────────────────────────
running=$(find "$ACTIVE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$running" -ge "$MAX_JOBS" ]]; then
  echo "ERROR: $running jobs already running (max $MAX_JOBS). Wait for one to finish or raise DISPATCH_MAX_JOBS." >&2
  echo "BUSY"
  exit 2
fi

# ── Create job record ───────────────────────────────────────────────────────
JOB_ID="j-$(date -u +%Y%m%d)-$(openssl rand -hex 2 2>/dev/null || printf '%04x' $RANDOM)"
RECORD="$ACTIVE_DIR/$JOB_ID.json"
LOG_FILE="$AGENT_HOME/logs/job-$JOB_ID.log"

# Build the command to run
if [[ -n "$PROMPT" ]]; then
  FULL_PROMPT="$PROMPT"
  if [[ -n "$EXECUTOR" ]]; then
    FULL_PROMPT="You are acting as the '$EXECUTOR' sub-agent. $PROMPT"
  fi
  # claude --print as a separate process. bypassPermissions so hosted MCPs work.
  RUN_CMD=(claude --permission-mode bypassPermissions --print "$FULL_PROMPT")
else
  RUN_CMD=(bash -c "$CMD")
fi

jq -nc \
  --arg id "$JOB_ID" \
  --arg title "$TITLE" \
  --arg executor "${EXECUTOR:-direct}" \
  --arg started "$(date -u +%FT%TZ)" \
  --arg mode "$([[ -n "$PROMPT" ]] && echo prompt || echo cmd)" \
  '{id:$id, title:$title, executor:$executor, status:"running", started_at:$started, mode:$mode}' \
  > "$RECORD"

# ── Detached worker ─────────────────────────────────────────────────────────
# setsid fully detaches: new session, no controlling terminal, survives the
# parent (claude) exiting its turn. Output → log file. On completion, update
# the record, move to done/, ping Telegram.
worker() {
  local rc result short
  result=$(timeout "$JOB_TIMEOUT_SEC" "${RUN_CMD[@]}" 2>>"$LOG_FILE") && rc=0 || rc=$?
  echo "$result" >> "$LOG_FILE"

  local status finished
  finished="$(date -u +%FT%TZ)"
  if [[ $rc -eq 0 ]]; then status="done"; elif [[ $rc -eq 124 ]]; then status="timeout"; else status="failed"; fi

  # Update record + move to done/
  jq --arg s "$status" --arg f "$finished" --arg rc "$rc" \
    '. + {status:$s, finished_at:$f, exit_code:($rc|tonumber)}' \
    "$RECORD" > "$RECORD.tmp" 2>/dev/null && mv "$RECORD.tmp" "$DONE_DIR/$JOB_ID.json" && rm -f "$RECORD"

  # Telegram ping — title + status + first ~280 chars of result
  short=$(echo "$result" | tr '\n' ' ' | head -c 280)
  local emoji icon
  case "$status" in
    done)    icon="✅" ;;
    timeout) icon="⏱️" ;;
    *)       icon="⚠️" ;;
  esac
  if [[ "$status" == "done" ]]; then
    "$TG_SEND" send --text "$icon Background job done: $TITLE

${short:-（no output）}" >/dev/null 2>&1 || true
  else
    "$TG_SEND" send --text "$icon Background job $status: $TITLE — see logs/job-$JOB_ID.log" >/dev/null 2>&1 || true
  fi
}

# Launch detached. Redirect all stdio so setsid fully releases the terminal.
setsid bash -c "$(declare -f worker); $(declare -p RUN_CMD RECORD DONE_DIR ACTIVE_DIR LOG_FILE TG_SEND TITLE JOB_ID JOB_TIMEOUT_SEC); worker" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

# Return the job ID immediately — the agent keeps talking.
echo "$JOB_ID"
