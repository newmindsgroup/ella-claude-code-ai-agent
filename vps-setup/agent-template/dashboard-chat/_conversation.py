"""
_conversation.py — unified conversation store for Mission Control chat.

v2.61.0 introduces a single source of truth for the chat thread that BOTH the
dashboard chat and (later, Phase B/C) the Telegram channel write to and read
from. This is what makes the two surfaces consistent: a message typed in the
dashboard and a message sent in Telegram land in the same store, tagged with
their source, so either surface can render the full thread.

Why SQLite (not JSONL like the legacy history.jsonl):
  - Two writers (dashboard + Telegram tee) → need atomic concurrent appends.
  - We want to query by source, by role, by time range, search text.
  - Matches the spans.db pattern from v2.54.

Schema is per-MESSAGE (not per round-trip like history.jsonl):
  - A user prompt is one row (role=user).
  - The agent reply is another row (role=agent), linked by request_id.
  - Attachments (voice/image/file) are JSON metadata on the row.

The legacy history.jsonl is kept in dual-write during the migration window so
nothing that reads it breaks. New readers should use this module.
"""
from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

# ----------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes the {{TENANT_*}} placeholder
# ----------------------------------------------------------------------------
AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

DB_PATH = Path(AGENT_HOME) / "dashboard-chat" / "state" / "conversation.db"

ROLES = frozenset({"user", "agent"})
SOURCES = frozenset({"dashboard", "telegram", "voice", "system"})


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS messages (
    id            TEXT PRIMARY KEY,
    ts            TEXT NOT NULL,
    role          TEXT NOT NULL,         -- user | agent
    source        TEXT NOT NULL,         -- dashboard | telegram | voice | system
    text          TEXT NOT NULL DEFAULT '',
    request_id    TEXT,                  -- links a user prompt to its agent reply
    tokens_in     INTEGER NOT NULL DEFAULT 0,
    tokens_out    INTEGER NOT NULL DEFAULT 0,
    cache_read    INTEGER NOT NULL DEFAULT 0,
    cache_write   INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    duration_ms   INTEGER,
    attachments   TEXT NOT NULL DEFAULT '[]',   -- JSON array of {type,url,name,mime}
    session_id    TEXT
);

CREATE INDEX IF NOT EXISTS idx_msg_ts      ON messages(ts);
CREATE INDEX IF NOT EXISTS idx_msg_source  ON messages(source);
CREATE INDEX IF NOT EXISTS idx_msg_request ON messages(request_id) WHERE request_id IS NOT NULL;
"""


def _ensure_db(db_path: Path = DB_PATH) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.executescript(SCHEMA_SQL)


@contextmanager
def connect(db_path: Path = DB_PATH):
    _ensure_db(db_path)
    conn = sqlite3.connect(db_path, timeout=30.0)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        yield conn
        conn.commit()
    finally:
        conn.close()


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def new_id() -> str:
    return uuid.uuid4().hex[:16]


def append_message(
    *,
    role: str,
    source: str,
    text: str = "",
    request_id: Optional[str] = None,
    tokens: Optional[dict] = None,
    cost_usd: float = 0.0,
    duration_ms: Optional[int] = None,
    attachments: Optional[list] = None,
    session_id: Optional[str] = None,
    ts: Optional[str] = None,
    msg_id: Optional[str] = None,
    db_path: Path = DB_PATH,
) -> dict:
    """Append one message. Returns the stored row as a dict."""
    if role not in ROLES:
        role = "user" if role == "user" else "agent"
    if source not in SOURCES:
        source = "dashboard"
    tokens = tokens or {}
    row = {
        "id": msg_id or new_id(),
        "ts": ts or now_iso(),
        "role": role,
        "source": source,
        "text": text or "",
        "request_id": request_id,
        "tokens_in": int(tokens.get("input_tokens", 0) or 0),
        "tokens_out": int(tokens.get("output_tokens", 0) or 0),
        "cache_read": int(tokens.get("cache_read_input_tokens", 0) or 0),
        "cache_write": int(tokens.get("cache_creation_input_tokens", 0) or 0),
        "cost_usd": float(cost_usd or 0.0),
        "duration_ms": duration_ms,
        "attachments": json.dumps(attachments or [], default=str),
        "session_id": session_id,
    }
    with connect(db_path) as conn:
        conn.execute(
            """
            INSERT OR REPLACE INTO messages
                (id, ts, role, source, text, request_id, tokens_in, tokens_out,
                 cache_read, cache_write, cost_usd, duration_ms, attachments, session_id)
            VALUES (:id, :ts, :role, :source, :text, :request_id, :tokens_in, :tokens_out,
                    :cache_read, :cache_write, :cost_usd, :duration_ms, :attachments, :session_id)
            """,
            row,
        )
    return _row_out(row)


def _row_out(row) -> dict:
    """Normalize a row (sqlite3.Row or dict) into the API shape."""
    d = dict(row)
    try:
        d["attachments"] = json.loads(d.get("attachments") or "[]")
    except Exception:
        d["attachments"] = []
    # API token shape mirrors the rest of the stack
    d["tokens"] = {
        "input_tokens": d.pop("tokens_in", 0),
        "output_tokens": d.pop("tokens_out", 0),
        "cache_read_input_tokens": d.pop("cache_read", 0),
        "cache_creation_input_tokens": d.pop("cache_write", 0),
    }
    return d


def recent_messages(limit: int = 100, db_path: Path = DB_PATH) -> list[dict]:
    """Return the most recent `limit` messages in chronological (oldest-first)
    order, so the frontend can append them top-to-bottom."""
    with connect(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM messages ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
    out = [_row_out(r) for r in rows]
    out.reverse()  # chronological for rendering
    return out


def message_count(db_path: Path = DB_PATH) -> int:
    with connect(db_path) as conn:
        row = conn.execute("SELECT COUNT(*) AS c FROM messages").fetchone()
    return row["c"] if row else 0


def clear_all(db_path: Path = DB_PATH) -> int:
    """Wipe the conversation (used by the 'Clear history' button). Returns rows deleted."""
    with connect(db_path) as conn:
        cur = conn.execute("DELETE FROM messages")
        return cur.rowcount or 0
