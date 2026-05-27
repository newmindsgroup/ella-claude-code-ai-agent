#!/usr/bin/env bash
# website-uptime-watcher.sh — proactive Telegram nudge when a monitored
# website goes down, returns slow responses, or comes back online.
#
# Why: {{TENANT_PERSON_FIRST_NAME}}'s public-facing website is the front door for
# inbound. If it 5xx's or times out, every visitor sees broken; if a deploy
# leaves it slow, conversion craters. Knowing within ~10 min beats finding out
# from a customer.
#
# What it checks per URL:
#   - HTTP status code (curl -w)
#   - Response time (--max-time, --connect-timeout)
#   - Body sanity (optional — set WEBSITE_UPTIME_EXPECT_STR to a substring
#     that must appear in the response, e.g. tenant name)
#
# States and dedup:
#   - down:      HTTP >=500, 4xx other than 401/403/429, OR curl error/timeout
#                → alert once per HOUR while in down state (so you know it's
#                still down without spam)
#   - slow:      total time > WEBSITE_UPTIME_SLOW_MS (default 5000)
#                → info nudge once per DAY
#   - recovered: previous state was down, now ok
#                → ALWAYS fire on the transition (recovery is rare + useful)
#
# Each URL keeps its own state file under
#   {{TENANT_AGENT_HOME}}/notifications/website-uptime-state/<sha8>.state
# Dedup keys live in {{TENANT_AGENT_HOME}}/notifications/website-uptime-nudges.jsonl
#
# URLs watched:
#   - default: $TENANT_WEBSITE_URL (set by systemd from tenant.yml `website_url`)
#   - override: WEBSITE_UPTIME_URLS="https://a.com https://b.com"
#   - extras:   WEBSITE_UPTIME_EXTRA_URLS appended to the default
set -uo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
TENANT_WEBSITE_URL="${TENANT_WEBSITE_URL:-{{TENANT_WEBSITE_URL}}}"
NUDGE_LOG="$TENANT_AGENT_HOME/notifications/website-uptime-nudges.jsonl"
STATE_DIR="$TENANT_AGENT_HOME/notifications/website-uptime-state"
TG_SEND="$TENANT_AGENT_HOME/scripts/tg-send.sh"

mkdir -p "$(dirname "$NUDGE_LOG")" "$STATE_DIR"
touch "$NUDGE_LOG"

[[ ! -x "$TG_SEND" ]] && { echo "ERROR: $TG_SEND not executable" >&2; exit 1; }

# Tunables
TIMEOUT_SEC="${WEBSITE_UPTIME_TIMEOUT_SEC:-15}"
CONNECT_TIMEOUT_SEC="${WEBSITE_UPTIME_CONNECT_TIMEOUT_SEC:-8}"
SLOW_MS="${WEBSITE_UPTIME_SLOW_MS:-5000}"
EXPECT_STR="${WEBSITE_UPTIME_EXPECT_STR:-}"

# Build URL list. Override > default + extras.
if [[ -n "${WEBSITE_UPTIME_URLS:-}" ]]; then
  # shellcheck disable=SC2206
  URLS=( $WEBSITE_UPTIME_URLS )
else
  URLS=()
  [[ -n "$TENANT_WEBSITE_URL" ]] && URLS+=( "$TENANT_WEBSITE_URL" )
  if [[ -n "${WEBSITE_UPTIME_EXTRA_URLS:-}" ]]; then
    # shellcheck disable=SC2206
    URLS+=( ${WEBSITE_UPTIME_EXTRA_URLS} )
  fi
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "website-uptime-watcher: no URLs to check (set TENANT_WEBSITE_URL or WEBSITE_UPTIME_URLS)"
  exit 0
fi

now_epoch=$(date -u +%s)
today=$(date -u +%Y-%m-%d)
this_hour=$(date -u +%Y-%m-%dT%H)
nudges_sent=0

