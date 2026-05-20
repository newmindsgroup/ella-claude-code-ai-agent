"""
test_spans.py — verify _spans.py SQLite store contract.

These tests are pure-logic (no VPS hits). They lock in the OTel-conformant
schema + ROI math so future refactors stay backward-compatible with the
dashboard.
"""
from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import _spans  # noqa: E402


@pytest.fixture
def tmp_db(tmp_path):
    db = tmp_path / "spans.db"
    return db


def _span(span_id="s1", **kw):
    """Helper to build a Span with sane defaults."""
    return _spans.Span(
        span_id=kw.pop("span_id", span_id),
        parent_span_id=kw.pop("parent_span_id", None),
        conversation_id=kw.pop("conversation_id", "conv-1"),
        kind=kw.pop("kind", "tool_call"),
        name=kw.pop("name", "tool.Read"),
        start_ts=kw.pop("start_ts", "2026-05-19T01:00:00Z"),
        end_ts=kw.pop("end_ts", "2026-05-19T01:00:01Z"),
        duration_ms=kw.pop("duration_ms", 100),
        tool_name=kw.pop("tool_name", "Read"),
        **kw,
    )


def test_schema_creates_idempotently(tmp_db):
    """Calling connect() twice on the same DB should not raise."""
    with _spans.connect(tmp_db) as conn:
        pass
    with _spans.connect(tmp_db) as conn:
        # Should still work; schema is CREATE IF NOT EXISTS
        rows = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
        assert any(r["name"] == "spans" for r in rows)


def test_upsert_and_query_roundtrip(tmp_db):
    """Insert one span, fetch it back. Cost computed from tokens."""
    span = _span(
        span_id="s-x", kind="llm_call", name="anthropic.chat",
        tokens_in=1_000_000, tokens_out=500_000, cache_read=100_000,
        model="claude-sonnet-4-6", tool_name=None,
    )
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_span(conn, span)
        rows = _spans.recent_spans(conn, limit=10)
    assert len(rows) == 1
    r = rows[0]
    assert r["span_id"] == "s-x"
    assert r["kind"] == "llm_call"
    assert r["tokens_in"] == 1_000_000
    # Cost: 1M*$3 + 0.5M*$15 + 0.1M*$0.30 = $3 + $7.50 + $0.03 = $10.53
    assert abs(r["cost_usd"] - 10.53) < 0.001


def test_upsert_is_idempotent(tmp_db):
    """Same span_id upserted twice = one row, latest wins."""
    s1 = _span(span_id="dup", name="first", tokens_in=100)
    s2 = _span(span_id="dup", name="second", tokens_in=200)
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_span(conn, s1)
        _spans.upsert_span(conn, s2)
        rows = _spans.recent_spans(conn, limit=10)
    assert len(rows) == 1
    assert rows[0]["name"] == "second"
    assert rows[0]["tokens_in"] == 200


