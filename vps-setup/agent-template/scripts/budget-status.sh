#!/usr/bin/env bash
# budget-status.sh — today's LLM spend vs ceiling + frugal-mode state.
# Backs the /budget command. Read-only.
set -euo pipefail
AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp
TELEMETRY="${SPEND_TELEMETRY_PATH:-/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/telemetry.json}"
CEILING="${DAILY_SPEND_CEILING_USD:-{{TENANT_DAILY_SPEND_CEILING_USD}}}"
[[ "$CEILING" =~ ^[0-9.]+$ ]] || CEILING=20
FRUGAL_FLAG="$AGENT_HOME/state/frugal-mode"

cost=$(jq -r '.rollup.today.api_cost_usd // 0' "$TELEMETRY" 2>/dev/null || echo 0)
value=$(jq -r '.rollup.today.value_usd // 0' "$TELEMETRY" 2>/dev/null || echo 0)
savings=$(jq -r '.rollup.today.net_savings_usd // 0' "$TELEMETRY" 2>/dev/null || echo 0)
week=$(jq -r '.rollup.week.api_cost_usd // 0' "$TELEMETRY" 2>/dev/null || echo 0)
pct=$(awk -v c="$cost" -v cap="$CEILING" 'BEGIN{ if(cap>0) printf "%d", (c/cap)*100; else print 0 }')

bar_n=$(awk -v p="$pct" 'BEGIN{ n=int(p/10); if(n>10)n=10; if(n<0)n=0; print n }')
bar=$(printf '█%.0s' $(seq 1 "$bar_n" 2>/dev/null) 2>/dev/null)$(printf '░%.0s' $(seq 1 $((10-bar_n)) 2>/dev/null) 2>/dev/null)

echo "💰 LLM budget — today"
echo
echo "Spent: \$$cost / \$$CEILING  ${bar} ${pct}%"
echo "Value delivered: \$$value (net savings \$$savings)"
echo "Week to date: \$$week"
echo
if [[ -f "$FRUGAL_FLAG" ]]; then
  echo "🛑 FRUGAL MODE ON — LLM watchers paused, new LLM jobs blocked. Resets when today's cost is back under ceiling (midnight)."
else
  echo "🟢 Full autonomy — under ceiling."
fi
