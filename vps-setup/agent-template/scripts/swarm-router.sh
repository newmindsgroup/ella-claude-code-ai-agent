#!/usr/bin/env bash
# swarm-router.sh — dispatch a brief to the right swarm.
#
# Usage:
#   swarm-router.sh content   --brief "Topic text" [--task-id t-XXXX]
#   swarm-router.sh bizdev    --prospect "Company Name" [--url https://...] [--task-id t-XXXX]
#   swarm-router.sh delivery  --client "Acme Corp" --brief-file /path/to/brief.json [--task-id t-XXXX]
#   swarm-router.sh onboarding --client "Acme" --kickoff-date 2026-05-15 [--task-id t-XXXX]
#
# The chief-of-staff calls this when a request matches a swarm pattern.
# Returns the task ID of the spawned swarm run.

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
SWARMS_DIR="$AGENT_HOME/swarms"
SCRIPTS_DIR="$AGENT_HOME/scripts"
LOG_DIR="$AGENT_HOME/logs"
OPENSWARM_DIR="${OPENSWARM_DIR:-$AGENT_HOME/openswarm-repo}"

# Load env (Anthropic key + DEFAULT_MODEL)
set -a; source "$AGENT_HOME/.env" 2>/dev/null || true; set +a

mkdir -p "$LOG_DIR"

SWARM="${1:-help}"; shift || true

# Collect remaining args to pass through
ARGS=("$@")

# Auto-create a task if none provided
task_id=""
for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--task-id" ]]; then
        task_id="${ARGS[$((i+1))]}"
        break
    fi
done

if [[ -z "$task_id" ]]; then
    case "$SWARM" in
        content)    summary="Content swarm run" ;;
        bizdev)     summary="Bizdev swarm run" ;;
        delivery)   summary="Client delivery swarm run" ;;
        onboarding) summary="Onboarding swarm run" ;;
        slides)     summary="OpenSwarm: slides agent run" ;;
        docs)       summary="OpenSwarm: docs agent run" ;;
        data|analyst) summary="OpenSwarm: data analyst run" ;;
        research)   summary="OpenSwarm: deep research run" ;;
        video)      summary="OpenSwarm: video generation run" ;;
        image)      summary="OpenSwarm: image generation run" ;;
        assistant)  summary="OpenSwarm: virtual assistant run" ;;
        *)          summary="Swarm run" ;;
    esac
    task_id=$(bash "$SCRIPTS_DIR/task-ledger.sh" create \
        --summary "$summary ($SWARM)" \
        --owner "swarm-router" \
        --loud true \
        --source "swarm-router" 2>/dev/null)
    ARGS+=("--task-id" "$task_id")
    echo "Created task: $task_id" >&2
fi

echo "Dispatching to $SWARM swarm (task: $task_id)..." >&2

