#!/usr/bin/env bash
# Smoke-test everything we built today, end-to-end.
# Run on the VPS as root (some checks need it).
set -uo pipefail

PASS=0
FAIL=0
WARN=0
ISSUES=()

ok()    { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); ISSUES+=("FAIL: $1"); }
warn()  { echo "  ⚠ $1"; WARN=$((WARN+1)); ISSUES+=("WARN: $1"); }

section() { echo; echo "═══════════════════════════════════════════════════════════"; echo " $1"; echo "═══════════════════════════════════════════════════════════"; }

# ───────────────────────────────────────────────────────────────────────────
section "1. CORE SERVICES"
# ───────────────────────────────────────────────────────────────────────────
for svc in claude-agent.service dashboard-chat.service nginx telegram-poller-watchdog.timer; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc active"
  else
    fail "$svc NOT active"
  fi
done

# ───────────────────────────────────────────────────────────────────────────
section "2. ALL SCHEDULED TIMERS"
# ───────────────────────────────────────────────────────────────────────────
expected_timers=(
  "morning-brief.timer"
  "evening-rollup.timer"
  "stale-watcher.timer"
  "task-deadline-watcher.timer"
  "goal-deadline-watcher.timer"
  "stalled-deal-watcher.timer"
  "disk-space-watcher.timer"
  "hot-lead-inbox-watcher.timer"
  "calendar-conflict-watcher.timer"
  "website-uptime-watcher.timer"
  "graphify-rebuild.timer"
  "graphify-semantic.timer"
  "agent-skill@brand-drift-scanner.timer"
  "telegram-poller-watchdog.timer"
)
for t in "${expected_timers[@]}"; do
  # systemctl is-active is the most reliable check (handles all states).
  if systemctl is-active --quiet "$t" 2>/dev/null; then
    next=$(systemctl list-timers --all --no-pager 2>/dev/null | grep -F "$t" | head -1 | awk '{print $1, $2}')
    ok "$t (next: ${next:-unscheduled-but-loaded})"
  else
    fail "$t NOT active"
  fi
done

# ───────────────────────────────────────────────────────────────────────────
section "3. SCRIPTS PRESENT + EXECUTABLE"
# ───────────────────────────────────────────────────────────────────────────
SCRIPTS_DIR={{TENANT_AGENT_HOME}}/scripts
expected_scripts=(
  "morning-brief.py"
  "morning-brief.sh"
  "voice-transcribe.sh"
  "voice-reply.sh"
  "tg-send.sh"
  "pref.sh"
  "setup-bot-identity.sh"
  "patch-channels-plugin.sh"
  "task-deadline-watcher.sh"
  "goal-deadline-watcher.sh"
  "stalled-deal-watcher.sh"
  "disk-space-watcher.sh"
  "hot-lead-inbox-watcher.sh"
  "calendar-conflict-watcher.sh"
  "website-uptime-watcher.sh"
  "graphify-rebuild.sh"
)
for s in "${expected_scripts[@]}"; do
  if [[ -x "$SCRIPTS_DIR/$s" ]]; then ok "$s"
  else fail "$s missing or not executable"; fi
done

# ───────────────────────────────────────────────────────────────────────────
section "4. CHANNELS PLUGIN PATCHES (7 passes)"
# ───────────────────────────────────────────────────────────────────────────
PLUGIN={{TENANT_USER_HOME}}/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6/server.ts
sentinels=(
  "v2.22.2: deploy command callbacks"
  "v2.24.0: draft approval callbacks"
  "v2.27.2: proposal approval callbacks"
  "v2.27.3: forward_origin metadata"
  "v2.27.4: email triage callbacks"
  "v2.62.0: chat parity ingest tee"
  "v2.78.0: outbound reply ingest tee"
)
for s in "${sentinels[@]}"; do
  if grep -q "$s" "$PLUGIN" 2>/dev/null; then ok "$s"
  else fail "$s MISSING"; fi
done
if grep -q 'perm:(allow|deny|more)' "$PLUGIN" 2>/dev/null; then ok "upstream perm: handler intact"
else fail "perm: handler corrupted"; fi
if command -v bun >/dev/null 2>&1; then
  bun build "$PLUGIN" --target=bun --outfile /tmp/smoke-test-server-$$.js >/dev/null 2>&1 \
    && { ok "TypeScript still compiles"; rm -f /tmp/smoke-test-server-$$.js; } \
    || fail "TypeScript BROKEN"
