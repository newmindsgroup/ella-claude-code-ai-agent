"""
_spans.py — OTel-conformant span store for Mission Control.

v2.54.0 establishes the foundation for the Phase 4 observability roadmap. Every
LLM call, tool call, sub-agent invocation, and skill run gets a row here. The
schema follows OpenTelemetry GenAI Semantic Conventions (gen_ai.* + anthropic.*)
so we stay vendor-neutral.

Why SQLite, not Postgres:
  - Single-tenant. One write process (session-parser.py), many readers.
  - 30 days × ~50 spans/hour × ~500 bytes ≈ 18 MB. Trivial.
  - Postgres can come later via DATABASE_URL env (agentlens pattern).

Span hierarchy:
  conversation_id (e.g. claude-code session id)
    └─ root span (kind=session)
        ├─ child span (kind=llm_call)
        ├─ child span (kind=tool_call, tool=Read)
        ├─ child span (kind=tool_call, tool=Bash)
        └─ child span (kind=agent_dispatch, agent_id=brand-drift-scanner)
            └─ child span (kind=llm_call)

Span kinds — aligned with agent-telemetry-spec/atsc + OpenInference:
  session           — top-level user/cron-triggered run
  llm_call          — single Anthropic API call
  tool_call         — Read/Edit/Bash/Grep/Glob/WebFetch/etc
  agent_dispatch    — Task() invocation of a sub-agent
  mcp_call          — MCP server tool invocation
  skill_run         — agent-skill@*.service execution
  watcher_tick      — proactive watcher cycle
  rule_eval         — behavioral rule evaluation
  retrieval         — Graphify / memory-vault lookup
"""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

# ----------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes the {{TENANT_*}} placeholders
# ----------------------------------------------------------------------------
AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

DB_PATH = Path(AGENT_HOME) / "state" / "spans.db"

# Sonnet 4.6 list pricing — kept in sync with telemetry-calc.py
INPUT_PER_MTOK_USD       = 3.00
OUTPUT_PER_MTOK_USD      = 15.00
CACHE_WRITE_PER_MTOK_USD = 3.75
CACHE_READ_PER_MTOK_USD  = 0.30


SPAN_KINDS = frozenset({
    "session", "llm_call", "tool_call", "agent_dispatch", "mcp_call",
    "skill_run", "watcher_tick", "rule_eval", "retrieval",
})


@dataclass
class Span:
    """One observable agent action. Follows OTel GenAI semantic conventions."""
    span_id: str
    parent_span_id: Optional[str]
    conversation_id: str
    kind: str
    name: str
    start_ts: str                        # ISO8601 UTC
    end_ts: Optional[str] = None         # null if still running
    duration_ms: Optional[int] = None
    status: str = "ok"                   # ok | error | timeout
    error_type: Optional[str] = None
    # Token usage (OTel: gen_ai.usage.*)
    tokens_in: int = 0
    tokens_out: int = 0
    cache_read: int = 0                  # anthropic.cache_read_input_tokens
    cache_write: int = 0                 # anthropic.cache_creation_input_tokens
    model: Optional[str] = None          # gen_ai.response.model
    # Tool/agent/skill metadata
    tool_name: Optional[str] = None      # for kind=tool_call
    agent_id: Optional[str] = None       # for kind=agent_dispatch
    skill_name: Optional[str] = None     # for kind=skill_run
    # Arbitrary attributes — kept as JSON for forward-compat
    attributes: dict = field(default_factory=dict)
    # Provenance — where did this span come from
    source: str = "session-parser"       # session-parser | watcher | rules-engine | manual

    @property
    def cost_usd(self) -> float:
        """Compute USD cost from token counts. Cost is NOT stored — pricing
        table can change; recompute on read per OTel convention."""
        return (
            self.tokens_in   * INPUT_PER_MTOK_USD       / 1_000_000
            + self.tokens_out * OUTPUT_PER_MTOK_USD      / 1_000_000
            + self.cache_read * CACHE_READ_PER_MTOK_USD  / 1_000_000
            + self.cache_write* CACHE_WRITE_PER_MTOK_USD / 1_000_000
        )


# ----------------------------------------------------------------------------
# Schema
# ----------------------------------------------------------------------------
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS spans (
    span_id          TEXT PRIMARY KEY,
    parent_span_id   TEXT,
    conversation_id  TEXT NOT NULL,
    kind             TEXT NOT NULL,
    name             TEXT NOT NULL,
    start_ts         TEXT NOT NULL,
    end_ts           TEXT,
    duration_ms      INTEGER,
    status           TEXT NOT NULL DEFAULT 'ok',
    error_type       TEXT,
    tokens_in        INTEGER NOT NULL DEFAULT 0,
    tokens_out       INTEGER NOT NULL DEFAULT 0,
    cache_read       INTEGER NOT NULL DEFAULT 0,
    cache_write      INTEGER NOT NULL DEFAULT 0,
    model            TEXT,
    tool_name        TEXT,
    agent_id         TEXT,
    skill_name       TEXT,
    attributes       TEXT NOT NULL DEFAULT '{}',
    source           TEXT NOT NULL DEFAULT 'session-parser'
);

