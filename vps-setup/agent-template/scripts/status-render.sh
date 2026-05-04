#!/usr/bin/env bash
# status-render.sh — render a comprehensive Telegram MarkdownV2 snapshot of
# the stack: health overview, today's cost, active tasks summary, next 3
# scheduled skill runs, recent agent restarts. Replaces the need to ssh in
# or open the dashboard for a basic status check.
#
# v2.27.0+. Used by the agent's /status slash command (CLAUDE.md spec).
# Also runnable directly: `bash scripts/status-render.sh` prints to stdout.
#
# Reads from /api/*.json (already-aggregated by dashboard-sync.sh +
# telemetry-calc.py) so this script is fast and read-only — never touches
# state files.
set -uo pipefail

DASHBOARD_API="http://127.0.0.1/api"  # nginx serves /api locally without TLS
# Fallback to file paths if nginx isn't routing locally
API_DIR="/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api"

read_json() {
  local file="$1"
  if [[ -r "$API_DIR/$file" ]]; then
    cat "$API_DIR/$file"
  else
    echo "{}"
  fi
}

# MarkdownV2 escape for arbitrary text (numbers, emails, paths, etc.)
mdv2() {
  sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' \
      -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' \
      -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' \
      -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' \
      -e 's/}/\\}/g' -e 's/\./\\./g' -e 's/!/\\!/g' <<< "$1"
}

health_json=$(read_json health.json)
telem_json=$(read_json telemetry.json)
tasks_json=$(read_json tasks.json)
queue_json=$(read_json queue.json)

# Health line
ok=$(echo "$health_json" | jq -r '.ok // false')
health_emoji=$([ "$ok" = "true" ] && echo "🟢" || echo "🔴")
restarts=$(echo "$health_json" | jq -r '.watchdog.recent_restarts_30min // 0')
poller=$(echo "$health_json" | jq -r '.telegram_poller.alive // false')
poller_emoji=$([ "$poller" = "true" ] && echo "✓" || echo "✗")
cert_days=$(echo "$health_json" | jq -r '.tls_cert.days_remaining // "?"')
stack_ver=$(echo "$health_json" | jq -r '.stack_version // "?"')

# Cost line (today)
cost_today=$(echo "$telem_json" | jq -r '.rollup.today.api_cost_usd // 0' | awk '{printf "%.2f", $1}')
value_today=$(echo "$telem_json" | jq -r '.rollup.today.value_usd // 0' | awk '{printf "%.0f", $1}')
savings_today=$(echo "$telem_json" | jq -r '.rollup.today.net_savings_usd // 0' | awk '{printf "%.0f", $1}')
hours_today=$(echo "$telem_json" | jq -r '.rollup.today.human_eq_hours // 0' | awk '{printf "%.1f", $1}')
tasks_today=$(echo "$telem_json" | jq -r '.rollup.today.task_count // 0')

# Cost line (week)
cost_week=$(echo "$telem_json" | jq -r '.rollup.week.api_cost_usd // 0' | awk '{printf "%.2f", $1}')

# Tasks summary
total_tasks=$(echo "$tasks_json" | jq -r '. | length // 0' 2>/dev/null || echo 0)
in_review=$(echo "$queue_json" | jq -r '.by_state.in_review // 0')
awaiting_external=$(echo "$queue_json" | jq -r '.by_state.awaiting_external // 0')
blocked=$(echo "$queue_json" | jq -r '.by_state.blocked // 0')

# Next 3 scheduled skill runs. systemctl list-timers' columns are space-padded
# but the LEFT countdown can be multi-word ("2h 42min"), so robust parsing
# means: find the *.timer field, then build a short timestamp from fields 1-3.
next_runs=$(systemctl list-timers --no-pager --no-legend 2>/dev/null \
  | grep -E 'morning-brief|evening-rollup|agent-skill@|deploy-timeout' \
  | head -3 \
  | awk '{
      unit=""
      for (i=1; i<=NF; i++) if ($i ~ /\.timer$/) { unit=$i; break }
      gsub(/^agent-skill@/, "", unit)
      gsub(/\.timer$/, "", unit)
      printf "  • %-25s next %s %s %s\n", unit, $1, $2, $3
    }')

ESC_VER=$(mdv2 "$stack_ver")

# Compose MarkdownV2 message
cat <<EOF
*Mission Control status* ${health_emoji}

*Stack:* \`$ESC_VER\` · poller ${poller_emoji} · ${restarts} restarts/30min · TLS ${cert_days}d
*Cost today:* \$${cost_today} api · \$${value_today} value created · \$${savings_today} net savings · ${hours_today}h human\-equiv
*Cost week:* \$${cost_week} api
*Tasks today:* ${tasks_today} ran · ${in_review} in review · ${awaiting_external} awaiting you · ${blocked} blocked

*Next runs:*
\`\`\`
${next_runs:-  (none scheduled)}
\`\`\`

\`/diag\` for deeper trace · \`/tasks\` for full list · \`/queue\` for approval queue
EOF