fi

# ───────────────────────────────────────────────────────────────────────────
section "5. TELEGRAM BOT IDENTITY"
# ───────────────────────────────────────────────────────────────────────────
TG_TOKEN=$(grep TELEGRAM_BOT_TOKEN= {{TENANT_USER_HOME}}/.claude/channels/telegram/.env | cut -d= -f2)
cmd_count=$(curl -s "https://api.telegram.org/bot$TG_TOKEN/getMyCommands" | jq '.result | length')
if [[ "$cmd_count" -ge 28 ]]; then ok "$cmd_count commands set in bot menu (expected ≥28)"
else fail "only $cmd_count commands set, expected ≥28"; fi
desc_len=$(curl -s "https://api.telegram.org/bot$TG_TOKEN/getMyDescription" | jq -r '.result.description | length')
if [[ "$desc_len" -gt 50 ]]; then ok "Bot description set ($desc_len chars)"
else fail "Bot description empty"; fi
short_len=$(curl -s "https://api.telegram.org/bot$TG_TOKEN/getMyShortDescription" | jq -r '.result.short_description | length')
if [[ "$short_len" -gt 20 ]]; then ok "Short description set ($short_len chars)"
else fail "Short description empty"; fi

# ───────────────────────────────────────────────────────────────────────────
section "6. CONFIG FILES + STATE"
# ───────────────────────────────────────────────────────────────────────────
[[ -f {{TENANT_USER_HOME}}/.claude/channels/telegram/access.json ]] && ok "access.json exists" || fail "access.json missing"
ack=$(jq -r '.ackReaction // "(unset)"' {{TENANT_USER_HOME}}/.claude/channels/telegram/access.json 2>/dev/null)
if [[ "$ack" == "👀" ]]; then ok "ackReaction = 👀"; else warn "ackReaction = '$ack' (expected 👀)"; fi

[[ -f {{TENANT_AGENT_HOME}}/preferences.json ]] && {
  vm=$(jq -r '.voice_mode // "(unset)"' {{TENANT_AGENT_HOME}}/preferences.json)
  ok "preferences.json — voice_mode=$vm"
} || warn "preferences.json missing (will be created on first /voice command)"