CREATE INDEX IF NOT EXISTS idx_spans_conv  ON spans(conversation_id);
CREATE INDEX IF NOT EXISTS idx_spans_kind  ON spans(kind);
CREATE INDEX IF NOT EXISTS idx_spans_start ON spans(start_ts);
CREATE INDEX IF NOT EXISTS idx_spans_tool  ON spans(tool_name) WHERE tool_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_spans_skill ON spans(skill_name) WHERE skill_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_spans_agent ON spans(agent_id) WHERE agent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_spans_parent ON spans(parent_span_id) WHERE parent_span_id IS NOT NULL;
"""


# ----------------------------------------------------------------------------
# Connection helpers
# ----------------------------------------------------------------------------
def _ensure_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.executescript(SCHEMA_SQL)


@contextmanager
def connect(db_path: Path = DB_PATH):
    """Open DB connection with row factory + WAL mode for concurrent readers."""
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


# ----------------------------------------------------------------------------
# Upsert + query
# ----------------------------------------------------------------------------
def upsert_span(conn: sqlite3.Connection, span: Span) -> None:
    """Insert or replace a span by span_id. Idempotent — safe for parser
    re-runs over the same JSONL lines."""
    conn.execute(
        """
        INSERT OR REPLACE INTO spans
            (span_id, parent_span_id, conversation_id, kind, name,
             start_ts, end_ts, duration_ms, status, error_type,
             tokens_in, tokens_out, cache_read, cache_write,
             model, tool_name, agent_id, skill_name, attributes, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            span.span_id, span.parent_span_id, span.conversation_id,
            span.kind, span.name, span.start_ts, span.end_ts,
            span.duration_ms, span.status, span.error_type,
            span.tokens_in, span.tokens_out, span.cache_read, span.cache_write,
            span.model, span.tool_name, span.agent_id, span.skill_name,
            json.dumps(span.attributes, default=str), span.source,
        ),
    )


def upsert_many(conn: sqlite3.Connection, spans: Iterable[Span]) -> int:
    """Bulk upsert. Returns count inserted/replaced."""
    n = 0
    for s in spans:
        upsert_span(conn, s)
        n += 1
    return n


def _row_to_dict(row: sqlite3.Row) -> dict:
    d = dict(row)
    try:
        d["attributes"] = json.loads(d.get("attributes") or "{}")
    except Exception:
        d["attributes"] = {}
    # Derived cost — never stored, always computed
    d["cost_usd"] = round(
        d.get("tokens_in", 0)   * INPUT_PER_MTOK_USD       / 1_000_000
        + d.get("tokens_out", 0) * OUTPUT_PER_MTOK_USD      / 1_000_000
        + d.get("cache_read", 0) * CACHE_READ_PER_MTOK_USD  / 1_000_000
        + d.get("cache_write", 0)* CACHE_WRITE_PER_MTOK_USD / 1_000_000,
        6,
    )
    return d


