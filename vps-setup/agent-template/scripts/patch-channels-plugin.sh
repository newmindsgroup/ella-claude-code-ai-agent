#!/usr/bin/env bash
# patch-channels-plugin.sh — apply local patches to the vendored
# claude-plugins-official/telegram server.ts. Multi-pass, idempotent.
#
# Each pass has its own sentinel string. A pass is a no-op if its sentinel
# is already in the file. Passes are applied in order; later passes assume
# earlier passes have already run (use anchors that exist after the prior
# pass completes).
#
# CURRENT PASSES:
#   v2.22.2 — deploy: callback_data routing (Ship/Cancel buttons on /deploy)
#   v2.24.0 — draft:  callback_data routing (Ship/Hold/Revise on every draft)
#   v2.27.2 — prop:   callback_data routing (Run/Skip on morning-brief proposed moves)
#   v2.27.3 — forward: surface forward_origin metadata so agent detects forwards
#   v2.27.4 — email:  callback_data routing (Reply/Archive/Snooze on /inbox triage)
#   v2.62.0 — parity: tee INBOUND Telegram user text into the dashboard chat
#   v2.78.0 — reply:  tee OUTBOUND agent replies into the dashboard chat
#
# WHY THIS EXISTS:
#   The upstream channels plugin's bot.on('callback_query:data', ...) handler
#   ONLY recognizes ^perm:(allow|deny|more):...$ patterns. Anything else gets
#   answerCallbackQuery()'d silently and dropped. To route arbitrary callbacks
#   (deploy: for /deploy, draft: for newsletter approvals, etc.), we patch
#   sibling handlers in BEFORE the perm: check, all routing through the
#   standard notifications/claude/channel MCP path so the agent receives them
#   as synthetic chat messages.
#
# RUN ON EVERY claude-agent.service RESTART (wired via ExecStartPre in v2.23.0).
# This makes the patch self-healing if upstream plugin updates wipe the cache.
#
# RE-APPLY MANUALLY (e.g. after plugin version bump 0.0.6 → 0.0.7+):
#   1. Update PLUGIN_DIR if path changed
#   2. Run this script
#   3. systemctl restart claude-agent.service
#
# v2.23.0+ backlog: fork the plugin into our repo with patches baked in.

set -uo pipefail

PLUGIN_DIR="${PLUGIN_DIR:-{{TENANT_USER_HOME}}/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6}"
PLUGIN="$PLUGIN_DIR/server.ts"

[[ ! -f "$PLUGIN" ]] && { echo "FATAL: $PLUGIN not found — check PLUGIN_DIR" >&2; exit 2; }

# -----------------------------------------------------------------------------
# PASS 1 — v2.22.2 deploy: callback_data routing
# -----------------------------------------------------------------------------
SENTINEL_DEPLOY="v2.22.2: deploy command callbacks"

if grep -q "$SENTINEL_DEPLOY" "$PLUGIN"; then
  echo "  pass 1 (deploy:) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass1-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_DEPLOY" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
needle = "  const data = ctx.callbackQuery.data\n  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)"
new = f"""  const data = ctx.callbackQuery.data

  // {SENTINEL} — route ship/cancel taps through the standard channel
  // notification path so the agent receives them as if typed. Pattern:
  // deploy:(ship|cancel):v<MAJ>.<MIN>.<PATCH>
  // Must precede the perm: handler — they're disjoint patterns.
  const dm = /^deploy:(ship|cancel):(v\\d+\\.\\d+\\.\\d+)$/.exec(data)
  if (dm) {{
    const accessD = loadAccess()
    const senderIdD = String(ctx.from.id)
    if (!accessD.allowFrom.includes(senderIdD)) {{
      await ctx.answerCallbackQuery({{ text: 'Not authorized.' }}).catch(() => {{}})
      return
    }}
    const [, dAction, dVersion] = dm
    const dMsg = ctx.callbackQuery.message
    void mcp.notification({{
      method: 'notifications/claude/channel',
      params: {{
        content: `${{dAction}} ${{dVersion}}`,
        meta: {{
          chat_id: String(ctx.chat?.id ?? ''),
          ...(dMsg && 'message_id' in dMsg ? {{ message_id: String(dMsg.message_id) }} : {{}}),
          user: ctx.from.username ?? String(ctx.from.id),
          user_id: String(ctx.from.id),
          ts: new Date().toISOString(),
          source: 'callback_query:deploy',
        }},
      }},
    }}).catch(() => {{}})
    const dLabel = dAction === 'ship' ? '✅ Ship requested' : '🛑 Cancel requested'
    await ctx.answerCallbackQuery({{ text: dLabel }}).catch(() => {{}})
    if (dMsg && 'text' in dMsg && dMsg.text) {{
      await ctx.editMessageText(`${{dMsg.text}}\\n\\n${{dLabel}}: ${{dVersion}}`).catch(() => {{}})
    }}
    return
  }}

  const m = /^perm:(allow|deny|more):([a-km-z]{{5}})$/.exec(data)"""
