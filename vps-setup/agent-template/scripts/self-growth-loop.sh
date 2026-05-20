#!/usr/bin/env bash
# self-growth-loop.sh — the daily "get smarter" engine.
#
# Once a day: review what happened, identify the SINGLE highest-leverage
# improvement to the agent's own capabilities, then EITHER auto-apply it
# (if it's a safe additive GREEN-tier change) OR propose it for one-tap
# approval (if it changes existing behavior). Every learning is logged to
# growth-log.jsonl so the agent's growth is auditable over time.
#
# SAFETY MODEL (this is the riskiest automation in the stack — self-
# modification — so the rails matter):
#   - ONE improvement per run. No runaway self-editing.
#   - GREEN auto-apply = ADDITIVE ONLY (new skill file, new memory, new
#     helper). It NEVER edits existing scripts/CLAUDE.md autonomously.
#     The implementing job runs smoke-test.sh BEFORE committing; if smoke
#     fails it `git checkout`-reverts and reports failure instead of
#     committing broken code.
#   - YELLOW (anything that changes existing behavior — prompt edits,
#     CLAUDE.md, new watchers that cost/spam) = PROPOSE only. Staged in
#     drafts/self-improvement/, applied only when Daniel replies
#     `apply growth-<id>`.
#   - RED-tier targets (deny-list, sudoers, audit log, the Charter) are
#     NEVER touched — the LLM prompt forbids proposing them, and even if
#     it did, settings.json deny-list blocks the edit.
#   - Everything is git-committed (revertible) and announced on Telegram.
#
# Composes on Phase 2: the loop DECIDES; a dispatched background job
# IMPLEMENTS (so the heavy work runs detached, not on this timer).
set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
cd "$AGENT_HOME" 2>/dev/null || cd /tmp

REPO_DIR="$AGENT_HOME/{{TENANT_BRAND_REPO_NAME}}"
GROWTH_LOG="$AGENT_HOME/growth/growth-log.jsonl"
PROPOSAL_DIR="$AGENT_HOME/drafts/self-improvement"
TG_SEND="$AGENT_HOME/scripts/tg-send.sh"
DISPATCH="$AGENT_HOME/scripts/dispatch-job.sh"
LOG_DIR="$AGENT_HOME/logs"
TIMEOUT_SEC="${GROWTH_TIMEOUT_SEC:-240}"

mkdir -p "$(dirname "$GROWTH_LOG")" "$PROPOSAL_DIR" "$LOG_DIR"
touch "$GROWTH_LOG"

today=$(date -u +%Y-%m-%d)
log_file="$LOG_DIR/self-growth-$today.log"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$log_file" >&2; }

log "=== self-growth-loop started ==="

