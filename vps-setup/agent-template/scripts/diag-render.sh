#!/usr/bin/env bash
# diag-render.sh — diagnostic dump for "something seems off" moments.
# Prints a MarkdownV2 message with: last 5 task ledger events, recent
# claude-agent restart history (last 5), bun-death diagnostic snapshot
# count, and last 30 lines of claude-agent journal (truncated).
#
# v2.27.0+. Used by the agent's /diag slash command (CLAUDE.md spec).
# Heavier than /status — meant for troubleshooting, not for routine checks.
set -uo pipefail

LEDGER="{{TENANT_AGENT_HOME}}/tasks/ledger.jsonl"
RESTART_HISTORY="/var/lib/{{TENANT_LINUX_USER}}/watchdog-restart-history.txt"
RESTART_HISTORY_FALLBACK="{{TENANT_AGENT_HOME}}/watchdog-restart-history.txt"
BUN_DIAG_LOG="/var/log/{{TENANT_LINUX_USER}}-bun-death-diagnostics.log"

mdv2() {
  sed -e 's/\\/\\\\/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' \
      -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g' -e 's/~/\\~/g' \
      -e 's/`/\\`/g' -e 's/>/\\>/g' -e 's/#/\\#/g' -e 's/+/\\+/g' \
      -e 's/-/\\-/g' -e 's/=/\\=/g' -e 's/|/\\|/g' -e 's/{/\\{/g' \
      -e 's/}/\\}/g' -e 's/\./\\./g' -e 's/!/\\!/g' <<< "$1"
}

# 1. Last 5 ledger events — id, event, state, summary excerpt
ledger_events=""
if [[ -r "$LEDGER" ]]; then
  ledger_events=$(tail -5 "$LEDGER" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        ts = e.get('ts','')[:19]
        eid = e.get('id','')
        ev = e.get('event','')
        st = e.get('state','')
        msg = (e.get('msg') or e.get('summary') or '')[:80]
        print(f'  {ts} {eid} {ev}/{st} — {msg}')
    except Exception:
        pass
" 2>/dev/null)
fi

# 2. Restart history — last 5
restart_log="$RESTART_HISTORY"
[[ ! -r "$restart_log" ]] && restart_log="$RESTART_HISTORY_FALLBACK"
restarts=""
if [[ -r "$restart_log" ]]; then
  restarts=$(tail -5 "$restart_log" 2>/dev/null | awk '{printf "  %s\n", $0}')
fi
restart_count_30min=$(systemctl show claude-agent.service -p NRestarts --value 2>/dev/null || echo "?")

# 3. Bun-death diagnostic snapshot count (each snapshot is ~5-10 lines)
bun_diag_snapshots=0
if [[ -r "$BUN_DIAG_LOG" ]]; then
  bun_diag_snapshots=$(grep -c "^================" "$BUN_DIAG_LOG" 2>/dev/null || echo 0)
  bun_diag_snapshots=$((bun_diag_snapshots / 2))  # each snapshot has 2 separator lines
fi

# 4. Last 30 lines of claude-agent journal (truncated to fit Telegram)
journal=$(journalctl -u claude-agent.service --no-pager -n 30 2>/dev/null \
  | tail -30 \
  | sed 's/^[A-Z][a-z][a-z] [0-9 ]\{2\} //' \
  | head -c 2000)

ESC_JOURNAL=$(mdv2 "${journal:-(no recent journal)}")
ESC_LEDGER=$(mdv2 "${ledger_events:-  (no recent events)}")
ESC_RESTARTS=$(mdv2 "${restarts:-  (no restart history)}")

cat <<EOF
*Mission Control diagnostic dump* 🔧

*Service restarts \(systemd lifetime\):* ${restart_count_30min}
*Bun\-death diagnostic snapshots accumulated:* ${bun_diag_snapshots}

*Last 5 watchdog restart timestamps:*
\`\`\`
${ESC_RESTARTS}
\`\`\`

*Last 5 task ledger events:*
\`\`\`
${ESC_LEDGER}
\`\`\`

*Last 30 lines of claude\-agent journal:*
\`\`\`
${ESC_JOURNAL}
\`\`\`

If something looks broken: run \`/status\` for routine snapshot, or ssh in to dig deeper\.
EOF
