#!/usr/bin/env python3
"""
memory-export.py — SQLite memory vault → Obsidian markdown files
Runs every 5 min via systemd timer. Agent-owned output; never touches inbox/.
"""

import sqlite3
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

VAULT_DB = "{{TENANT_AGENT_HOME}}/memory/vault.db"
VAULT_DIR = Path("{{TENANT_USER_HOME}}/obsidian-vault")
BRAND_SRC = Path("{{TENANT_AGENT_HOME}}/daniel-personal-brand")

TYPE_FOLDER = {
    "fact":         "memories/facts",
    "decision":     "memories/decisions",
    "relationship": "memories/relationships",
    "preference":   "memories/preferences",
    "pattern":      "memories/patterns",
    "commitment":   "memories/commitments",
    "goal":         "memories/goals",
    "context":      "memories/context",
}

def safe_filename(text: str, max_len: int = 60) -> str:
    slug = re.sub(r"[^\w\s-]", "", text.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug[:max_len]

def export_memories():
    conn = sqlite3.connect(VAULT_DB)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("""
        SELECT id, type, text, tags, source, created_at, expires_at,
               confidence, access_count, last_accessed, superseded_by
        FROM memories
        WHERE superseded_by IS NULL
        ORDER BY created_at DESC
    """)
    rows = cur.fetchall()
    conn.close()

    written = 0
    for row in rows:
        mem_type = row["type"] if row["type"] in TYPE_FOLDER else "context"
        folder = VAULT_DIR / TYPE_FOLDER[mem_type]
        folder.mkdir(parents=True, exist_ok=True)

        tags = row["tags"].split() if row["tags"] else []
        slug = safe_filename(row["text"])
        filename = f"{row['id']}-{slug}.md"
        filepath = folder / filename

        created = row["created_at"] or ""
        date_prefix = created[:10] if created else ""

        frontmatter = f"""---
id: {row['id']}
type: {mem_type}
tags: [{', '.join(tags)}]
source: {row['source'] or 'unknown'}
created: {created}
confidence: {row['confidence']}
access_count: {row['access_count']}
last_accessed: {row['last_accessed'] or ''}
expires: {row['expires_at'] or 'never'}
---
"""
        body = f"# {row['text'][:80]}\n\n{row['text']}\n"
        if tags:
            body += f"\n**Tags:** {', '.join(f'#{t}' for t in tags)}\n"
        body += f"\n_Logged: {date_prefix} · Source: {row['source'] or 'unknown'} · Confidence: {row['confidence']}_\n"

        filepath.write_text(frontmatter + "\n" + body)
        written += 1

    return written

def write_daily_summary():
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    daily_dir = VAULT_DIR / "daily"
    daily_dir.mkdir(exist_ok=True)
    summary_file = daily_dir / f"{today}.md"

    conn = sqlite3.connect(VAULT_DB)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("""
        SELECT id, type, text, tags, created_at
        FROM memories
        WHERE date(created_at) = date('now')
          AND superseded_by IS NULL
        ORDER BY created_at DESC
    """)
    rows = cur.fetchall()
    conn.close()

    lines = [f"# Daily memory summary — {today}\n", f"*{len(rows)} memories added today.*\n"]
    for r in rows:
        tags = r["tags"].split() if r["tags"] else []
        tag_str = " · ".join(f"#{t}" for t in tags) if tags else ""
        lines.append(f"- **[{r['type']}]** {r['text'][:120]}{'...' if len(r['text'])>120 else ''}")
        if tag_str:
            lines.append(f"  {tag_str}")

    summary_file.write_text("\n".join(lines) + "\n")

def sync_brand_canon():
    brand_dest = VAULT_DIR / "brand"
    brand_dest.mkdir(exist_ok=True)
    if not BRAND_SRC.exists():
        return 0
    count = 0
    for src_file in BRAND_SRC.glob("*.md"):
        dest = brand_dest / src_file.name
        dest.write_text(src_file.read_text())
        count += 1
    for src_file in BRAND_SRC.glob("*.html"):
        dest = brand_dest / (src_file.stem + ".md")
        # minimal html strip — just copy as-is for now
        dest.write_text(f"<!-- source: {src_file.name} -->\n" + src_file.read_text())
        count += 1
    return count

def write_vault_readme(mem_count: int):
    readme = VAULT_DIR / "README.md"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    readme.write_text(f"""# Daniel Gonell — Personal Brand Memory Vault

Agent-generated. Last export: **{now}**

## Structure

| Folder | Contents |
|---|---|
| `memories/` | All SQLite memory exports ({mem_count} entries) |
| `brand/` | Brand canon files (read-only mirror) |
| `daily/` | Daily summaries of new memories |
| `inbox/` | YOUR notes — agent reads but never writes here |

## Rules
- `memories/` and `brand/` are overwritten every 5 min. Don't edit them here.
- `inbox/` is yours. Drop context notes, the agent picks them up next session.
- SQLite is authoritative. Obsidian is a read-only view.
""")

if __name__ == "__main__":
    mem_count = export_memories()
    write_daily_summary()
    sync_brand_canon()
    write_vault_readme(mem_count)
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] Exported {mem_count} memories → {VAULT_DIR}")
