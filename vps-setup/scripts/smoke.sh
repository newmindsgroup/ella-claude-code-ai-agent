#!/usr/bin/env bash
# smoke.sh — exercise every /api/* endpoint and validate against JSON Schema.
#
# Closes the bug class surfaced during v2.20.0 deploy: dashboard JS bound to
# response shapes that didn't match what the server actually emitted (NaN tok,
# empty bubbles, broken telemetry tab). With schemas as the API contract, any
# drift between server output and dashboard expectation surfaces here.
#
# Usage:
#   bash vps-setup/scripts/smoke.sh <hostname> <user> <password>
#   bash vps-setup/scripts/smoke.sh {{TENANT_DASHBOARD_HOSTNAME}} daniel "$pw"
#
# The password may also be sourced via $BASIC_AUTH_PW. NEVER paste it inline
# in shell history — use:
#   read -rs -p "BASIC_AUTH_PW: " BASIC_AUTH_PW && export BASIC_AUTH_PW
#
# Exit codes:
#   0 — all endpoints PASS schema validation
#   1 — one or more FAIL
#   2 — invalid args

set -uo pipefail

HOST="${1:-}"
USER="${2:-daniel}"
PW="${3:-${BASIC_AUTH_PW:-}}"

[[ -z "$HOST" || -z "$PW" ]] && {
  echo "usage: $0 <hostname> [<user>] <password>" >&2
  echo "  or set BASIC_AUTH_PW env var and pass <hostname> only" >&2
  exit 2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMAS="$REPO_ROOT/vps-setup/schemas"
[[ ! -d "$SCHEMAS" ]] && { echo "schemas dir not found: $SCHEMAS" >&2; exit 2; }

PASS=0
FAIL=0
SKIP=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
skip() { echo "[SKIP] $*"; SKIP=$((SKIP+1)); }

echo "smoke: host=$HOST user=$USER schemas=$SCHEMAS"
echo "----"

# Helper: fetch + JSON validate + schema validate. Returns 0 on PASS, 1 on FAIL,
# 2 if endpoint returns 404 (treated as SKIP — endpoint not yet implemented).
fetch_and_validate() {
  local label="$1" path="$2" schema_file="$3" required="${4:-true}"
  local tmp; tmp=$(mktemp)
  local code
  code=$(curl -sS -u "$USER:$PW" -o "$tmp" -w "%{http_code}" "https://$HOST$path" 2>/dev/null || echo "000")
  if [[ "$code" == "404" ]]; then
    rm -f "$tmp"
    if [[ "$required" == "true" ]]; then
      bad "$label: HTTP 404 (endpoint missing)"
      return 1
    else
      skip "$label: HTTP 404 (endpoint not yet implemented — see v2.22.0 backlog)"
      return 2
    fi
  fi
  if [[ "$code" != "200" ]]; then
    bad "$label: HTTP $code"
    rm -f "$tmp"
    return 1
  fi

  # JSON parse + schema validate inline.
  if python3 - "$tmp" "$schema_file" "$label" <<'PY'
import json, sys
from jsonschema import Draft202012Validator
data_file, schema_file, label = sys.argv[1:]
try:
    data = json.load(open(data_file))
except Exception as e:
    print(f"  invalid JSON: {e}"); sys.exit(1)
schema = json.load(open(schema_file))
v = Draft202012Validator(schema)
errors = sorted(v.iter_errors(data), key=lambda e: list(e.path))
if errors:
    for e in errors[:5]:
        path = "/".join(str(p) for p in e.path) or "<root>"
        print(f"  schema violation at {path}: {e.message[:150]}")
    if len(errors) > 5:
        print(f"  ...and {len(errors)-5} more")
    sys.exit(1)
sys.exit(0)
PY
  then
    ok "$label (HTTP 200, schema valid)"
    rm -f "$tmp"
    return 0
  else
    bad "$label: schema mismatch"
    rm -f "$tmp"
    return 1
  fi
}

# 1) /api/tasks.json
fetch_and_validate "GET /api/tasks.json" "/api/tasks.json" "$SCHEMAS/tasks.schema.json"

# 2) /api/telemetry.json — also assert rollup.week exists (per runbook).
fetch_and_validate "GET /api/telemetry.json" "/api/telemetry.json" "$SCHEMAS/telemetry.schema.json"
WEEK_OK=$(curl -fsS -u "$USER:$PW" "https://$HOST/api/telemetry.json" 2>/dev/null | \
          python3 -c "import sys,json; d=json.load(sys.stdin); print('1' if d.get('rollup',{}).get('week') else '0')")
if [[ "$WEEK_OK" == "1" ]]; then
  ok "telemetry.json: rollup.week present"
else
  bad "telemetry.json: rollup.week MISSING"
fi

# 3) /api/goals.json
fetch_and_validate "GET /api/goals.json" "/api/goals.json" "$SCHEMAS/goals.schema.json"

# 4) /api/queue.json — implemented in v2.24.2 (was 404 in v2.20.0–v2.24.1).
fetch_and_validate "GET /api/queue.json" "/api/queue.json" "$SCHEMAS/queue.schema.json"

# 5) /api/memory.json
fetch_and_validate "GET /api/memory.json" "/api/memory.json" "$SCHEMAS/memory.schema.json"

# 6) /api/chat/health (FastAPI backend on 127.0.0.1:8001)
fetch_and_validate "GET /api/chat/health" "/api/chat/health" "$SCHEMAS/chat-health.schema.json"

# 6.5) /api/health.json (system-level health, written by dashboard-sync.sh) — v2.24.2+
fetch_and_validate "GET /api/health.json" "/api/health.json" "$SCHEMAS/health.schema.json"

# 7) /api/chat — POST round-trip with real Claude call.
echo "[....] POST /api/chat (real round-trip; ~6-10s)"
CHAT_RESP=$(mktemp)
CHAT_HTTP=$(curl -sS --max-time 180 -u "$USER:$PW" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Reply with the single word PONG and nothing else."}' \
  -o "$CHAT_RESP" -w "%{http_code}" \
  "https://$HOST/api/chat" 2>/dev/null || echo "000")
if [[ "$CHAT_HTTP" != "200" ]]; then
  bad "POST /api/chat: HTTP $CHAT_HTTP"
else
  python3 - "$CHAT_RESP" "$SCHEMAS/chat-response.schema.json" <<'PY' && \
    ok "POST /api/chat: HTTP 200, schema valid, real response" || \
    bad "POST /api/chat: schema mismatch or empty response"
import json, sys
from jsonschema import Draft202012Validator
data = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
errors = list(Draft202012Validator(schema).iter_errors(data))
if errors:
    for e in errors[:3]:
        path = "/".join(str(p) for p in e.path) or "<root>"
        print(f"  schema violation at {path}: {e.message[:150]}")
    sys.exit(1)
# Real-response assertions beyond schema.
resp = (data.get('response') or '').strip()
if not resp or 'no response' in resp.lower()[:20] or 'error' in resp.lower()[:20]:
    print(f"  fabricated response: {resp[:80]!r}")
    sys.exit(1)
out = data.get('tokens',{}).get('output_tokens', 0)
if out <= 0:
    print(f"  no output_tokens recorded: {data.get('tokens')}")
    sys.exit(1)
print(f"  response={resp[:60]!r} output_tokens={out} cost=${data['cost_usd']:.6f} {data['duration_seconds']:.2f}s")
PY
fi
rm -f "$CHAT_RESP"

# 8) /api/chat/history — schema validate AND hydration round-trip (just-sent
#    message must appear in the next history fetch). Closes the v2.20.0 chat
#    history hydration bug class.
HIST=$(mktemp)
HIST_HTTP=$(curl -sS -u "$USER:$PW" -o "$HIST" -w "%{http_code}" "https://$HOST/api/chat/history?limit=10" 2>/dev/null || echo "000")
if [[ "$HIST_HTTP" != "200" ]]; then
  bad "GET /api/chat/history: HTTP $HIST_HTTP"
else
  python3 - "$HIST" "$SCHEMAS/chat-history.schema.json" <<'PY' && \
    ok "GET /api/chat/history: HTTP 200, schema valid, just-sent prompt found in history" || \
    bad "GET /api/chat/history: schema or hydration round-trip failed"
import json, sys
from jsonschema import Draft202012Validator
data = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
errors = list(Draft202012Validator(schema).iter_errors(data))
if errors:
    for e in errors[:3]:
        path = "/".join(str(p) for p in e.path) or "<root>"
        print(f"  schema violation at {path}: {e.message[:150]}")
    sys.exit(1)
msgs = data.get('messages', [])
if not msgs:
    print("  history is empty — chat round-trip didn't persist")
    sys.exit(1)
# Hydration round-trip: PONG prompt sent above must appear in the latest entry.
latest = msgs[-1] if 'task_id' in msgs[-1] else msgs[0]
if 'PONG' not in (latest.get('prompt','') + latest.get('response','')):
    print(f"  latest history entry doesn't contain just-sent PONG turn: {latest.get('prompt','')[:60]!r}")
    sys.exit(1)
print(f"  history.len={len(msgs)} latest_task={latest['task_id']}")
PY
fi
rm -f "$HIST"

echo "----"
echo "smoke: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