case "$SWARM" in
    content)
        nohup python3 "$SWARMS_DIR/content_swarm.py" "${ARGS[@]}" \
            >> "$LOG_DIR/swarm-content.log" 2>&1 &
        echo "content-swarm started (task: $task_id, PID: $!)"
        ;;
    bizdev)
        nohup python3 "$SWARMS_DIR/bizdev_swarm.py" "${ARGS[@]}" \
            >> "$LOG_DIR/swarm-bizdev.log" 2>&1 &
        echo "bizdev-swarm started (task: $task_id, PID: $!)"
        ;;
    delivery|client-delivery)
        nohup python3 "$SWARMS_DIR/client_delivery_swarm.py" "${ARGS[@]}" \
            >> "$LOG_DIR/swarm-delivery.log" 2>&1 &
        echo "client-delivery-swarm started (task: $task_id, PID: $!)"
        ;;
    onboarding)
        nohup python3 "$SWARMS_DIR/onboarding_swarm.py" "${ARGS[@]}" \
            >> "$LOG_DIR/swarm-onboarding.log" 2>&1 &
        echo "onboarding-swarm started (task: $task_id, PID: $!)"
        ;;
    # ── Salomon / Hermes Agent ──────────────────────────────────────────
    hermes|salomon)
        TASK=""
        for i in "${!ARGS[@]}"; do
            if [[ "${ARGS[$i]}" == "--task" || "${ARGS[$i]}" == "--brief" ]]; then
                TASK="${ARGS[$((i+1))]}"
            fi
        done
        [[ -z "$TASK" ]] && TASK="${ARGS[0]:-Run task}"
        nohup bash "$SCRIPTS_DIR/hermes-dispatch.sh" \
            --task "$TASK" \
            --task-id "$task_id" \
            >> "$LOG_DIR/swarm-hermes.log" 2>&1 &
        echo "salomon-hermes started (task: $task_id, PID: $!)"
        ;;
    # ── OpenSwarm (VRSEN) agents ─────────────────────────────────────────
    slides|docs|data|analyst|research|video|image|assistant)
        # Normalize agent name
        AGENT="$SWARM"; [[ "$SWARM" == "analyst" ]] && AGENT="data"
        # Extract --task or --brief from args
        TASK=""
        for i in "${!ARGS[@]}"; do
            if [[ "${ARGS[$i]}" == "--task" || "${ARGS[$i]}" == "--brief" ]]; then
                TASK="${ARGS[$((i+1))]}"
            fi
        done
        [[ -z "$TASK" ]] && TASK="${ARGS[0]:-Run $AGENT task}"
        nohup python3 "$SWARMS_DIR/openswarm_runner.py" \
            --task "$TASK" \
            --agent "$AGENT" \
            --task-id "$task_id" \
            >> "$LOG_DIR/swarm-openswarm-$AGENT.log" 2>&1 &
        echo "openswarm-$AGENT started (task: $task_id, PID: $!)"
        ;;
    list)
        echo "Available swarms:"
        echo ""
        echo "  Custom (claude --print, no API key):"
        echo "    content    — brief → newsletter + LinkedIn + X + IG carousel"
        echo "    bizdev     — prospect → research + outreach + proposal outline"
        echo "    delivery   — client brief → strategy doc + comp analysis + visual direction"
        echo "    onboarding — new client → welcome kit + kickoff agenda + timeline"
        echo ""
        echo "  OpenSwarm (VRSEN — Claude API via LiteLLM):"
        echo "    slides     — /swarm slides --task 'deck on AI brand voice'"
        echo "    docs       — /swarm docs --task 'write a report on X'"
        echo "    data       — /swarm data --task 'analyze attached CSV'"
        echo "    research   — /swarm research --task 'deep dive on competitor Y'"
        echo "    video      — /swarm video --task 'short video about Z'"
        echo "    image      — /swarm image --task 'brand image for W'"
        echo "    assistant  — /swarm assistant --task 'schedule meeting / send email'"
        ;;
    help|*)
        cat <<EOF
swarm-router.sh — dispatch tasks to swarm orchestrators

Custom swarms (claude --print):
  swarm-router.sh content   --brief "Topic" [--task-id t-XXXX]
  swarm-router.sh bizdev    --prospect "Company" [--url URL] [--task-id t-XXXX]
  swarm-router.sh delivery  --brief-file /path.json [--task-id t-XXXX]
  swarm-router.sh onboarding --client "Name" --kickoff-date DATE [--task-id t-XXXX]

OpenSwarm agents (Claude API / LiteLLM):
  swarm-router.sh slides    --task "deck on AI brand voice" [--task-id t-XXXX]
  swarm-router.sh docs      --task "write report on X"
  swarm-router.sh data      --task "analyze this dataset"
  swarm-router.sh research  --task "deep dive on competitor Y"
  swarm-router.sh video     --task "short video about Z"
  swarm-router.sh image     --task "brand header image"
  swarm-router.sh assistant --task "schedule a call with X"

  swarm-router.sh list

Swarms run async (nohup). Results come via Telegram + task ledger updates.
EOF
        exit 0
        ;;
esac
