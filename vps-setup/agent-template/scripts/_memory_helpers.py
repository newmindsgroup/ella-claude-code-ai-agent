#!/usr/bin/env python3
"""Helpers for memory-vault.sh — keeps complex Python out of the bash heredoc."""
import json
import os
import re
import sys
from collections import defaultdict


def vault_paths():
    mem_dir = os.environ.get("MEM_DIR")
    if not mem_dir:
        sys.exit("MEM_DIR env not set")
    return mem_dir, os.path.join(mem_dir, "vault.jsonl"), os.path.join(mem_dir, "index")


def rebuild():
    mem_dir, vault, idx_dir = vault_paths()
    os.makedirs(idx_dir, exist_ok=True)

    by_type = defaultdict(list)
    by_tag = defaultdict(list)
    by_id = {}
    by_recent = []
    forgotten = set()

    if os.path.exists(vault):
        with open(vault) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                evt = ev.get("event")
                mid = ev.get("id")
                if evt == "forget":
                    forgotten.add(mid)
                    continue
                if evt == "add":
                    by_id[mid] = ev
                    by_type[ev.get("type", "fact")].append(mid)
                    for t in ev.get("tags", []) or []:
                        by_tag[t].append(mid)
                    by_recent.append(mid)

    for mid in forgotten:
        by_id.pop(mid, None)
        for k in by_type:
            by_type[k] = [m for m in by_type[k] if m != mid]
        for k in by_tag:
            by_tag[k] = [m for m in by_tag[k] if m != mid]
        by_recent = [m for m in by_recent if m != mid]

    by_recent.sort(key=lambda m: by_id.get(m, {}).get("created_at", ""), reverse=True)
    recent_full = [by_id[m] for m in by_recent[:200] if m in by_id]

    with open(os.path.join(idx_dir, "by-type.json"), "w") as f:
        json.dump(dict(by_type), f, indent=2)
    with open(os.path.join(idx_dir, "by-tag.json"), "w") as f:
        json.dump(dict(by_tag), f, indent=2)
    with open(os.path.join(idx_dir, "by-id.json"), "w") as f:
        json.dump(by_id, f, indent=2)
    with open(os.path.join(idx_dir, "recent.json"), "w") as f:
        json.dump(recent_full, f, indent=2)

    print(f"indexed: {len(by_id)} memories, {len(forgotten)} forgotten")


def recall():
    mem_dir, _, idx_dir = vault_paths()
    type_ = os.environ.get("MV_TYPE", "")
    tags = [t.strip() for t in os.environ.get("MV_TAGS", "").split(",") if t.strip()]
    query = os.environ.get("MV_QUERY", "").lower()
    since = os.environ.get("MV_SINCE", "")
    limit = int(os.environ.get("MV_LIMIT", "20"))

    with open(os.path.join(idx_dir, "recent.json")) as f:
        mems = json.load(f)

    out = []
    for m in mems:
        if type_ and m.get("type") != type_:
            continue
        if tags and not any(t in (m.get("tags") or []) for t in tags):
            continue
        if since and m.get("created_at", "") < since:
            continue
        if query:
            haystack = (m.get("text", "").lower() + " " + " ".join(m.get("tags", []) or [])).lower()
            if query not in haystack:
                continue
        out.append(m)
        if len(out) >= limit:
            break
    print(json.dumps(out, indent=2))


def summarize():
    mem_dir, _, idx_dir = vault_paths()
    type_ = os.environ.get("MV_TYPE", "")
    tags = [t.strip() for t in os.environ.get("MV_TAGS", "").split(",") if t.strip()]
    limit = int(os.environ.get("MV_LIMIT", "20"))

    with open(os.path.join(idx_dir, "recent.json")) as f:
        mems = json.load(f)

    ESC_CHARS = r'_*()~`>#+=|{}.!-\[\]\\'

    def esc(s):
        if s is None:
            return ""
        return re.sub(f"([{re.escape(ESC_CHARS)}])", r"\\\1", str(s))

    by_type = {}
    total = 0
    for m in mems:
        if type_ and m.get("type") != type_:
            continue
        if tags and not any(t in (m.get("tags") or []) for t in tags):
            continue
        by_type.setdefault(m.get("type", "other"), []).append(m)
        total += 1
        if total >= limit:
            break

    emoji = {
        "fact": "\U0001f4ce", "decision": "✓", "relationship": "\U0001f464",
        "preference": "❤️", "pattern": "\U0001f501", "commitment": "\U0001f91d",
        "goal": "\U0001f3af", "context": "\U0001f4c1", "other": "•",
    }

    lines = [f"*Memories* — {total}", ""]
    for t, items in by_type.items():
        e = emoji.get(t, "•")
        lines.append(f"{e} *{esc(t.title())}* — {len(items)}")
        for m in items[:10]:
            text = m.get("text", "")
            if len(text) > 130:
                text = text[:127] + "..."
            lines.append(f"  • {esc(text)} `{esc(m.get('id', ''))}`")
        lines.append("")

    if total == 0:
        lines = [
            "*Memories* — 0",
            "",
            "_Nothing in the vault yet\\. Tell me to remember something\\._",
        ]

    print("\n".join(lines))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "rebuild":
        rebuild()
    elif cmd == "recall":
        recall()
    elif cmd == "summarize":
        summarize()
    else:
        print(__doc__)
