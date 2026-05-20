#!/usr/bin/env python3
"""Knowledge graph queries over the memory vault.

Treats `relationship` and `commitment` memories as nodes/edges.
Surfaces what we know about a person, company, or topic.
"""
import json
import os
import re
import shutil
import subprocess
import sys


def agent_home():
    return os.environ.get("TENANT_AGENT_HOME", "/opt/{{TENANT_LINUX_USER}}/agents")


def vault_path():
    return os.path.join(agent_home(), "memory", "index", "recent.json")


def query_graph_nodes(needle, limit=6):
    """Traverse the unified Graphify knowledge graph for nodes related to the
    needle — bridges the memory-vault /who view with the code+concept graph."""
    merged = os.path.join(agent_home(), "graphify-out", "merged-graph.json")
    if not os.path.isfile(merged):
        return []
    graphify = shutil.which("graphify") or os.path.expanduser("~/.local/bin/graphify")
    try:
        out = subprocess.run([graphify, "query", needle, "--graph", merged, "--budget", "500"],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return []
    seen, nodes = set(), []
    for ln in out.splitlines():
        m = re.match(r"^NODE\s+(.*?)\s*\[src=(.*?)\s+loc=", ln.strip())
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            nodes.append((m.group(1), m.group(2)))
        if len(nodes) >= limit:
            break
    return nodes


ESC_CHARS = r'_*()~`>#+=|{}.!-\[\]\\'

def esc(s):
    if s is None:
        return ""
    return re.sub(f"([{re.escape(ESC_CHARS)}])", r"\\\1", str(s))


def load_memories():
    path = vault_path()
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f)


def query_who(needle):
    """Render: who do I know related to <needle>? Walks relationship + commitment + context memories."""
    needle_lc = needle.lower().strip()
    memories = load_memories()

    matches = {"relationship": [], "commitment": [], "context": [], "fact": [], "preference": []}
    for m in memories:
        text = (m.get("text", "") + " " + " ".join(m.get("tags", []) or [])).lower()
        if needle_lc in text:
            t = m.get("type", "fact")
            if t in matches:
                matches[t].append(m)

    total = sum(len(v) for v in matches.values())
    gnodes = query_graph_nodes(needle)  # unified Graphify graph traversal

    lines = [f"*Knowledge graph — {esc(needle)}*", ""]
    if total == 0 and not gnodes:
        lines.append(f"_Nothing in memory or the graph about_ `{esc(needle)}`_\\. As I learn things, this view fills out\\._")
        print("\n".join(lines))
        return

    if total:
        lines.append(f"Found {total} memories\\.")
        lines.append("")

    section_emoji = {
        "relationship": "👤",
        "commitment": "🤝",
        "context": "📁",
        "fact": "📎",
        "preference": "❤️",
    }
    section_label = {
        "relationship": "People & companies",
        "commitment": "Promises",
        "context": "Context",
        "fact": "Facts",
        "preference": "Preferences",
    }

    order = ["relationship", "commitment", "fact", "context", "preference"]
    for t in order:
        items = matches[t]
        if not items:
            continue
        e = section_emoji.get(t, "•")
        label = section_label.get(t, t.title())
        lines.append(f"{e} *{esc(label)}* — {len(items)}")
        # newest first
        items.sort(key=lambda m: m.get("created_at", ""), reverse=True)
        for m in items[:8]:
            text = m.get("text", "")
            if len(text) > 180:
                text = text[:177] + "..."
            mid = esc(m.get("id", ""))
            ts = esc((m.get("created_at") or "")[:10])
            lines.append(f"  • {esc(text)} _\\({ts}\\)_ `{mid}`")
        lines.append("")

    if gnodes:
        lines.append("🕸️ *Graph connections*")
        for label, src in gnodes:
            lines.append(f"  • {esc(label)} _\\({esc(src)}\\)_")
        lines.append("")

    print("\n".join(lines))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "who" and len(sys.argv) > 2:
        query_who(" ".join(sys.argv[2:]))
    else:
        print(__doc__)
