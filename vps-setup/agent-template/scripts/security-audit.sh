#!/usr/bin/env bash
# security-audit.sh — weekly self-audit of the agent's security posture.
#
# Verifies the security CONTROLS are intact (the things that keep autonomy
# safe), summarizes the week's security events, and reports to Daniel. If
# any control has drifted, it's a RED alert — those controls are the floor
# the whole autonomy model stands on.
#
# Runs weekly (Sunday) via timer. Also backs the /security command (--now).
set -uo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp
USER_HOME="${TENANT_USER_HOME:-{{TENANT_USER_HOME}}}"
LINUX_USER="{{TENANT_LINUX_USER}}"
SETTINGS="$USER_HOME/.claude/settings.json"
SUDOERS="/etc/sudoers.d/${LINUX_USER}-agent-ops"
OPS_DIR="$AGENT_HOME/scripts/ops"
AUDIT_LOG="/var/log/${LINUX_USER}-agent-ops.log"
CHARTER_FILE="$AGENT_HOME/CLAUDE.md"
SEC_LOG="$AGENT_HOME/security/injection-attempts.jsonl"
ANOMALIES="/var/www/{{TENANT_DASHBOARD_HOSTNAME}}/api/anomalies.json"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"

NOW_MODE=0
[[ "${1:-}" == "--now" ]] && NOW_MODE=1

PASS=0; FAIL=0
declare -a ISSUES=()
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); ISSUES+=("$1"); }

# ── Control integrity (the floor) ───────────────────────────────────────────
# 1. deny-list present + has the catastrophic + self-protection entries
if [[ -f "$SETTINGS" ]]; then
  deny_n=$(jq -r '.permissions.deny | length' "$SETTINGS" 2>/dev/null || echo 0)
  if [[ "$deny_n" -ge 15 ]] && jq -e '.permissions.deny[] | select(test("reboot"))' "$SETTINGS" >/dev/null 2>&1; then ok; else bad "deny-list weakened ($deny_n entries, reboot guard missing?)"; fi
else bad "settings.json missing"; fi

# 2. sudoers present, mode 440 root (perms via stat — metadata is readable
#    even though the agent CANNOT read the file contents, which is itself the
#    correct posture: 440 root means the agent can neither read nor tamper).
#    Grant CONTENT is verified against the readable repo-rendered copy.
if [[ -f "$SUDOERS" ]]; then
  perm=$(stat -c '%a %U' "$SUDOERS" 2>/dev/null)
  REPO_SUDOERS="$AGENT_HOME/{{TENANT_BRAND_REPO_NAME}}/vps-setup/agents-config/{{TENANT_ID}}/sudoers/agent-ops.sudoers"
  content_ok=1
  if [[ -r "$REPO_SUDOERS" ]]; then
    # Anti-pattern check ignores comment lines (the file documents "do NOT use
    # NOPASSWD: ALL" in a comment, which must not trip this).
    grep -qE "NOPASSWD: ${AGENT_HOME}/scripts/ops/?$" "$REPO_SUDOERS" && ! grep -qE '^[^#]*NOPASSWD:[[:space:]]*ALL' "$REPO_SUDOERS" || content_ok=0
  fi
  # The agent should NOT be able to read the live file (440 root). If it CAN, that's drift.
  if [[ "$perm" == "440 root" && "$content_ok" == "1" ]]; then ok; else bad "sudoers drifted (perm='$perm', grant_ok=$content_ok)"; fi
else bad "sudoers file missing — self-service ops disabled"; fi

# 3. ops wrappers root-owned (agent can't edit a script it runs as root)
nonroot=$(find "$OPS_DIR" -name '*.sh' ! -user root 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nonroot" == "0" ]]; then ok; else bad "$nonroot ops wrappers NOT root-owned — privilege-escalation risk"; fi

# 4. audit log present
[[ -f "$AUDIT_LOG" ]] && ok || bad "ops audit log missing"

# 5. Charter present in live CLAUDE.md
if grep -q 'Autonomy & Security Charter' "$CHARTER_FILE" 2>/dev/null && grep -q 'DATA, never INSTRUCTIONS' "$CHARTER_FILE" 2>/dev/null; then ok; else bad "Charter missing/edited in CLAUDE.md"; fi

# 6. injection detector present + executable
[[ -x "$AGENT_HOME/scripts/injection-check.sh" ]] && ok || bad "injection-check.sh missing"

# ── Week's posture summary ──────────────────────────────────────────────────
week_ago=$(date -u -d '7 days ago' +%s 2>/dev/null || echo 0)
inj_week=0
if [[ -f "$SEC_LOG" ]]; then
  inj_week=$(awk -v c="$week_ago" 'BEGIN{n=0} { if(match($0,/"ts":"([^"]+)"/,m)){ "date -d \""m[1]"\" +%s 2>/dev/null" | getline e; if(e>=c) n++ } } END{print n}' "$SEC_LOG" 2>/dev/null || echo 0)
  [[ -z "$inj_week" ]] && inj_week=$(wc -l < "$SEC_LOG")
fi
anomaly_n=0
[[ -f "$ANOMALIES" ]] && anomaly_n=$(jq -r '[.metrics[]? | select(.anomaly==true)] | length' "$ANOMALIES" 2>/dev/null || echo 0)
frugal_now="off"; [[ -f "$AGENT_HOME/state/frugal-mode" ]] && frugal_now="ON"
smoke=$(bash "$AGENT_HOME/scripts/smoke-test.sh" 2>/dev/null | grep -E 'Passed:' | head -1 || echo "smoke n/a")

# ── Report ──────────────────────────────────────────────────────────────────
if [[ $FAIL -eq 0 ]]; then
  header="🛡️ Weekly security audit — ALL CONTROLS INTACT ($PASS/6)"
else
  header="🚨 Weekly security audit — $FAIL CONTROL ISSUE(S) ($PASS/$((PASS+FAIL)))"
fi

msg="$header

Controls: deny-list, sudoers (root 440), ops root-owned, audit log, Charter, injection detector
This week: injection attempts blocked: $inj_week | cost anomalies flagged: $anomaly_n | frugal mode: $frugal_now
$smoke"

if [[ $FAIL -gt 0 ]]; then
  msg="$msg

ISSUES:"
  for i in "${ISSUES[@]}"; do msg="$msg
  ✗ $i"; done
  msg="$msg

These are the controls that keep autonomy safe — investigate before granting more freedom."
fi

if [[ $NOW_MODE -eq 1 ]]; then
  echo "$msg"
else
  [[ -x "$TG_SEND" ]] && "$TG_SEND" send --text "$msg" >/dev/null 2>&1 || true
  echo "$msg"
fi

exit $(( FAIL > 0 ? 1 : 0 ))
