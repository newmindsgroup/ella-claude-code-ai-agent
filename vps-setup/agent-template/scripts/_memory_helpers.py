#!/usr/bin/env python3
"""Helpers for memory-vault.sh — persistent second brain.

Architecture:
  vault.jsonl  — append-only event log (source of truth)
  vault.db     — SQLite read model with FTS5 for hybrid search (rebuilt from JSONL)
  index/       — legacy JSON indexes kept for backward compatibility

Events in vault.jsonl: add | forget | access
"""
import json
import os
import re
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timezone

try:
    import sqlite_vec
    HAVE_VEC = True
except ImportError:
    HAVE_VEC = False


def vault_paths():
    mem_dir = os.environ.get("MEM_DIR")
    if not mem_dir:
        sys.exit("MEM_DIR env not set")
    vault = os.path.join(mem_dir, "vault.jsonl")
    idx_dir = os.path.join(mem_dir, "index")
    db_path = os.path.join(mem_dir, "vault.db")
    return mem_dir, vault, idx_dir, db_path


def open_db(db_path):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")

    if HAVE_VEC:
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)

    conn.execute("""
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            type TEXT,
            text TEXT,
            tags TEXT,
            source TEXT,
            created_at TEXT,
            expires_at TEXT,
            confidence REAL DEFAULT 0.9,
            access_count INTEGER DEFAULT 0,
            last_accessed TEXT,
            supersedes TEXT,
            superseded_by TEXT,
            valid_until TEXT
        )
    """)
    # Add temporal columns to existing DBs that predate this schema
    for col, defval in [("supersedes", "NULL"), ("superseded_by", "NULL"), ("valid_until", "NULL")]:
        try:
            conn.execute(f"ALTER TABLE memories ADD COLUMN {col} TEXT DEFAULT {defval}")
        except Exception:
            pass
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            id UNINDEXED,
            text,
            tags,
            content=memories,
            content_rowid=rowid
        )
    """)
    conn.execute("""
        CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            INSERT INTO memories_fts(rowid, id, text, tags)
            VALUES (new.rowid, new.id, new.text, new.tags);
        END
    """)
    conn.execute("""
        CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, id, text, tags)
            VALUES ('delete', old.rowid, old.id, old.text, old.tags);
        END
    """)
    conn.execute("""
        CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            INSERT INTO memories_fts(memories_fts, rowid, id, text, tags)
            VALUES ('delete', old.rowid, old.id, old.text, old.tags);
            INSERT INTO memories_fts(rowid, id, text, tags)
            VALUES (new.rowid, new.id, new.text, new.tags);
        END
    """)

    if HAVE_VEC:
        conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_vec USING vec0(
                embedding float[384]
            )
        """)

    conn.commit()
    return conn