# ── Gather context (cheap, local reads) ─────────────────────────────────────
LEDGER_TAIL=$(tail -40 "$AGENT_HOME/tasks/ledger.jsonl" 2>/dev/null || echo "")
RECENT_PATTERNS=$(grep -rl 'type: pattern' "$AGENT_HOME/memory/" 2>/dev/null | xargs -r ls -t 2>/dev/null | head -8 | xargs -r cat 2>/dev/null | head -c 2000 || echo "")
REJECTED=$(tail -10 "$AGENT_HOME/proposals/rejected.jsonl" 2>/dev/null || echo "")
PRIOR_GROWTH=$(tail -15 "$GROWTH_LOG" 2>/dev/null || echo "")
SKILLS_LIST=$(ls "$AGENT_HOME/../.claude/skills/" 2>/dev/null | tr '\n' ' ' || echo "")
WATCHER_FAILS=$(grep -lE 'FATAL|ERROR' "$LOG_DIR"/*-watcher-*.log 2>/dev/null | head -5 | xargs -r basename -a 2>/dev/null | tr '\n' ' ' || echo "")

# ── The decision prompt ─────────────────────────────────────────────────────
PROMPT=$(cat <<EOF
You are running your DAILY SELF-GROWTH review. Identify the SINGLE highest-leverage improvement to your OWN capabilities today. Be concrete and small — one thing done well beats five vague ideas.

Today's signal:
- Recent task ledger events:
$LEDGER_TAIL

- Recent pattern memories (things Daniel kept correcting / preferences learned):
$RECENT_PATTERNS

- Recently rejected Proposed Moves (don't re-propose these shapes):
$REJECTED

- What you've already improved recently (DON'T repeat these):
$PRIOR_GROWTH

- Skills you already have: $SKILLS_LIST
- Watchers logging errors lately: ${WATCHER_FAILS:-none}

Pick ONE improvement. Classify its tier HONESTLY:
- "green" = purely ADDITIVE and isolated: a NEW skill file, a NEW memory, a NEW helper script that nothing else depends on yet. Cannot break existing behavior because nothing invokes it unless explicitly triggered. These auto-apply.
- "yellow" = changes EXISTING behavior: editing a prompt, editing CLAUDE.md, modifying an existing script, or a new watcher that costs money / sends messages. These get proposed for Daniel's approval, never auto-applied.

NEVER propose changes to: the settings.json deny-list, the sudoers file, the audit log, or the Autonomy & Security Charter. Those are RED-tier and off-limits to self-modification.

Output ONLY this JSON (no markdown, no preamble):
{
  "id": "growth-$(date -u +%Y%m%d)-aaaa",
  "title": "<= 80 chars, verb-led",
  "rationale": "1-2 sentences: what signal prompted this + why it's the highest-leverage move today",
  "tier": "green | yellow",
  "type": "skill | memory | helper | prompt | claude_md | watcher | optimization",
  "implementation_plan": "Exact steps to implement. For green: the precise file path(s) to CREATE and what goes in them. For yellow: what existing thing to change and how.",
  "expected_benefit": "Concrete: faster/cheaper/better at X",
  "files_created": ["list of NEW file paths this creates, empty if none"]
}

If genuinely nothing is worth improving today (rare), output {"id":"none","tier":"none","title":"no high-leverage improvement today","rationale":"...","type":"none","implementation_plan":"","expected_benefit":"","files_created":[]}.
EOF
)

log "invoking claude --print for the daily decision"
raw=$(timeout "$TIMEOUT_SEC" claude --permission-mode bypassPermissions --print "$PROMPT" 2>>"$log_file" || echo "")
[[ -z "$raw" ]] && { log "empty LLM response — exiting"; exit 0; }

json=$(echo "$raw" | sed -n '/^{/,/^}$/p' | head -60)
[[ -z "$json" ]] && json="$raw"
if ! echo "$json" | jq -e .tier >/dev/null 2>&1; then
  log "invalid JSON: $(echo "$raw" | head -c 200)"; exit 0
fi

TIER=$(echo "$json" | jq -r '.tier')
ID=$(echo "$json" | jq -r '.id')
TITLE=$(echo "$json" | jq -r '.title')
RATIONALE=$(echo "$json" | jq -r '.rationale')
PLAN=$(echo "$json" | jq -r '.implementation_plan')
BENEFIT=$(echo "$json" | jq -r '.expected_benefit')
TYPE=$(echo "$json" | jq -r '.type')

log "decision: id=$ID tier=$TIER type=$TYPE title=$TITLE"

# Always log the learning (even "none")
echo "$json" | jq -c --arg d "$(date -u +%FT%TZ)" '. + {logged_at:$d, outcome:"reviewed"}' >> "$GROWTH_LOG"

if [[ "$TIER" == "none" ]]; then
  log "no improvement today — done"
  exit 0
fi

# ── GREEN: auto-implement (additive, smoke-gated, git-reverted on failure) ──
if [[ "$TIER" == "green" ]]; then
  log "GREEN tier — dispatching auto-implement job"
  IMPL_PROMPT=$(cat <<IMPL
You are implementing a self-approved GREEN-tier (additive-only) improvement to the agent stack. Work in $AGENT_HOME.

Improvement: $TITLE
Plan: $PLAN
Files to create: $(echo "$json" | jq -c '.files_created')

RULES:
1. ADDITIVE ONLY. Create new files. Do NOT edit any existing script, CLAUDE.md, settings.json, sudoers, or the Charter. If the plan requires editing an existing file, STOP and report "requires-edit, escalating to yellow" instead.
2. After creating the files, run: bash $AGENT_HOME/scripts/smoke-test.sh
3. If smoke test shows "Failed: 0", git add the new files in $REPO_DIR (if they belong in the repo template) AND/OR leave runtime-only files in place, then commit with message "feat(self-growth): $TITLE [auto-applied green-tier]".
4. If smoke test shows any failure, DELETE the files you created (revert) and report "smoke-failed, reverted".
5. Report in 2 sentences what you did + the smoke result.
IMPL
)
  bash "$DISPATCH" --title "Self-growth: $TITLE" --executor self --prompt "$IMPL_PROMPT" >/dev/null 2>&1 || {
    log "dispatch failed"; exit 0;
  }
  # Mark in growth log
  echo "$json" | jq -c --arg d "$(date -u +%FT%TZ)" '. + {logged_at:$d, outcome:"auto-applying-green"}' >> "$GROWTH_LOG"
  "$TG_SEND" send --text "📈 Daily growth — auto-applying (green): $TITLE

$RATIONALE

Expected: $BENEFIT

Running in the background with smoke-test gate. I'll confirm when it lands (or report if it reverts)." >/dev/null 2>&1 || true
  log "GREEN auto-implement dispatched"
  exit 0
fi

# ── YELLOW: propose for one-tap approval ────────────────────────────────────
if [[ "$TIER" == "yellow" ]]; then
  PROP_FILE="$PROPOSAL_DIR/$today-$ID.md"
  {
    echo "# Self-growth proposal: $TITLE"
    echo
    echo "- **ID:** $ID"
    echo "- **Type:** $TYPE (yellow — changes existing behavior, needs approval)"
    echo "- **Rationale:** $RATIONALE"
    echo "- **Expected benefit:** $BENEFIT"
    echo
    echo "## Implementation plan"
    echo "$PLAN"
  } > "$PROP_FILE"
  log "YELLOW proposal staged at $PROP_FILE"

  "$TG_SEND" send --text "📈 Daily growth — proposing (needs your ok): $TITLE

$RATIONALE

Expected: $BENEFIT

This changes existing behavior, so I won't apply it without you. Reply:
  apply $ID   → I implement + test + commit it
  skip $ID    → I drop it and won't re-propose this shape" >/dev/null 2>&1 || true
  log "YELLOW proposal sent"
  exit 0
fi

log "=== done ==="