check_url() {
  local url="$1"
  local sha8 state_file prev_state body http_code time_total time_total_ms curl_exit
  sha8=$(printf '%s' "$url" | shasum -a 256 | cut -c1-8)
  state_file="$STATE_DIR/$sha8.state"
  prev_state="ok"
  [[ -f "$state_file" ]] && prev_state=$(cat "$state_file" 2>/dev/null || echo "ok")

  # Single curl call captures status + total time + body (truncated). The
  # --write-out token at end of body lets us parse both in one round trip.
  local out
  out=$(curl -sS -L \
    --max-time "$TIMEOUT_SEC" \
    --connect-timeout "$CONNECT_TIMEOUT_SEC" \
    -H "User-Agent: {{TENANT_ID}}-uptime-watcher/1.0" \
    -o /tmp/uptime-body-$$ \
    -w "%{http_code} %{time_total}" \
    "$url" 2>&1) || curl_exit=$?
  curl_exit="${curl_exit:-0}"

  if [[ $curl_exit -ne 0 ]]; then
    http_code="000"
    time_total="0"
  else
    http_code=$(echo "$out" | awk '{print $1}')
    time_total=$(echo "$out" | awk '{print $2}')
  fi
  time_total_ms=$(awk -v t="$time_total" 'BEGIN { printf "%d", t * 1000 }')

  # Classify
  local new_state="ok" detail=""
  if [[ $curl_exit -ne 0 ]]; then
    new_state="down"
    detail="curl exit $curl_exit (timeout/connect/dns)"
  elif [[ $http_code -ge 500 ]]; then
    new_state="down"
    detail="HTTP $http_code"
  elif [[ $http_code -ge 400 && $http_code -ne 401 && $http_code -ne 403 && $http_code -ne 429 ]]; then
    new_state="down"
    detail="HTTP $http_code"
  elif [[ -n "$EXPECT_STR" ]] && ! grep -q "$EXPECT_STR" /tmp/uptime-body-$$ 2>/dev/null; then
    new_state="down"
    detail="HTTP $http_code but body missing expected '$EXPECT_STR'"
  elif [[ $time_total_ms -gt $SLOW_MS ]]; then
    new_state="slow"
    detail="${time_total_ms}ms (>${SLOW_MS}ms)"
  fi
  rm -f /tmp/uptime-body-$$ 2>/dev/null

  echo "$new_state" > "$state_file"

  # Decide whether to nudge
  local cooldown_key="" msg="" emoji=""
  case "$new_state:$prev_state" in
    ok:down)
      cooldown_key="$url:recovered:$now_epoch"
      emoji="✅"
      msg=$(printf "%s %s is back online\n\nHTTP %s in %dms" "$emoji" "$url" "$http_code" "$time_total_ms")
      ;;
    down:*)
      cooldown_key="$url:down:$this_hour"
      emoji="🚨"
      msg=$(printf "%s Website DOWN: %s\n\n%s\nLast OK: %s" "$emoji" "$url" "$detail" "$(last_ok_at "$state_file" || echo 'unknown')")
      ;;
    slow:*)
      cooldown_key="$url:slow:$today"
      emoji="🐢"
      msg=$(printf "%s Website slow: %s\n\n%s" "$emoji" "$url" "$detail")
      ;;
    ok:slow)
      # silent recovery from slow → ok
      :
      ;;
    *)
      # ok:ok — nothing to do
      :
      ;;
  esac

  if [[ -n "$cooldown_key" && -n "$msg" ]]; then
    if grep -qF "\"$cooldown_key\"" "$NUDGE_LOG" 2>/dev/null; then
      return 0  # already alerted this window
    fi
    if "$TG_SEND" send --text "$msg" >/dev/null 2>&1; then
      printf '{"key":"%s","sent_at":"%s","url":"%s","state":"%s","http":"%s","time_ms":%d}\n' \
        "$cooldown_key" "$(date -u +%FT%TZ)" "$url" "$new_state" "$http_code" "$time_total_ms" \
        >> "$NUDGE_LOG"
      nudges_sent=$((nudges_sent + 1))
    fi
  fi
}

# Best-effort "last ok timestamp" by scanning the nudge log for the most
# recent recovery. Falls back to a placeholder if none.
last_ok_at() {
  local state_file="$1" url
  url=$(basename "$state_file" .state)
  grep -F "\"recovered\"" "$NUDGE_LOG" 2>/dev/null | tail -1 | grep -oE '"sent_at":"[^"]*"' | head -1 | cut -d'"' -f4
}

for url in "${URLS[@]}"; do
  check_url "$url"
done

echo "website-uptime-watcher: $nudges_sent nudges sent at $(date -u +%FT%TZ) — checked ${#URLS[@]} URL(s)"