def _load_emb_cache(mem_dir: str) -> dict:
    path = os.path.join(mem_dir, "embeddings.json")
    if os.path.exists(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def _save_emb_cache(mem_dir: str, cache: dict) -> None:
    path = os.path.join(mem_dir, "embeddings.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, path)


def rebuild():
    mem_dir, vault, idx_dir, db_path = vault_paths()
    os.makedirs(idx_dir, exist_ok=True)

    # Parse vault.jsonl
    by_type = defaultdict(list)
    by_tag = defaultdict(list)
    by_id = {}
    by_recent = []
    forgotten = set()
    access_counts = defaultdict(int)
    last_accessed = {}

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
                elif evt == "access":
                    if mid:
                        access_counts[mid] += 1
                        ts = ev.get("ts", "")
                        if ts > last_accessed.get(mid, ""):
                            last_accessed[mid] = ts
                elif evt == "add":
                    by_id[mid] = ev
                    by_type[ev.get("type", "fact")].append(mid)
                    for t in ev.get("tags", []) or []:
                        by_tag[t].append(mid)
                    by_recent.append(mid)
                elif evt == "superseded_by":
                    # Mark the superseded memory with who replaced it
                    if mid in by_id:
                        by_id[mid]["superseded_by"] = ev.get("superseded_by")
                elif evt == "invalidate":
                    if mid in by_id:
                        by_id[mid]["valid_until"] = ev.get("ts")

    for mid in forgotten:
        by_id.pop(mid, None)
        for k in by_type:
            by_type[k] = [m for m in by_type[k] if m != mid]
        for k in by_tag:
            by_tag[k] = [m for m in by_tag[k] if m != mid]
        by_recent = [m for m in by_recent if m != mid]

    by_recent.sort(key=lambda m: by_id.get(m, {}).get("created_at", ""), reverse=True)
    recent_full = [by_id[m] for m in by_recent[:200] if m in by_id]

    # Rebuild legacy JSON indexes (backward compat)
    with open(os.path.join(idx_dir, "by-type.json"), "w") as f:
        json.dump(dict(by_type), f, indent=2)
    with open(os.path.join(idx_dir, "by-tag.json"), "w") as f:
        json.dump(dict(by_tag), f, indent=2)
    with open(os.path.join(idx_dir, "by-id.json"), "w") as f:
        json.dump(by_id, f, indent=2)
    with open(os.path.join(idx_dir, "recent.json"), "w") as f:
        json.dump(recent_full, f, indent=2)

    # Compute embeddings (only for new/changed memories, using cache)
    emb_cache = {}
    if HAVE_VEC:
        emb_cache = _load_emb_cache(mem_dir)
        # Remove forgotten memories from cache
        for mid in forgotten:
            emb_cache.pop(mid, None)
        # Find memories that need embedding
        to_embed_ids = [mid for mid in by_id if mid not in emb_cache]
        if to_embed_ids:
            try:
                _scripts_dir = os.path.dirname(os.path.abspath(__file__))
                if _scripts_dir not in sys.path:
                    sys.path.insert(0, _scripts_dir)
                from _embedding_helpers import embed_batch
                texts = [by_id[mid].get("text", "") for mid in to_embed_ids]
                embeddings = embed_batch(texts)
                for mid, emb in zip(to_embed_ids, embeddings):
                    emb_cache[mid] = emb
                _save_emb_cache(mem_dir, emb_cache)
            except Exception as e:
                sys.stderr.write(f"[embedding] warn: {e}\n")

    # Rebuild SQLite read model
    import tempfile
    tmp_db = db_path + ".tmp"
    if os.path.exists(tmp_db):
        os.unlink(tmp_db)
    conn = open_db(tmp_db)
    conn.execute("DELETE FROM memories")

    for mid, m in by_id.items():
        tags_str = " ".join(m.get("tags", []) or [])
        conn.execute("""
            INSERT OR REPLACE INTO memories
              (id, type, text, tags, source, created_at, expires_at, confidence, access_count, last_accessed,
               supersedes, superseded_by, valid_until)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            mid,
            m.get("type", "fact"),
            m.get("text", ""),
            tags_str,
            m.get("source", ""),
            m.get("created_at", ""),
            m.get("expires_at"),
            m.get("confidence", 0.9),
            access_counts.get(mid, 0),
            last_accessed.get(mid),
            m.get("supersedes"),
            m.get("superseded_by"),
            m.get("valid_until"),
        ))
    conn.execute("INSERT INTO memories_fts(memories_fts) VALUES ('rebuild')")

    # Populate vec table
    if HAVE_VEC and emb_cache:
        for mid, emb in emb_cache.items():
            if mid not in by_id:
                continue
            row = conn.execute("SELECT rowid FROM memories WHERE id = ?", (mid,)).fetchone()
            if row:
                conn.execute(
                    "INSERT OR REPLACE INTO memories_vec(rowid, embedding) VALUES (?, ?)",
                    (row["rowid"], json.dumps(emb))
                )

    conn.commit()
    conn.close()

    # Atomic swap
    if os.path.exists(db_path):
        os.unlink(db_path)
    os.rename(tmp_db, db_path)

    vec_count = len(emb_cache) if HAVE_VEC else 0
    print(f"indexed: {len(by_id)} memories, {len(forgotten)} forgotten, {vec_count} embedded")


def recall():
    mem_dir, vault, idx_dir, db_path = vault_paths()
    type_ = os.environ.get("MV_TYPE", "")
    tags = [t.strip() for t in os.environ.get("MV_TAGS", "").split(",") if t.strip()]
    query = os.environ.get("MV_QUERY", "").strip()
    since = os.environ.get("MV_SINCE", "")
    limit = int(os.environ.get("MV_LIMIT", "20"))
    include_history = os.environ.get("MV_INCLUDE_HISTORY", "").lower() in ("1", "true", "yes")

    # Fall back to JSON index if DB not built yet
    if not os.path.exists(db_path):
        _recall_json(idx_dir, type_, tags, query, since, limit)
        return

    conn = open_db(db_path)

    hit_ids = []

    if query:
        # --- FTS5 BM25 ranked search ---
        fts_query = _fts_sanitize(query)
        try:
            rows = conn.execute("""
                SELECT m.id, fts.rank
                FROM memories_fts fts
                JOIN memories m ON m.id = fts.id
                WHERE memories_fts MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            """, (fts_query, limit * 3)).fetchall()
            fts_ids = [r["id"] for r in rows]
        except sqlite3.OperationalError:
            fts_ids = []

        # Substring fallback for short/partial terms
        substr_rows = conn.execute("""
            SELECT id FROM memories
            WHERE lower(text) LIKE ? OR lower(tags) LIKE ?
            LIMIT ?
        """, (f"%{query.lower()}%", f"%{query.lower()}%", limit * 2)).fetchall()
        substr_ids = [r["id"] for r in substr_rows]

        # --- Vector KNN semantic search ---
        vec_ids = []
        if HAVE_VEC:
            try:
                _scripts_dir = os.path.dirname(os.path.abspath(__file__))
                if _scripts_dir not in sys.path:
                    sys.path.insert(0, _scripts_dir)
                from _embedding_helpers import embed
                q_emb = embed(query)
                vec_rows = conn.execute("""
                    SELECT m.id, v.distance
                    FROM memories_vec v
                    JOIN memories m ON m.rowid = v.rowid
                    WHERE v.embedding MATCH ?
                    ORDER BY v.distance
                    LIMIT ?
                """, (json.dumps(q_emb), limit * 3)).fetchall()
                vec_ids = [r["id"] for r in vec_rows]
            except Exception:
                vec_ids = []

        # --- Reciprocal Rank Fusion (RRF) merge ---
        # Each list contributes score = 1/(k + rank), k=60
        K = 60
        scores: dict[str, float] = {}
        for rank, mid in enumerate(fts_ids):
            scores[mid] = scores.get(mid, 0) + 1.0 / (K + rank)
        for rank, mid in enumerate(vec_ids):
            scores[mid] = scores.get(mid, 0) + 1.0 / (K + rank)
        # Substring hits that didn't appear in either ranked list get a small bonus
        for mid in substr_ids:
            if mid not in scores:
                scores[mid] = 1.0 / (K + limit * 3)

        hit_ids = sorted(scores, key=lambda m: scores[m], reverse=True)
    else:
        # No query — return by recency
        rows = conn.execute(
            "SELECT id FROM memories ORDER BY created_at DESC LIMIT ?",
            (limit * 3,)
        ).fetchall()
        hit_ids = [r["id"] for r in rows]

    # Apply filters and fetch full records
    results = []
    for mid in hit_ids:
        row = conn.execute(
            "SELECT * FROM memories WHERE id = ?", (mid,)
        ).fetchone()
        if not row:
            continue
        # Exclude superseded memories unless caller explicitly requests history
        if not include_history and row["superseded_by"]:
            continue
        if type_ and row["type"] != type_:
            continue
        if tags and not any(t in (row["tags"] or "").split() for t in tags):
            continue
        if since and row["created_at"] < since:
            continue
        results.append(dict(row))
        if len(results) >= limit:
            break

    conn.close()

    # Track access — append access events to vault.jsonl
    if results:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(vault, "a") as f:
            for r in results:
                ev = {"event": "access", "id": r["id"], "ts": now}
                f.write(json.dumps(ev) + "\n")
        # Update SQLite access counts in-place (non-blocking, best-effort)
        try:
            conn2 = open_db(db_path)
            for r in results:
                conn2.execute(
                    "UPDATE memories SET access_count = access_count + 1, last_accessed = ? WHERE id = ?",
                    (now, r["id"])
                )
            conn2.commit()
            conn2.close()
        except Exception:
            pass

    # Convert to vault.jsonl record format for callers
    out = []
    for r in results:
        tags_list = [t for t in (r.get("tags") or "").split() if t]
        out.append({
            "id": r["id"],
            "type": r["type"],
            "text": r["text"],
            "tags": tags_list,
            "source": r.get("source", ""),
            "created_at": r.get("created_at", ""),
            "expires_at": r.get("expires_at"),
            "confidence": r.get("confidence", 0.9),
            "access_count": r.get("access_count", 0),
            "last_accessed": r.get("last_accessed"),
            "supersedes": r.get("supersedes"),
            "superseded_by": r.get("superseded_by"),
            "valid_until": r.get("valid_until"),
        })

    print(json.dumps(out, indent=2))


def _fts_sanitize(query):
    """Convert a natural language query to a safe FTS5 MATCH expression."""
    # Remove FTS5 special chars that cause syntax errors
    cleaned = re.sub(r'["\'\(\)\*\:\^]', ' ', query)
    words = [w.strip() for w in cleaned.split() if len(w.strip()) >= 2]
    if not words:
        return '""'
    # Use prefix matching on each word for partial term support
    return " OR ".join(f'"{w}"' for w in words[:8])


def _recall_json(idx_dir, type_, tags, query, since, limit):
    """Fallback recall from legacy JSON index."""
    try:
        with open(os.path.join(idx_dir, "recent.json")) as f:
            mems = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        mems = []

    out = []
    for m in mems:
        if type_ and m.get("type") != type_:
            continue
        if tags and not any(t in (m.get("tags") or []) for t in tags):
            continue
        if since and m.get("created_at", "") < since:
            continue
        if query:
            haystack = (m.get("text", "") + " " + " ".join(m.get("tags", []) or [])).lower()
            if query.lower() not in haystack:
                continue
        out.append(m)
        if len(out) >= limit:
            break
    print(json.dumps(out, indent=2))


def summarize():
    mem_dir, vault, idx_dir, db_path = vault_paths()
    type_ = os.environ.get("MV_TYPE", "")
    tags = [t.strip() for t in os.environ.get("MV_TAGS", "").split(",") if t.strip()]
    limit = int(os.environ.get("MV_LIMIT", "20"))

    try:
        with open(os.path.join(idx_dir, "recent.json")) as f:
            mems = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        mems = []

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
            ac = m.get("access_count", 0)
            ac_str = f" _{esc(f'×{ac}')}_" if ac > 0 else ""
            lines.append(f"  • {esc(text)}{ac_str} `{esc(m.get('id', ''))}`")
        lines.append("")

    if total == 0:
        lines = [
            "*Memories* — 0",
            "",
            "_Nothing in the vault yet\\. Tell me to remember something\\._",
        ]

    print("\n".join(lines))




def history():
    """Show the validity chain for a memory — all superseded and superseding versions."""
    mem_dir, vault, idx_dir, db_path = vault_paths()
    target_id = os.environ.get("MV_ID", "")
    if not target_id:
        print(json.dumps([]))
        return

    if not os.path.exists(db_path):
        print(json.dumps([]))
        return

    conn = open_db(db_path)

    def get_mem(mid):
        row = conn.execute("SELECT * FROM memories WHERE id = ?", (mid,)).fetchone()
        return dict(row) if row else None

    # Walk backwards to root (find the oldest ancestor)
    chain = []
    current = get_mem(target_id)
    if not current:
        print(json.dumps([]))
        return

    # Walk backwards via supersedes links
    ancestor = current
    while ancestor and ancestor.get("supersedes"):
        prev = get_mem(ancestor["supersedes"])
        if prev:
            chain.insert(0, prev)
            ancestor = prev
        else:
            break

    chain.append(current)

    # Walk forwards via superseded_by links
    node = current
    while node and node.get("superseded_by"):
        nxt = get_mem(node["superseded_by"])
        if nxt:
            chain.append(nxt)
            node = nxt
        else:
            break

    conn.close()
    print(json.dumps(chain, indent=2))


def invalidate():
    """Mark a memory as superseded (without providing a replacement)."""
    mem_dir, vault, idx_dir, db_path = vault_paths()
    target_id = os.environ.get("MV_ID", "")
    reason = os.environ.get("MV_REASON", "invalidated")
    if not target_id:
        sys.exit("MV_ID not set")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Append an invalidation event to the vault
    ev = {"event": "invalidate", "id": target_id, "ts": now, "reason": reason}
    vault_path = os.path.join(mem_dir, "vault.jsonl")
    with open(vault_path, "a") as f:
        f.write(json.dumps(ev) + "\n")

    # Update DB directly
    if os.path.exists(db_path):
        conn = open_db(db_path)
        conn.execute("UPDATE memories SET valid_until = ? WHERE id = ?", (now, target_id))
        conn.commit()
        conn.close()

    print(f"invalidated: {target_id}")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "rebuild":
        rebuild()
    elif cmd == "recall":
        recall()
    elif cmd == "summarize":
        summarize()
    elif cmd == "history":
        history()
    elif cmd == "invalidate":
        invalidate()
    else:
        print(__doc__)