def recent_spans(conn: sqlite3.Connection, limit: int = 200) -> list[dict]:
    rows = conn.execute(
        "SELECT * FROM spans ORDER BY start_ts DESC LIMIT ?", (limit,)
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def session_latencies(conn: sqlite3.Connection, since_ts: str, limit: int = 100) -> dict:
    """v2.60.0: Compute time-to-first-action + total wall-clock per session.

    For each conversation_id with at least one span since `since_ts`, returns:
      - first_ts:           when the first span started
      - first_action_ts:    when the first non-LLM span started (tool/agent dispatch)
      - last_ts:            when the most-recent span ended/started
      - intent_to_first_ms: gap between first LLM call and first tool/agent action
      - first_to_last_ms:   total session wall-clock
      - n_spans:            count of spans in this session

    Then summarizes across all sessions:
      - median_first_action_ms / p95
      - median_total_ms / p95
    """
    rows = conn.execute(
        """
        SELECT conversation_id,
               span_id, kind, start_ts, end_ts
          FROM spans
         WHERE start_ts >= ?
         ORDER BY conversation_id, start_ts ASC
        """,
        (since_ts,),
    ).fetchall()

    sessions: dict[str, dict] = {}
    for r in rows:
        conv = r["conversation_id"]
        s = sessions.setdefault(conv, {
            "conversation_id": conv,
            "first_ts": None, "first_action_ts": None, "last_ts": None,
            "first_llm_ts": None, "n_spans": 0,
        })
        s["n_spans"] += 1
        if s["first_ts"] is None:
            s["first_ts"] = r["start_ts"]
        s["last_ts"] = r["end_ts"] or r["start_ts"]
        if r["kind"] == "llm_call" and s["first_llm_ts"] is None:
            s["first_llm_ts"] = r["start_ts"]
        if r["kind"] in ("tool_call", "agent_dispatch") and s["first_action_ts"] is None:
            s["first_action_ts"] = r["start_ts"]

    def _to_ms(a: str | None, b: str | None) -> int | None:
        if not a or not b:
            return None
        try:
            ta = datetime.fromisoformat(a.replace("Z", "+00:00"))
            tb = datetime.fromisoformat(b.replace("Z", "+00:00"))
            return max(0, int((tb - ta).total_seconds() * 1000))
        except (ValueError, TypeError):
            return None

    enriched = []
    for s in sessions.values():
        s["intent_to_first_ms"] = _to_ms(s["first_llm_ts"], s["first_action_ts"])
        s["first_to_last_ms"]   = _to_ms(s["first_ts"], s["last_ts"])
        enriched.append(s)

    # Sort by recency descending, cap at limit
    enriched.sort(key=lambda r: r["first_ts"] or "", reverse=True)
    enriched = enriched[:limit]

    # Summary percentiles
    def _percentile(values: list[int], p: float) -> int | None:
        if not values:
            return None
        sv = sorted(values)
        idx = max(0, min(len(sv) - 1, int(round(p * (len(sv) - 1)))))
        return sv[idx]

    intent_vals = [s["intent_to_first_ms"] for s in enriched if s["intent_to_first_ms"] is not None]
    total_vals  = [s["first_to_last_ms"]   for s in enriched if s["first_to_last_ms"]   is not None]
    summary = {
        "sessions":              len(enriched),
        "median_first_action_ms": _percentile(intent_vals, 0.5),
        "p95_first_action_ms":    _percentile(intent_vals, 0.95),
        "median_total_ms":        _percentile(total_vals,  0.5),
        "p95_total_ms":           _percentile(total_vals,  0.95),
    }
    return {"sessions": enriched, "summary": summary}


def live_span(conn: sqlite3.Connection, since_ts: str) -> dict | None:
    """v2.58.0: Return the most recent span that's still open (end_ts NULL),
    if any started after `since_ts`. The dashboard topbar uses this to render
    a 'Live · WebFetch (3s)' indicator.

    Filter on start_ts so we don't surface zombies left over from a crashed
    session — only count "open" spans that started in the last few minutes.
    """
    row = conn.execute(
        """
        SELECT * FROM spans
         WHERE end_ts IS NULL
           AND start_ts >= ?
         ORDER BY start_ts DESC
         LIMIT 1
        """,
        (since_ts,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def session_tree(conn: sqlite3.Connection, conversation_id: str) -> list[dict]:
    """Return all spans for a session, ordered by start_ts.
    Caller builds the tree from parent_span_id."""
    rows = conn.execute(
        "SELECT * FROM spans WHERE conversation_id = ? ORDER BY start_ts ASC",
        (conversation_id,),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def tool_breakdown(conn: sqlite3.Connection, since_ts: str) -> list[dict]:
    """Aggregate by tool_name since the given UTC ISO timestamp."""
    rows = conn.execute(
        """
        SELECT tool_name,
               COUNT(*) AS calls,
               SUM(tokens_in)   AS tokens_in,
               SUM(tokens_out)  AS tokens_out,
               SUM(cache_read)  AS cache_read,
               SUM(cache_write) AS cache_write,
               AVG(duration_ms) AS avg_ms,
               MIN(duration_ms) AS min_ms,
               MAX(duration_ms) AS max_ms
          FROM spans
         WHERE tool_name IS NOT NULL AND start_ts >= ?
         GROUP BY tool_name
         ORDER BY calls DESC
        """,
        (since_ts,),
    ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["cost_usd"] = round(
            (d.get("tokens_in")  or 0)  * INPUT_PER_MTOK_USD       / 1_000_000
            + (d.get("tokens_out") or 0) * OUTPUT_PER_MTOK_USD      / 1_000_000
            + (d.get("cache_read") or 0) * CACHE_READ_PER_MTOK_USD  / 1_000_000
            + (d.get("cache_write") or 0)* CACHE_WRITE_PER_MTOK_USD / 1_000_000,
            4,
        )
        out.append(d)
    return out


def kind_breakdown(conn: sqlite3.Connection, since_ts: str) -> list[dict]:
    """Aggregate by span kind since the given UTC ISO timestamp."""
    rows = conn.execute(
        """
        SELECT kind,
               COUNT(*) AS calls,
               SUM(tokens_in + tokens_out + cache_read + cache_write) AS tokens_total,
               AVG(duration_ms) AS avg_ms
          FROM spans
         WHERE start_ts >= ?
         GROUP BY kind
         ORDER BY calls DESC
        """,
        (since_ts,),
    ).fetchall()
    return [dict(r) for r in rows]


def _tok_cost(ti, to, cr, cw) -> float:
    return round(
        (ti or 0) * INPUT_PER_MTOK_USD       / 1_000_000
        + (to or 0) * OUTPUT_PER_MTOK_USD     / 1_000_000
        + (cr or 0) * CACHE_READ_PER_MTOK_USD / 1_000_000
        + (cw or 0) * CACHE_WRITE_PER_MTOK_USD/ 1_000_000,
        4,
    )


def cost_breakdown(conn: sqlite3.Connection, since_ts: str, top: int = 8) -> dict:
    """v2.68.0: cost-attribution for spend-spike diagnosis. Returns total cost,
    cache stats, per-kind cost, and the top sessions by cost since `since_ts`.

    Cache ratio is the headline diagnostic: if it's low (<~50%) for a session
    that re-sends a big context every turn, prompt caching isn't landing and
    that's a 10× cost multiplier — the usual culprit behind a spend spike.
    """
    rows = conn.execute(
        """
        SELECT conversation_id, kind, tokens_in, tokens_out, cache_read, cache_write
          FROM spans
         WHERE start_ts >= ?
        """,
        (since_ts,),
    ).fetchall()

    total_in = total_out = total_cr = total_cw = 0
    by_kind: dict[str, dict] = {}
    by_session: dict[str, dict] = {}
    for r in rows:
        ti, to_, cr, cw = (r["tokens_in"] or 0, r["tokens_out"] or 0,
                           r["cache_read"] or 0, r["cache_write"] or 0)
        total_in += ti; total_out += to_; total_cr += cr; total_cw += cw
        k = by_kind.setdefault(r["kind"], {"kind": r["kind"], "in": 0, "out": 0, "cr": 0, "cw": 0, "calls": 0})
        k["in"] += ti; k["out"] += to_; k["cr"] += cr; k["cw"] += cw; k["calls"] += 1
        sid = r["conversation_id"]
        s = by_session.setdefault(sid, {"conversation_id": sid, "in": 0, "out": 0, "cr": 0, "cw": 0, "calls": 0})
        s["in"] += ti; s["out"] += to_; s["cr"] += cr; s["cw"] += cw; s["calls"] += 1

    def _finish(d):
        d["cost_usd"] = _tok_cost(d["in"], d["out"], d["cr"], d["cw"])
        return d

    kinds = sorted((_finish(v) for v in by_kind.values()), key=lambda x: x["cost_usd"], reverse=True)
    sessions = sorted((_finish(v) for v in by_session.values()), key=lambda x: x["cost_usd"], reverse=True)[:top]

    total_cost = _tok_cost(total_in, total_out, total_cr, total_cw)
    # Cache ratio = cache_read / (cache_read + uncached input). High = good.
    cache_denom = total_cr + total_in
    cache_ratio = round(total_cr / cache_denom, 4) if cache_denom else 0.0
    # What the cache_read tokens WOULD have cost at full input price (savings).
    cache_savings = round((total_cr / 1_000_000) * (INPUT_PER_MTOK_USD - CACHE_READ_PER_MTOK_USD), 4)

    return {
        "total_cost_usd": total_cost,
        "tokens": {"input": total_in, "output": total_out, "cache_read": total_cr, "cache_write": total_cw},
        "cache_ratio": cache_ratio,
        "cache_savings_usd": cache_savings,
        "by_kind": kinds,
        "top_sessions": sessions,
    }


def iso_start_of_day_utc() -> str:
    """UTC midnight today, ISO8601 — for 'today's' cost windows."""
    now = datetime.now(timezone.utc)
    return now.replace(hour=0, minute=0, second=0, microsecond=0).isoformat().replace("+00:00", "Z")


def prune_older_than(conn: sqlite3.Connection, days: int = 30) -> int:
    """Delete spans older than N days. Returns rows deleted."""
    cutoff = (datetime.now(timezone.utc).timestamp() - days * 86400)
    cutoff_iso = datetime.fromtimestamp(cutoff, timezone.utc).isoformat().replace("+00:00", "Z")
    cur = conn.execute("DELETE FROM spans WHERE start_ts < ?", (cutoff_iso,))
    return cur.rowcount or 0


# ----------------------------------------------------------------------------
# Time helpers (kept here to avoid sprinkling imports across callers)
# ----------------------------------------------------------------------------
def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def iso_minus_hours(hours: int) -> str:
    ts = datetime.now(timezone.utc).timestamp() - hours * 3600
    return datetime.fromtimestamp(ts, timezone.utc).isoformat().replace("+00:00", "Z")
