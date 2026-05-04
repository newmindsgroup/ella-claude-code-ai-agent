#!/usr/bin/env python3
"""Helpers for goal-tracker.sh — render and rebuild logic in one place."""
import json
import os
import re
import sys
import datetime
from collections import OrderedDict


def goals_paths():
    home = os.environ.get("TENANT_AGENT_HOME", "/opt/{{TENANT_LINUX_USER}}/agents")
    goals_dir = os.path.join(home, "goals")
    return (
        goals_dir,
        os.path.join(goals_dir, "ledger.jsonl"),
        os.path.join(goals_dir, "active.json"),
        os.path.join(goals_dir, "archive.json"),
    )


def rebuild():
    goals_dir, ledger, active, archive = goals_paths()
    os.makedirs(goals_dir, exist_ok=True)
    if not os.path.exists(ledger):
        open(ledger, "w").close()
    if not os.path.exists(active):
        with open(active, "w") as f:
            json.dump({}, f)
    if not os.path.exists(archive):
        with open(archive, "w") as f:
            json.dump({}, f)

    state = {}
    with open(ledger) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            gid = ev.get("id")
            if not gid:
                continue
            evt = ev.get("event")
            g = state.setdefault(gid, {
                "id": gid, "summary": "", "target_date": None,
                "metric": None, "target_value": None, "current_value": 0,
                "linked_tasks": [], "linked_memories": [],
                "owner": None, "state": "proposed",
                "created_at": ev.get("ts"), "updated_at": ev.get("ts"),
                "events": [],
            })
            g["events"].append(ev)
            g["updated_at"] = ev.get("ts", g["updated_at"])
            if evt == "create":
                for k in ("summary", "target_date", "metric", "target_value", "owner", "current_value"):
                    if k in ev:
                        g[k] = ev[k]
                g["state"] = ev.get("state", "committed")
            elif evt == "state":
                g["state"] = ev.get("state", g["state"])
            elif evt == "progress":
                if "current_value" in ev:
                    g["current_value"] = ev["current_value"]
            elif evt == "link":
                kind = ev.get("kind", "task")
                key = "linked_tasks" if kind == "task" else "linked_memories"
                lid = ev.get("link_id")
                if lid and lid not in g[key]:
                    g[key].append(lid)
            elif evt == "comment":
                pass

    # Split active vs archive
    now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
    active_state = {}
    for gid, g in state.items():
        if g["state"] in ("achieved", "missed", "deferred", "cancelled"):
            try:
                upd = datetime.datetime.fromisoformat(g["updated_at"].replace("Z", ""))
                if (now - upd).days >= 30:
                    continue
            except (KeyError, ValueError):
                pass
        active_state[gid] = g

    with open(active, "w") as f:
        json.dump(active_state, f, indent=2, sort_keys=True)
    print(f"goals indexed: {len(active_state)} active")


def render():
    _, _, active, _ = goals_paths()
    if not os.path.exists(active):
        print("*Goals* — 0\n\n_No goal tracker initialized yet\\._")
        return

    with open(active) as f:
        goals = json.load(f)

    ESC_CHARS = r'_*()~`>#+=|{}.!-\[\]\\'

    def esc(s):
        if s is None:
            return ""
        return re.sub(f"([{re.escape(ESC_CHARS)}])", r"\\\1", str(s))

    state_emoji = {
        "proposed": "✏️", "committed": "🎯", "in_progress": "🔧",
        "at_risk": "⚠️", "achieved": "✅", "missed": "❌",
        "deferred": "⏭️", "cancelled": "✖️",
    }

    states_order = ["at_risk", "in_progress", "committed", "proposed", "achieved", "missed", "deferred", "cancelled"]
    grouped = {}
    for gid, g in goals.items():
        grouped.setdefault(g.get("state", "proposed"), []).append(g)

    open_count = sum(len(grouped.get(s, [])) for s in ["at_risk", "in_progress", "committed", "proposed"])

    if not goals:
        print("*Goals* — 0\n\n_No goals tracked yet\\. Tell me what you want to achieve\\._")
        return

    lines = [f"*Goals* — {open_count} open"]

    for st in states_order:
        items = grouped.get(st, [])
        if not items:
            continue
        e = state_emoji.get(st, "•")
        label = st.replace("_", " ").title()
        lines.append("")
        lines.append(f"{e} *{esc(label)}* — {len(items)}")
        for g in sorted(items, key=lambda x: x.get("target_date") or "", reverse=False)[:8]:
            summary = esc(g.get("summary", "(no summary)"))
            gid = esc(g.get("id", ""))
            parts = [f"• {summary}"]
            cur = g.get("current_value")
            tgt = g.get("target_value")
            if cur is not None and tgt is not None:
                pct = int(round(100 * float(cur) / float(tgt))) if tgt else 0
                parts.append(f"_{cur}/{tgt} ({pct}%)_")
            target_date = g.get("target_date")
            if target_date:
                parts.append(f"_due {esc(target_date)}_")
            parts.append(f"`{gid}`")
            lines.append("  " + " · ".join(parts))

    print("\n".join(lines))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "rebuild":
        rebuild()
    elif cmd == "render":
        render()
    else:
        print(__doc__)