def test_tool_breakdown_aggregates(tmp_db):
    """Two tool calls of same name aggregate into one row."""
    spans = [
        _span(span_id="r1", tool_name="Read", duration_ms=100, tokens_in=10),
        _span(span_id="r2", tool_name="Read", duration_ms=200, tokens_in=20),
        _span(span_id="b1", tool_name="Bash", duration_ms=500, tokens_in=5),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        since = "2020-01-01T00:00:00Z"
        breakdown = _spans.tool_breakdown(conn, since)
    by_name = {b["tool_name"]: b for b in breakdown}
    assert by_name["Read"]["calls"] == 2
    assert by_name["Read"]["avg_ms"] == 150.0
    assert by_name["Read"]["tokens_in"] == 30
    assert by_name["Bash"]["calls"] == 1


def test_kind_breakdown_aggregates(tmp_db):
    spans = [
        _span(span_id="t1", kind="tool_call", tool_name="Read"),
        _span(span_id="t2", kind="tool_call", tool_name="Bash"),
        _span(span_id="l1", kind="llm_call", tool_name=None, name="chat"),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        out = _spans.kind_breakdown(conn, "2020-01-01T00:00:00Z")
    by_kind = {k["kind"]: k for k in out}
    assert by_kind["tool_call"]["calls"] == 2
    assert by_kind["llm_call"]["calls"] == 1


def test_recent_spans_ordered_newest_first(tmp_db):
    spans = [
        _span(span_id="early", start_ts="2026-05-19T01:00:00Z", tool_name="A"),
        _span(span_id="late",  start_ts="2026-05-19T05:00:00Z", tool_name="B"),
        _span(span_id="mid",   start_ts="2026-05-19T03:00:00Z", tool_name="C"),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        rows = _spans.recent_spans(conn, limit=10)
    assert [r["span_id"] for r in rows] == ["late", "mid", "early"]


def test_session_tree_filters_by_conversation(tmp_db):
    spans = [
        _span(span_id="a", conversation_id="c1"),
        _span(span_id="b", conversation_id="c1"),
        _span(span_id="x", conversation_id="other"),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        c1 = _spans.session_tree(conn, "c1")
    ids = {r["span_id"] for r in c1}
    assert ids == {"a", "b"}


def test_prune_removes_old_spans(tmp_db):
    spans = [
        _span(span_id="old", start_ts="2020-01-01T00:00:00Z", tool_name="A"),
        _span(span_id="new", start_ts=_spans.now_iso(),       tool_name="B"),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        deleted = _spans.prune_older_than(conn, days=30)
    assert deleted == 1
    with _spans.connect(tmp_db) as conn:
        remaining = _spans.recent_spans(conn, limit=10)
    assert {r["span_id"] for r in remaining} == {"new"}


def test_cost_includes_cache_tokens(tmp_db):
    """Cache write @ $3.75/MT and cache read @ $0.30/MT both factor in."""
    s = _span(
        span_id="cache-test", kind="llm_call", tool_name=None,
        tokens_in=0, tokens_out=0, cache_read=1_000_000, cache_write=1_000_000,
    )
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_span(conn, s)
        rows = _spans.recent_spans(conn, limit=10)
    # 1M @ $0.30 + 1M @ $3.75 = $4.05
    assert abs(rows[0]["cost_usd"] - 4.05) < 0.001


def test_unknown_kind_still_stored(tmp_db):
    """The DB layer is permissive — validation happens at the parser layer."""
    s = _span(span_id="weird", kind="future_kind_not_in_canon")
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_span(conn, s)
        rows = _spans.recent_spans(conn, limit=10)
    assert rows[0]["kind"] == "future_kind_not_in_canon"


def test_span_kinds_constant_present():
    """The canonical SPAN_KINDS frozenset is exposed for parsers to reference."""
    assert "llm_call" in _spans.SPAN_KINDS
    assert "tool_call" in _spans.SPAN_KINDS
    assert "agent_dispatch" in _spans.SPAN_KINDS
    assert "session" in _spans.SPAN_KINDS


def test_session_latencies_computes_intent_to_action(tmp_db):
    """First llm_call at t=0, first tool_call at t=2s → intent_to_first = 2000ms."""
    spans = [
        _span(span_id="llm-1", conversation_id="conv-A", kind="llm_call",
              tool_name=None, start_ts="2026-05-19T01:00:00Z",
              end_ts="2026-05-19T01:00:01Z", duration_ms=1000),
        _span(span_id="tool-1", conversation_id="conv-A", kind="tool_call",
              tool_name="Read", start_ts="2026-05-19T01:00:02Z",
              end_ts="2026-05-19T01:00:02.500Z", duration_ms=500),
        _span(span_id="tool-2", conversation_id="conv-A", kind="tool_call",
              tool_name="Bash", start_ts="2026-05-19T01:00:05Z",
              end_ts="2026-05-19T01:00:06Z", duration_ms=1000),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        result = _spans.session_latencies(conn, "2020-01-01T00:00:00Z")

    assert len(result["sessions"]) == 1
    s = result["sessions"][0]
    assert s["conversation_id"] == "conv-A"
    # llm at 01:00:00, first tool at 01:00:02 → 2000ms
    assert s["intent_to_first_ms"] == 2000
    # First ts 01:00:00, last ts 01:00:06 → 6000ms
    assert s["first_to_last_ms"] == 6000
    assert s["n_spans"] == 3


def test_session_latencies_summary_percentiles(tmp_db):
    """Three sessions with varying latencies — median + p95 land correctly."""
    base = "2026-05-19T01:00:"
    for i, intent_s in enumerate([1, 2, 5]):  # 1s, 2s, 5s to first action
        spans = [
            _span(span_id=f"llm-{i}", conversation_id=f"conv-{i}", kind="llm_call",
                  tool_name=None, start_ts=f"{base}0{i}.000Z",
                  end_ts=f"{base}0{i}.100Z", duration_ms=100),
            _span(span_id=f"tool-{i}", conversation_id=f"conv-{i}", kind="tool_call",
                  tool_name="Read", start_ts=f"{base}0{i+intent_s}.000Z",
                  end_ts=f"{base}0{i+intent_s+1}.000Z", duration_ms=1000),
        ]
        with _spans.connect(tmp_db) as conn:
            _spans.upsert_many(conn, spans)

    with _spans.connect(tmp_db) as conn:
        result = _spans.session_latencies(conn, "2020-01-01T00:00:00Z")
    assert result["summary"]["sessions"] == 3
    # Median of {1000, 2000, 5000} = 2000ms
    assert result["summary"]["median_first_action_ms"] == 2000
    # p95 of those = 5000ms (clamp to max)
    assert result["summary"]["p95_first_action_ms"] == 5000


def test_session_latencies_handles_no_spans(tmp_db):
    with _spans.connect(tmp_db) as conn:
        result = _spans.session_latencies(conn, "2020-01-01T00:00:00Z")
    assert result["sessions"] == []
    assert result["summary"]["sessions"] == 0
    assert result["summary"]["median_first_action_ms"] is None


def test_cost_breakdown_attribution(tmp_db):
    """v2.68.0: cost_breakdown groups cost by kind + session, computes cache ratio."""
    spans = [
        _span(span_id="x1", conversation_id="sess-A", kind="llm_call", tool_name=None,
              tokens_in=1_000_000, tokens_out=100_000, cache_read=50_000),
        _span(span_id="x2", conversation_id="sess-A", kind="llm_call", tool_name=None,
              tokens_in=2_000_000, tokens_out=50_000, cache_read=0),
        _span(span_id="t1", conversation_id="sess-B", kind="tool_call", tool_name="Read",
              tokens_in=5_000),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        bd = _spans.cost_breakdown(conn, "2020-01-01T00:00:00Z")
    assert bd["total_cost_usd"] > 0
    # Cache ratio low: ~50k cache_read / (50k + ~3.005M input)
    assert bd["cache_ratio"] < 0.1
    assert bd["by_kind"][0]["kind"] == "llm_call"
    assert bd["top_sessions"][0]["conversation_id"] == "sess-A"


def test_cost_breakdown_empty(tmp_db):
    with _spans.connect(tmp_db) as conn:
        bd = _spans.cost_breakdown(conn, "2020-01-01T00:00:00Z")
    assert bd["total_cost_usd"] == 0
    assert bd["cache_ratio"] == 0.0
    assert bd["by_kind"] == []
    assert bd["top_sessions"] == []


def test_agent_breakdown_aggregates(tmp_db):
    """v2.70.0: per-sub-agent rollup from agent_dispatch spans."""
    spans = [
        _span(span_id="d1", kind="agent_dispatch", agent_id="brand-drift-scanner",
              tool_name="Task", duration_ms=2000, end_ts="2026-05-20T01:00:02Z",
              start_ts="2026-05-20T01:00:00Z", tokens_in=100_000, tokens_out=20_000),
        _span(span_id="d2", kind="agent_dispatch", agent_id="brand-drift-scanner",
              tool_name="Task", duration_ms=4000, end_ts="2026-05-20T02:00:04Z",
              start_ts="2026-05-20T02:00:00Z", tokens_in=80_000, tokens_out=10_000),
        # An in-flight dispatch (end_ts NULL) of a different agent
        _span(span_id="d3", kind="agent_dispatch", agent_id="pipeline-reporter",
              tool_name="Task", duration_ms=None, end_ts=None,
              start_ts="2026-05-20T03:00:00Z", status="error"),
        # A non-dispatch span — must be excluded
        _span(span_id="t1", kind="tool_call", agent_id=None, tool_name="Read"),
    ]
    with _spans.connect(tmp_db) as conn:
        _spans.upsert_many(conn, spans)
        agents = _spans.agent_breakdown(conn, "2020-01-01T00:00:00Z")
    by_id = {a["agent_id"]: a for a in agents}
    assert set(by_id) == {"brand-drift-scanner", "pipeline-reporter"}
    drift = by_id["brand-drift-scanner"]
    assert drift["dispatches"] == 2
    assert drift["total_ms"] == 6000
    assert drift["avg_ms"] == 3000
    assert drift["live"] == 0
    assert drift["cost_usd"] > 0
    pr = by_id["pipeline-reporter"]
    assert pr["live"] == 1       # in-flight
    assert pr["errors"] == 1


def test_agent_breakdown_empty(tmp_db):
    with _spans.connect(tmp_db) as conn:
        agents = _spans.agent_breakdown(conn, "2020-01-01T00:00:00Z")
    assert agents == []