# Tenant timezone consistency check
tz_yaml=$(grep '^timezone:' {{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/vps-setup/tenants/{{TENANT_LINUX_USER}}.yml | awk -F'"' '{print $2}')
if [[ "$tz_yaml" == "{{TENANT_TIMEZONE}}" ]]; then ok "tenant.yml timezone = {{TENANT_WEATHER_LABEL}}"
else fail "tenant.yml timezone = $tz_yaml (expected {{TENANT_TIMEZONE}})"; fi

# All timer files should reference {{TENANT_WEATHER_LABEL}}
hf_count=$(grep -l '{{TENANT_TIMEZONE}}' /etc/systemd/system/*.timer /etc/systemd/system/*.service 2>/dev/null | wc -l)
if [[ "$hf_count" -eq 0 ]]; then ok "No {{TENANT_WEATHER_LABEL}} references in /etc/systemd/system/"
else fail "$hf_count units still reference {{TENANT_TIMEZONE}}"; fi

# ───────────────────────────────────────────────────────────────────────────
section "7. WATCHER DEDUP LOGS (notifications/)"
# ───────────────────────────────────────────────────────────────────────────
NOTIF_DIR={{TENANT_AGENT_HOME}}/notifications
[[ -d "$NOTIF_DIR" ]] && ok "notifications/ exists" || fail "notifications/ missing"
for log in deadline-nudges goal-nudges stalled-deal-nudges disk-space-nudges; do
  if [[ -f "$NOTIF_DIR/$log.jsonl" ]]; then
    lines=$(wc -l < "$NOTIF_DIR/$log.jsonl")
    ok "$log.jsonl ($lines entries)"
  else
    warn "$log.jsonl not yet created (no nudges fired)"
  fi
done

# ───────────────────────────────────────────────────────────────────────────
section "8. WATCHDOG / BUN-DEATH STATE"
# ───────────────────────────────────────────────────────────────────────────
recent=$(awk -v c="$(date -d '30 min ago' -u +%FT%TZ)" '$1 >= c' /var/lib/{{TENANT_LINUX_USER}}/watchdog-restart-history.txt 2>/dev/null | wc -l)
if [[ "$recent" -lt 3 ]]; then ok "Watchdog circuit breaker clean ($recent restarts in last 30 min, threshold 3)"
else fail "Watchdog at $recent restarts in 30 min — breaker about to trip"; fi

bun_count=$(ps -ef | grep -c '[b]un.*claude-plugins-official/telegram')
if [[ "$bun_count" -ge 1 ]]; then ok "Telegram poller alive ($bun_count bun processes)"
else fail "No Telegram poller bun process"; fi

# ───────────────────────────────────────────────────────────────────────────
section "9. MORNING BRIEF DATA SOURCES"
# ───────────────────────────────────────────────────────────────────────────
# Verify external data sources are reachable (Open-Meteo, bible-api)
if curl -s --max-time 5 'https://api.open-meteo.com/v1/forecast?latitude={{TENANT_WEATHER_LAT}}&longitude={{TENANT_WEATHER_LON}}&current=temperature_2m' | jq -e .current >/dev/null 2>&1; then
  ok "Open-Meteo ({{TENANT_WEATHER_LABEL}} weather) reachable"
else fail "Open-Meteo unreachable"; fi
if curl -s --max-time 5 'https://bible-api.com/proverbs+16:3' | jq -e .text >/dev/null 2>&1; then
  ok "bible-api.com reachable"
else warn "bible-api.com unreachable (fallback verses kick in)"; fi
# GHL API
GHL_API_KEY=$(jq -r '.mcpServers.ghl.env.GHL_API_KEY' {{TENANT_AGENT_HOME}}/.mcp.json)
GHL_LOC=$(jq -r '.mcpServers.ghl.env.GHL_LOCATION_ID' {{TENANT_AGENT_HOME}}/.mcp.json)
if curl -s --max-time 5 -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
  "https://services.leadconnectorhq.com/opportunities/search?location_id=$GHL_LOC&status=open&limit=1" \
  | jq -e .opportunities >/dev/null 2>&1; then
  ok "GHL API reachable + auth valid"
else fail "GHL API unreachable or auth broken"; fi

# ───────────────────────────────────────────────────────────────────────────
section "10. VOICE STACK"
# ───────────────────────────────────────────────────────────────────────────
WHISPER_BIN={{TENANT_USER_HOME}}/whisper.cpp/build/bin/whisper-cli
[[ -x "$WHISPER_BIN" ]] && ok "whisper-cli present" || fail "whisper-cli missing"
[[ -f {{TENANT_USER_HOME}}/whisper.cpp/models/ggml-small.bin ]] && ok "whisper multilingual model present" || fail "multilingual model missing"
[[ -x {{TENANT_USER_HOME}}/.local/bin/edge-tts ]] && ok "edge-tts present" || fail "edge-tts missing"

# ───────────────────────────────────────────────────────────────────────────
section "11. PROPOSAL FILES (Chief-of-Staff layer)"
# ───────────────────────────────────────────────────────────────────────────
if [[ -d {{TENANT_AGENT_HOME}}/proposals ]]; then
  today_props={{TENANT_AGENT_HOME}}/proposals/$(date -u +%Y-%m-%d).json
  if [[ -f "$today_props" ]]; then
    n=$(jq -r '.proposals | length' "$today_props")
    ok "Today's proposals file exists with $n proposals"
  else
    warn "Today's proposals file not yet generated (will be created at 9 AM)"
  fi
else
  warn "proposals/ directory missing (will be created on first run)"
fi

# ───────────────────────────────────────────────────────────────────────────
section "12. GRAPHIFY KNOWLEDGE GRAPH"
# ───────────────────────────────────────────────────────────────────────────
GRAPHIFY_BIN={{TENANT_USER_HOME}}/.local/bin/graphify
[[ -x "$GRAPHIFY_BIN" ]] && ok "graphify CLI present" || fail "graphify CLI missing"

[[ -f {{TENANT_USER_HOME}}/.claude/skills/graphify/SKILL.md ]] && ok "graphify skill installed" || fail "graphify skill missing"

PROJECT_GRAPH={{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/graphify-out/graph.json
if [[ -f "$PROJECT_GRAPH" ]]; then
  nodes=$(jq '.nodes | length' "$PROJECT_GRAPH" 2>/dev/null || echo 0)
  links=$(jq '.links | length' "$PROJECT_GRAPH" 2>/dev/null || echo 0)
  if [[ "$nodes" -gt 0 && "$links" -gt 0 ]]; then
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$PROJECT_GRAPH") ) / 86400 ))
    if [[ "$age_days" -lt 10 ]]; then
      ok "project graph: $nodes nodes / $links links (${age_days}d old)"
    else
      warn "project graph stale ($age_days days old) — run graphify-rebuild.service"
    fi
  else
    fail "project graph empty: $nodes nodes / $links links"
  fi
else
  warn "project graph not built yet"
fi

# ───────────────────────────────────────────────────────────────────────────
section "13. AUTONOMY DASHBOARD ENDPOINTS"
# ───────────────────────────────────────────────────────────────────────────
API_DIR=/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api
for ep in jobs growth proposals security watchers daily-brief; do
  f="$API_DIR/$ep.json"
  if [[ -f "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
    ok "/api/$ep.json present + valid JSON"
  else
    fail "/api/$ep.json missing or invalid"
  fi
done
DASH_HTML=/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/index.html
if [[ -f "$DASH_HTML" ]]; then
  missing=""
  for tab in briefing proposals growth jobs budget security automation; do
    grep -q "data-tab-content=\"$tab\"" "$DASH_HTML" || missing="$missing $tab"
  done
  [[ -z "$missing" ]] && ok "dashboard has all 7 autonomy tabs" || fail "dashboard missing tabs:$missing"
else
  fail "dashboard index.html missing"
fi

# ───────────────────────────────────────────────────────────────────────────
section "14. DASHBOARD UX (Kanban · tooltips · task write-back)"
# ───────────────────────────────────────────────────────────────────────────
DASH_HTML=/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/index.html
if [[ -f "$DASH_HTML" ]]; then
  grep -q 'id="kanban-board"' "$DASH_HTML" && grep -q 'data-action="tasks-view"' "$DASH_HTML" \
    && ok "Tasks Kanban board (List⇄Board) present" || fail "Kanban board markup missing"
  grep -q 'mc-tip-pop' "$DASH_HTML" && grep -q 'const infoDot' "$DASH_HTML" \
    && ok "ⓘ tooltip system present" || fail "tooltip system missing"
else
  fail "dashboard index.html missing (UX checks)"
fi
# Task state write-back endpoint: bad input must 400 (proves it's wired, no side effect).
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST 127.0.0.1:8001/api/task/state \
  -H "Content-Type: application/json" -d '{"id":"smoke-test","state":"__bogus__"}' 2>/dev/null || echo 000)
if [[ "$code" == "400" ]]; then ok "/api/task/state endpoint wired (rejects bad state)"
else fail "/api/task/state endpoint not responding correctly (got $code)"; fi

# ───────────────────────────────────────────────────────────────────────────
section "15. DASHBOARD UX PASS 2 (briefing AI · growth analytics · Cmd-K)"
# ───────────────────────────────────────────────────────────────────────────
if [[ -f "$DASH_HTML" ]]; then
  grep -q 'id="brief-exec"' "$DASH_HTML" && ok "Briefing executive-summary card present" || fail "exec-summary card missing"
  grep -q 'id="growth-chart"' "$DASH_HTML" && grep -q 'data-action="growth-apply"' "$DASH_HTML" \
    && ok "Self-Growth analytics (chart + inline apply/skip) present" || fail "growth analytics missing"
  grep -q 'id="palette"' "$DASH_HTML" && grep -q 'buildPaletteItems' "$DASH_HTML" \
    && ok "Cmd-K command palette present" || fail "command palette missing"
fi
# daily-brief.json carries the executive_summary block (reused morning-brief LLM).
if jq -e '.executive_summary' "$API_DIR/daily-brief.json" >/dev/null 2>&1; then
  ok "daily-brief.json has executive_summary block"
else
  fail "daily-brief.json missing executive_summary"
fi

# ───────────────────────────────────────────────────────────────────────────
section "16. AGENT + VPS OBSERVABILITY (system · sub-agents · graph)"
# ───────────────────────────────────────────────────────────────────────────
for ep in system agents graph; do
  f="$API_DIR/$ep.json"
  if [[ -f "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then ok "/api/$ep.json present + valid JSON"
  else fail "/api/$ep.json missing or invalid"; fi
done
# Sanity: system has disk, agents has the registry, graph picked the rich graph.
jq -e '.disk.total > 0' "$API_DIR/system.json" >/dev/null 2>&1 && ok "system.json reports disk usage" || fail "system.json disk missing"
agc=$(jq -r '.count // 0' "$API_DIR/agents.json" 2>/dev/null)
[[ "$agc" -ge 1 ]] && ok "agents.json registry ($agc agents)" || fail "agents.json registry empty"
gn=$(jq -r '.summary.nodes // 0' "$API_DIR/graph.json" 2>/dev/null)
[[ "$gn" -ge 1 ]] && ok "graph.json summary ($gn nodes)" || fail "graph.json summary empty"
if [[ -f "$DASH_HTML" ]]; then
  miss=""
  for tab in agents graph system; do grep -q "data-tab-content=\"$tab\"" "$DASH_HTML" || miss="$miss $tab"; done
  [[ -z "$miss" ]] && ok "dashboard has agents/graph/system tabs" || fail "dashboard missing tabs:$miss"
  grep -q 'id="graph-canvas"' "$DASH_HTML" && ok "knowledge-graph canvas present" || fail "graph canvas missing"
fi

# ───────────────────────────────────────────────────────────────────────────
section "17. GRAPHIFY GraphRAG (merged graph · Ask-the-Graph · feedback loop)"
# ───────────────────────────────────────────────────────────────────────────
MERGED="{{TENANT_AGENT_HOME}}/graphify-out/merged-graph.json"
if [[ -f "$MERGED" ]]; then
  mn=$(jq -r '.nodes|length' "$MERGED" 2>/dev/null || echo 0)
  [[ "$mn" -ge 1 ]] && ok "unified merged-graph.json ($mn nodes)" || fail "merged-graph.json empty"
else
  fail "merged-graph.json missing (run graphify-rebuild)"
fi
# Ask-the-Graph endpoint wired (bad input → 400, no side effect).
gcode=$(curl -s -o /dev/null -w "%{http_code}" -X POST 127.0.0.1:8001/api/graph/query \
  -H "Content-Type: application/json" -d '{"q":""}' 2>/dev/null || echo 000)
[[ "$gcode" == "400" ]] && ok "/api/graph/query endpoint wired" || fail "/api/graph/query not responding ($gcode)"
gacode=$(curl -s -o /dev/null -w "%{http_code}" -X POST 127.0.0.1:8001/api/graph/add \
  -H "Content-Type: application/json" -d '{"url":"notaurl"}' 2>/dev/null || echo 000)
[[ "$gacode" == "400" ]] && ok "/api/graph/add endpoint wired" || fail "/api/graph/add not responding ($gacode)"
if [[ -f "$DASH_HTML" ]]; then
  grep -q 'id="graph-q"' "$DASH_HTML" && grep -q "data-action=\"graph-ask\"" "$DASH_HTML" \
    && ok "Ask-the-Graph panel present" || fail "Ask-the-Graph panel missing"
fi
grep -q '/graph <question>' "{{TENANT_AGENT_HOME}}/CLAUDE.md" 2>/dev/null && ok "/graph wired into agent (CLAUDE.md)" || warn "/graph not in CLAUDE.md"

# ───────────────────────────────────────────────────────────────────────────
section "FINAL"
# ───────────────────────────────────────────────────────────────────────────
echo
echo "Passed: $PASS    Failed: $FAIL    Warnings: $WARN"
echo
if [[ $FAIL -gt 0 || $WARN -gt 0 ]]; then
  echo "Issues:"
  for i in "${ISSUES[@]}"; do echo "  - $i"; done
fi
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
