#!/usr/bin/env python3
"""Render the approval queue (awaiting_review tasks) as MarkdownV2 for Telegram."""
import json
import os
import re

ACTIVE = os.environ.get("ACTIVE_JSON",
    "{{TENANT_AGENT_HOME}}/tasks/active.json".replace("{{TENANT_AGENT_HOME}}", "/opt/{{TENANT_LINUX_USER}}/agents"))

ESC_CHARS = r'_*()~`>#+=|{}.!-\[\]\\'

def esc(s):
    if s is None:
        return ""
    return re.sub(f"([{re.escape(ESC_CHARS)}])", r"\\\1", str(s))

with open(ACTIVE) as f:
    active = json.load(f)

awaiting = [t for t in active.values() if t.get("state") == "awaiting_review"]
awaiting_external = [t for t in active.values() if t.get("state") == "awaiting_external"]
blocked = [t for t in active.values() if t.get("state") == "blocked"]

lines = [f"*Approval queue* — {len(awaiting)} awaiting your ✅", ""]

if not awaiting and not awaiting_external and not blocked:
    lines = [
        "*Approval queue* — clean",
        "",
        "_Nothing pending\\. The agent has nothing waiting on you\\._",
    ]
else:
    if awaiting:
        lines.append("👀 *Drafts ready for review*")
        for t in sorted(awaiting, key=lambda x: x.get("updated_at", ""), reverse=True)[:15]:
            summary = esc(t.get("summary", "(no summary)"))
            tid = t.get("id", "")
            tid_esc = esc(tid)
            last_msg = ""
            for ev in reversed(t.get("events", [])):
                if ev.get("event") == "state" and ev.get("state") == "awaiting_review":
                    last_msg = esc(ev.get("msg", ""))
                    break
            lines.append(f"  • {summary}")
            if last_msg:
                lines.append(f"    _{last_msg}_")
            lines.append(f"    `{tid_esc}` — reply: `ship {tid}` · `revise {tid} <feedback>` · `hold {tid}`")
        lines.append("")
    if awaiting_external:
        lines.append("⏳ *Waiting on you for input*")
        for t in awaiting_external[:10]:
            lines.append(f"  • {esc(t.get('summary', ''))} `{esc(t.get('id', ''))}`")
        lines.append("")
    if blocked:
        lines.append("🚧 *Blocked*")
        for t in blocked[:10]:
            lines.append(f"  • {esc(t.get('summary', ''))} `{esc(t.get('id', ''))}`")
        lines.append("")

print("\n".join(lines))