if needle not in src:
    print(f"FATAL: pass-1 anchor not found in {PLUGIN}"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
open(PLUGIN, "w").write(patched)
print(f"  pass 1 (deploy:) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 2 — v2.24.0 draft: callback_data routing
# -----------------------------------------------------------------------------
# Replaces the broken tg://msg URL-button pattern from CLAUDE.md's "Approval
# flow" section. Pattern: draft:(ship|hold|revise):t-YYYYMMDD-XXXX
# Anchor: the line `const m = /^perm:...` (immediately after pass 1's deploy
# handler closing `}` if pass 1 ran; immediately after `const data = ...` if
# pass 1 was a no-op for some reason — but pass 1 must succeed first).
SENTINEL_DRAFT="v2.24.0: draft approval callbacks"

if grep -q "$SENTINEL_DRAFT" "$PLUGIN"; then
  echo "  pass 2 (draft:) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass2-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_DRAFT" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
needle = "\n  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)"
new = f"""

  // {SENTINEL} — route ship/hold/revise taps on draft approvals through the
  // standard channel notification path. Replaces the broken tg://msg URL-button
  // pattern from the original CLAUDE.md "Approval flow" section. Pattern:
  // draft:(ship|hold|revise):t-YYYYMMDD-XXXX
  const drm = /^draft:(ship|hold|revise):(t-[0-9]{{8}}-[a-f0-9]{{4}})$/.exec(data)
  if (drm) {{
    const accessDR = loadAccess()
    const senderIdDR = String(ctx.from.id)
    if (!accessDR.allowFrom.includes(senderIdDR)) {{
      await ctx.answerCallbackQuery({{ text: 'Not authorized.' }}).catch(() => {{}})
      return
    }}
    const [, drAction, drTaskId] = drm
    const drMsg = ctx.callbackQuery.message
    void mcp.notification({{
      method: 'notifications/claude/channel',
      params: {{
        content: `${{drAction}} ${{drTaskId}}`,
        meta: {{
          chat_id: String(ctx.chat?.id ?? ''),
          ...(drMsg && 'message_id' in drMsg ? {{ message_id: String(drMsg.message_id) }} : {{}}),
          user: ctx.from.username ?? String(ctx.from.id),
          user_id: String(ctx.from.id),
          ts: new Date().toISOString(),
          source: 'callback_query:draft',
        }},
      }},
    }}).catch(() => {{}})
    const drLabel = drAction === 'ship' ? '✅ Shipped'
                  : drAction === 'hold' ? '⏸️ On hold'
                  : '✏️ Revising'
    await ctx.answerCallbackQuery({{ text: drLabel }}).catch(() => {{}})
    if (drMsg && 'text' in drMsg && drMsg.text) {{
      await ctx.editMessageText(`${{drMsg.text}}\\n\\n${{drLabel}}: ${{drTaskId}}`).catch(() => {{}})
    }}
    return
  }}

  const m = /^perm:(allow|deny|more):([a-km-z]{{5}})$/.exec(data)"""
if needle not in src:
    print(f"FATAL: pass-2 anchor not found in {PLUGIN} — pass 1 may not have run cleanly"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-2 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 2 (draft:) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 3 — v2.27.2 prop: callback_data routing (Run/Skip on Proposed Moves)
# -----------------------------------------------------------------------------
# Pattern: prop:(run|skip):p-YYYYMMDD-aaaa
# Anchor: the `const m = /^perm:...` line (immediately after pass 2's draft
# handler). Pass 1 + pass 2 must have run first.
SENTINEL_PROP="v2.27.2: proposal approval callbacks"

if grep -q "$SENTINEL_PROP" "$PLUGIN"; then
  echo "  pass 3 (prop:) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass3-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_PROP" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
needle = "\n  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)"
new = f"""

  // {SENTINEL} — route Run/Skip taps on morning-brief proposals through the
  // standard channel notification path. Pattern:
  // prop:(run|skip):p-YYYYMMDD-aaaa
  // Agent reads proposals/<DATE>.json to look up the proposal by id and
  // dispatches to the named executor sub-agent. Handler in CLAUDE.md.
  const ppm = /^prop:(run|skip):(p-[0-9]{{8}}-[a-z]{{4}})$/.exec(data)
  if (ppm) {{
    const accessPP = loadAccess()
    const senderIdPP = String(ctx.from.id)
    if (!accessPP.allowFrom.includes(senderIdPP)) {{
      await ctx.answerCallbackQuery({{ text: 'Not authorized.' }}).catch(() => {{}})
      return
    }}
    const [, ppAction, ppPropId] = ppm
    const ppMsg = ctx.callbackQuery.message
    void mcp.notification({{
      method: 'notifications/claude/channel',
      params: {{
        content: `${{ppAction}} ${{ppPropId}}`,
        meta: {{
          chat_id: String(ctx.chat?.id ?? ''),
          ...(ppMsg && 'message_id' in ppMsg ? {{ message_id: String(ppMsg.message_id) }} : {{}}),
          user: ctx.from.username ?? String(ctx.from.id),
          user_id: String(ctx.from.id),
          ts: new Date().toISOString(),
          source: 'callback_query:prop',
        }},
      }},
    }}).catch(() => {{}})
    const ppLabel = ppAction === 'run' ? '✅ Approved — running'
                  : '⏭️ Skipped'
    await ctx.answerCallbackQuery({{ text: ppLabel }}).catch(() => {{}})
    return
  }}

  const m = /^perm:(allow|deny|more):([a-km-z]{{5}})$/.exec(data)"""
if needle not in src:
    print(f"FATAL: pass-3 anchor not found in {PLUGIN} — pass 2 may not have run cleanly"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-3 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 3 (prop:) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 5 — v2.27.4 email: callback_data routing (Reply/Archive/Snooze)
# -----------------------------------------------------------------------------
# Pattern: email:(reply|archive|snooze):<gmail-thread-id>
# Gmail thread IDs are hex (~16 chars). Anchor: same as other callback passes.
SENTINEL_EMAIL="v2.27.4: email triage callbacks"

if grep -q "$SENTINEL_EMAIL" "$PLUGIN"; then
  echo "  pass 5 (email:) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass5-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_EMAIL" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
needle = "\n  const m = /^perm:(allow|deny|more):([a-km-z]{5})$/.exec(data)"
new = f"""

  // {SENTINEL} — route Reply/Archive/Snooze taps on /inbox triage cards
  // through the standard channel notification path. Pattern:
  // email:(reply|archive|snooze):<gmail-thread-id-hex>
  // Agent uses the Gmail MCP to perform the action then confirms in chat.
  const epm = /^email:(reply|archive|snooze):([a-f0-9]{{8,32}})$/.exec(data)
  if (epm) {{
    const accessEP = loadAccess()
    const senderIdEP = String(ctx.from.id)
    if (!accessEP.allowFrom.includes(senderIdEP)) {{
      await ctx.answerCallbackQuery({{ text: 'Not authorized.' }}).catch(() => {{}})
      return
    }}
    const [, epAction, epThread] = epm
    const epMsg = ctx.callbackQuery.message
    void mcp.notification({{
      method: 'notifications/claude/channel',
      params: {{
        content: `${{epAction}} email ${{epThread}}`,
        meta: {{
          chat_id: String(ctx.chat?.id ?? ''),
          ...(epMsg && 'message_id' in epMsg ? {{ message_id: String(epMsg.message_id) }} : {{}}),
          user: ctx.from.username ?? String(ctx.from.id),
          user_id: String(ctx.from.id),
          ts: new Date().toISOString(),
          source: 'callback_query:email',
        }},
      }},
    }}).catch(() => {{}})
    const epLabel = epAction === 'reply'   ? '📎 Drafting reply'
                  : epAction === 'archive' ? '🗃 Archiving'
                  : '⏰ Snoozing 24h'
    await ctx.answerCallbackQuery({{ text: epLabel }}).catch(() => {{}})
    return
  }}

  const m = /^perm:(allow|deny|more):([a-km-z]{{5}})$/.exec(data)"""
if needle not in src:
    print(f"FATAL: pass-5 anchor not found in {PLUGIN}"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-5 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 5 (email:) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 4 — v2.27.3 forward_origin metadata
# -----------------------------------------------------------------------------
# Surfaces ctx.message.forward_origin into the meta block so the agent can
# detect that an inbound message was forwarded from somewhere else and offer
# to save it to memory with proper attribution.
#
# Anchor: the existing meta block in handleInbound that builds chat_id, etc.
# We splice forward fields into the same object.
SENTINEL_FWD="v2.27.3: forward_origin metadata"

if grep -q "$SENTINEL_FWD" "$PLUGIN"; then
  echo "  pass 4 (forward) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass4-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_FWD" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
# Anchor on the user_id meta line — present since v0 and stable.
needle = "        user_id: String(from.id),\n        ts: new Date((ctx.message?.date ?? 0) * 1000).toISOString(),"
new = f"""        user_id: String(from.id),
        ts: new Date((ctx.message?.date ?? 0) * 1000).toISOString(),
        // {SENTINEL} — surface forwarded-message provenance so the agent
        // can recognize forwards and offer to save them as memory.
        ...((() => {{
          const fo = (ctx.message as any)?.forward_origin
          if (!fo) return {{}}
          let label = ''
          if (fo.type === 'user') {{
            const u = fo.sender_user
            label = u?.username ? '@' + u.username : (u?.first_name ?? 'unknown user')
          }} else if (fo.type === 'hidden_user') {{
            label = fo.sender_user_name ?? 'hidden user'
          }} else if (fo.type === 'chat') {{
            label = fo.sender_chat?.title ?? fo.sender_chat?.username ?? 'chat'
          }} else if (fo.type === 'channel') {{
            label = fo.chat?.title ?? fo.chat?.username ?? 'channel'
          }}
          return {{
            forward_origin_type: fo.type,
            forward_origin_label: label,
            forward_origin_date: new Date((fo.date ?? 0) * 1000).toISOString(),
          }}
        }})()),"""
if needle not in src:
    print(f"FATAL: pass-4 anchor not found in {PLUGIN}"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-4 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 4 (forward) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 6 — v2.62.0 chat parity: tee inbound Telegram messages → unified store
# -----------------------------------------------------------------------------
# Captures each inbound Telegram user message and fires it (fire-and-forget) at
# the dashboard-chat FastAPI /api/chat/ingest endpoint, which appends it to the
# shared conversation.db. Telegram→Dashboard half of chat parity. Reuses PASS
# 4's proven handleInbound meta-block anchor + the same side-effecting-IIFE
# shape (returns {} — adds no field, fires the capture as a side effect).
SENTINEL_PARITY="v2.62.0: chat parity ingest tee"

if grep -q "$SENTINEL_PARITY" "$PLUGIN"; then
  echo "  pass 6 (parity) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass6-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_PARITY" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
needle = "        ts: new Date((ctx.message?.date ?? 0) * 1000).toISOString(),"
new = f"""        ts: new Date((ctx.message?.date ?? 0) * 1000).toISOString(),
        // {SENTINEL} — mirror inbound Telegram text into the dashboard's
        // unified conversation store so the Mission Control chat shows it.
        ...((() => {{
          try {{
            const t = ((ctx.message as any)?.text ?? '').trim()
            if (t) {{
              fetch('http://127.0.0.1:8001/api/chat/ingest', {{
                method: 'POST',
                headers: {{ 'Content-Type': 'application/json' }},
                body: JSON.stringify({{ role: 'user', source: 'telegram', text: t }}),
              }}).catch(() => {{}})
            }}
          }} catch (e) {{ /* never block delivery on a logging hiccup */ }}
          return {{}}
        }})()),"""
if needle not in src:
    print(f"FATAL: pass-6 anchor not found in {PLUGIN}"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-6 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 6 (parity) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# PASS 7 — v2.78.0 outbound reply ingest tee
#   Mirror the agent's OUTBOUND Telegram replies (the `reply` MCP tool) into
#   the dashboard's unified conversation store, completing 100% bidirectional
#   Telegram <-> Mission Control parity. PASS 6 handles inbound (user) text;
#   PASS 7 handles outbound (agent) text.
#
#   No loop with PASS 6 (which tees role=user from ctx.message) and no dupe
#   with the dashboard-chat path (which returns over SSE and never calls the
#   `reply` tool — it runs claude with the _DASHBOARD_CHAT_GUARD). Only the
#   conversational `reply` is captured; progress edit_message edits are not.
# -----------------------------------------------------------------------------
SENTINEL_REPLY="v2.78.0: outbound reply ingest tee"

if grep -q "$SENTINEL_REPLY" "$PLUGIN"; then
  echo "  pass 7 (reply tee) already applied — no-op"
else
  cp "$PLUGIN" "$PLUGIN.bak-pass7-$(date -u +%Y%m%dT%H%M%SZ)"
  PLUGIN_TARGET="$PLUGIN" SENTINEL_TARGET="$SENTINEL_REPLY" python3 <<'PY'
import os
PLUGIN = os.environ["PLUGIN_TARGET"]
SENTINEL = os.environ["SENTINEL_TARGET"]
src = open(PLUGIN).read()
# Anchor on the first two statements of the `reply` tool handler. `text` is
# already in scope after the second line; we inject the tee right after it.
needle = (
    "        const chat_id = args.chat_id as string\n"
    "        const text = args.text as string\n"
)
new = (
    "        const chat_id = args.chat_id as string\n"
    "        const text = args.text as string\n"
    f"        // {SENTINEL} — mirror outbound agent reply into the dashboard's\n"
    "        // unified conversation store so the Mission Control chat shows it.\n"
    "        try {\n"
    "          const __rt = (text ?? '').toString().trim()\n"
    "          if (__rt) {\n"
    "            fetch('http://127.0.0.1:8001/api/chat/ingest', {\n"
    "              method: 'POST',\n"
    "              headers: { 'Content-Type': 'application/json' },\n"
    "              body: JSON.stringify({ role: 'agent', source: 'telegram', text: __rt }),\n"
    "            }).catch(() => {})\n"
    "          }\n"
    "        } catch (e) { /* never block delivery on a logging hiccup */ }\n"
)
if needle not in src:
    print(f"FATAL: pass-7 anchor not found in {PLUGIN}"); raise SystemExit(2)
patched = src.replace(needle, new, 1)
if patched == src:
    print(f"FATAL: pass-7 replacement was a no-op"); raise SystemExit(2)
open(PLUGIN, "w").write(patched)
print(f"  pass 7 (reply tee) applied ({len(patched)-len(src)} bytes added)")
PY
fi

# -----------------------------------------------------------------------------
# Verify all expected handlers + ts compiles
# -----------------------------------------------------------------------------
echo ""
echo "=== verify ==="
for s in "$SENTINEL_DEPLOY" "$SENTINEL_DRAFT" "$SENTINEL_PROP" "$SENTINEL_FWD" "$SENTINEL_EMAIL" "$SENTINEL_PARITY" "$SENTINEL_REPLY"; do
  if grep -q "$s" "$PLUGIN"; then
    echo "  ✓ $s"
  else
    echo "  ✗ MISSING: $s"
    exit 1
  fi
done
if grep -q 'perm:(allow|deny|more)' "$PLUGIN"; then
  echo "  ✓ perm: handler intact"
else
  echo "  ✗ perm: handler MISSING — patch corrupted"
  exit 1
fi

echo ""
echo "=== ts syntax ==="
if command -v bun >/dev/null 2>&1; then
  bun build "$PLUGIN" --target=bun --outfile /tmp/server-test-$$.js >/dev/null 2>&1 && \
    echo "  ✓ ts compiles" || { echo "  ✗ ts BROKEN — restore from .bak-* and investigate"; exit 1; }
  rm -f /tmp/server-test-$$.js
else
  echo "  (bun not on PATH — skipping syntax check)"
fi

echo ""
echo "Next: systemctl restart claude-agent.service  (picks up the new server.ts)"
