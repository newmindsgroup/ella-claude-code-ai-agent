#!/usr/bin/env python3
"""Render active.json as MarkdownV2 for Telegram."""
import json
import re

ACTIVE = "{{TENANT_AGENT_HOME}}/tasks/active.json"
ESC_CHARS = r'_*()~`>#+=|{}.!-\[\]\\'

def esc(s):
    if s is None:
        return ""
    s = str(s)
    return re.sub(f"([{re.escape(ESC_CHARS)}])", r"\\\1", s)

with open(ACTIVE) as f:
    active = json.load(f)

states_order = [
    "awaiting_external", "awaiting_review", "in_progress",
    "blocked", "stale", "committed", "proposed", "done", "cancelled",
]
state_emoji = {
    "proposed": "✏️", "committed": "\U0001f4cc", "in_progress": "\U0001f527",
    "awaiting_review": "\U0001f440", "awaiting_external": "⏳", "blocked": "\U0001f6a7",
    "stale": "\U0001f550", "done": "✅", "cancelled": "✖️",
}
state_label = {
    "proposed": "Proposed", "committed": "Committed", "in_progress": "Working on",
    "awaiting_review": "Awaiting your review", "awaiting_external": "Waiting on you",
    "blocked": "Blocked", "stale": "Stale", "done": "Done", "cancelled": "Cancelled",
}

groups = {}
for tid, t in active.items():
    groups.setdefault(t.get("state", "proposed"), []).append(t)

total_open = sum(
    len(groups.get(s, []))
    for s in states_order
    if s not in ("done", "cancelled")
)

lines = [f"*Active tasks* — {total_open} open", ""]

for st in states_order:
    items = groups.get(st, [])
    if not items:
        continue
    emoji = state_emoji.get(st, "•")
    label = state_label.get(st, st)
    lines.append(f"{emoji} *{esc(label)}* — {len(items)}")
    for t in sorted(items, key=lambda x: x.get("updated_at", ""), reverse=True)[:10]:
        summary = esc(t.get("summary", "(no summary)"))
        tid = esc(t.get("id", ""))
        parts = [f"• {summary}"]
        if t.get("deadline"):
            parts.append(f"_due {esc(t['deadline'])}_")
        parts.append(f"`{tid}`")
        lines.append("  " + " · ".join(parts))
    lines.append("")

if total_open == 0:
    lines = [
        "*Active tasks* — 0 open",
        "",
        "_Nothing on the board\\. Tell me what to track\\._",
    ]

print("\n".join(lines))
