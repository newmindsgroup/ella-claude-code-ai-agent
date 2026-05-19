#!/usr/bin/env python3
"""
session-parser.py — Ingest Claude Code session transcripts into the spans DB.

Claude Code writes one JSONL file per session under ~/.claude/projects/<encoded-path>/<session-uuid>.jsonl.
Each line is an event (user message, assistant message, tool_use, tool_result,
…). v2.54.0 parses these into OTel-conformant spans so the dashboard's new
"Activity" tab can show every LLM call, every tool call, every sub-agent
dispatch.

Idempotent: spans are upserted by span_id (= the message uuid for LLM calls,
= the tool_use_id for tool calls). Safe to run every 2 minutes.

Scope: last 30 days hot. Older sessions are pruned each tick.

Privacy: we record metadata (tool name, token counts, duration, parent) — we
do NOT record message contents. Span events / message payloads remain in the
JSONL on disk; the dashboard never surfaces them.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

# Path imports — the scripts dir holds _spans.py
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _spans

# v2.58.0: best-effort audit-event posting so SSE subscribers see span activity
# without waiting for the next dashboard-sync tick.
AUDIT_URL = "http://127.0.0.1:8001/api/chat/audit"


def _post_audit(action: str, target: str, details: dict) -> None:
    body = {"action": action, "target": target, "details": details, "source": "session-parser"}
    try:
        req = urllib.request.Request(
            AUDIT_URL, data=json.dumps(body, default=str).encode(),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=3).close()
    except Exception:
        pass  # audit is best-effort; never block ingestion on a failed post

AGENT_HOME = "{{TENANT_AGENT_HOME}}"
if AGENT_HOME.startswith("{{"):
    AGENT_HOME = "/opt/agent"

USER_HOME = "{{TENANT_USER_HOME}}"
if USER_HOME.startswith("{{"):
    USER_HOME = "/opt/agent"

# Where Claude Code writes session JSONL files
CLAUDE_PROJECTS_DIR = Path(USER_HOME) / ".claude" / "projects"

# State file tracking last-parsed file offsets — keeps re-runs cheap
STATE_PATH = Path(AGENT_HOME) / "state" / "session-parser-cursor.json"

# How far back to walk on a cold start
COLD_START_DAYS = 30


# ----------------------------------------------------------------------------
# Cursor persistence — remember where we left off in each JSONL file
# ----------------------------------------------------------------------------
def load_cursor() -> dict[str, dict]:
    """Returns {file_path: {"offset": int, "mtime": float}}."""
    try:
        with STATE_PATH.open() as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_cursor(cursor: dict[str, dict]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(cursor, f, indent=2, sort_keys=True)
    tmp.replace(STATE_PATH)


# ----------------------------------------------------------------------------
# JSONL discovery + reading
# ----------------------------------------------------------------------------
def discover_session_files() -> list[Path]:
    """Return all *.jsonl under CLAUDE_PROJECTS_DIR, newest mtime first."""
    if not CLAUDE_PROJECTS_DIR.exists():
        return []
    files = list(CLAUDE_PROJECTS_DIR.rglob("*.jsonl"))
    # Only files modified in the last 30 days to bound the cold-start cost
    cutoff = time.time() - COLD_START_DAYS * 86400
    files = [f for f in files if f.stat().st_mtime >= cutoff]
    files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    return files


def iter_new_lines(path: Path, last_offset: int) -> Iterator[tuple[int, dict]]:
    """Yield (new_offset, decoded_event) for each new line past last_offset."""
    try:
        with path.open("rb") as f:
            f.seek(last_offset)
            while True:
                line_start = f.tell()
                raw = f.readline()
                if not raw:
                    return
                line_start = line_start  # capture before iterating
                try:
                    text = raw.decode("utf-8", errors="replace").rstrip("\n")
                    if not text.strip():
                        continue
                    event = json.loads(text)
                except json.JSONDecodeError:
                    continue
                yield f.tell(), event
    except FileNotFoundError:
        return


# ----------------------------------------------------------------------------
# Event → Span translation
# ----------------------------------------------------------------------------
def _iso(ts: float | str | None) -> str | None:
    if ts is None:
        return None
    if isinstance(ts, str):
        return ts.replace("+00:00", "Z")
    try:
        return datetime.fromtimestamp(ts, timezone.utc).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, OSError):
        return None


def _extract_usage(event: dict) -> dict:
    """Pull token usage from Anthropic-style message.usage block."""
    msg = event.get("message") or {}
    usage = msg.get("usage") or event.get("usage") or {}
    return {
        "tokens_in":   int(usage.get("input_tokens") or 0),
        "tokens_out":  int(usage.get("output_tokens") or 0),
        "cache_read":  int(usage.get("cache_read_input_tokens") or 0),
        "cache_write": int(usage.get("cache_creation_input_tokens") or 0),
    }


def _extract_model(event: dict) -> str | None:
    msg = event.get("message") or {}
    return msg.get("model") or event.get("model")


def event_to_spans(event: dict, session_id: str) -> list[_spans.Span]:
    """Translate one JSONL event into 0+ spans.

    Event types we handle:
      - "assistant" with type=message  → llm_call span + child tool_use spans
      - "user"       with type=message (tool_result) → completes tool_call span
      - "summary"                                    → ignore
    Sub-agent dispatches (Task tool) become agent_dispatch spans whose
    conversation_id is the parent's session_id; the sub-agent's own session
    file then becomes a separate chain that we ALSO parse (since it's another
    file in the projects dir), but we link them via the agent_dispatch span.
    """
    out: list[_spans.Span] = []
    etype = event.get("type")
    msg = event.get("message") or {}

    if etype == "assistant" and msg:
        # The assistant message itself = one llm_call span
        msg_id = msg.get("id") or event.get("uuid")
        if not msg_id:
            return out

        ts = _iso(event.get("timestamp"))
        usage = _extract_usage(event)
        llm_span = _spans.Span(
            span_id=str(msg_id),
            parent_span_id=event.get("parentUuid"),
            conversation_id=session_id,
            kind="llm_call",
            name="anthropic.chat",
            start_ts=ts or _spans.now_iso(),
            end_ts=ts,
            model=_extract_model(event),
            status="ok",
            **usage,
            attributes={
                "stop_reason": msg.get("stop_reason"),
                "role": "assistant",
            },
        )
        out.append(llm_span)

        # Each tool_use content block under the assistant message = a tool_call
        for block in (msg.get("content") or []):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_name = block.get("name") or "unknown"
                tool_id = block.get("id")
                if not tool_id:
                    continue
                # agent_dispatch is a special tool_call (Task tool)
                kind = "agent_dispatch" if tool_name in ("Task", "Agent") else "tool_call"
                agent_id = None
                if kind == "agent_dispatch":
                    tinput = block.get("input") or {}
                    agent_id = tinput.get("subagent_type") or tinput.get("agent_type")
                out.append(_spans.Span(
                    span_id=str(tool_id),
                    parent_span_id=str(msg_id),
                    conversation_id=session_id,
                    kind=kind,
                    name=f"tool.{tool_name}",
                    start_ts=ts or _spans.now_iso(),
                    end_ts=None,  # filled in when tool_result arrives
                    tool_name=tool_name,
                    agent_id=agent_id,
                    status="ok",
                    attributes={"tool_use_id": tool_id},
                ))
        return out

    if etype == "user" and msg:
        # Look for tool_result content blocks — they close existing tool_call spans
        for block in (msg.get("content") or []):
            if isinstance(block, dict) and block.get("type") == "tool_result":
                tool_use_id = block.get("tool_use_id")
                if not tool_use_id:
                    continue
                # We can't easily update by ID without a separate query. Caller
                # handles this by re-upserting with the closing data — but the
                # parser doesn't have the original start_ts. So we represent the
                # close as a partial-update Span and the upsert layer merges.
                # SIMPLIFICATION: emit a synthetic span with the same id and
                # end_ts only. The DB upsert will replace, but we lose tool
                # name + start_ts → not ideal.
                #
                # BETTER APPROACH: query the existing row, fill in the close
                # fields. Done in main() after collecting all events.
                ts = _iso(event.get("timestamp"))
                is_error = bool(block.get("is_error"))
                # Stash the close info; main() applies it via a second pass.
                out.append(_spans.Span(
                    span_id=str(tool_use_id),
                    parent_span_id=None,            # placeholder; merged later
                    conversation_id=session_id,
                    kind="tool_call",                # placeholder; merged later
                    name="",                          # placeholder
                    start_ts="",                      # placeholder; merged later
                    end_ts=ts,
                    status="error" if is_error else "ok",
                    error_type="tool_error" if is_error else None,
                    attributes={"_close": True, "tool_use_id": tool_use_id},
                ))
        return out

    return out


# ----------------------------------------------------------------------------
# Main parsing pass
# ----------------------------------------------------------------------------
def _session_id_for_file(path: Path) -> str:
    """The filename stem IS the session UUID by Claude Code convention."""
    return path.stem


def parse_one_file(path: Path, last_offset: int, conn) -> tuple[int, int]:
    """Parse new lines from a JSONL file, upsert spans, return (new_offset, spans_added)."""
    session_id = _session_id_for_file(path)

    # First pass: collect open spans + close events
    new_spans: list[_spans.Span] = []
    close_events: list[_spans.Span] = []
    new_offset = last_offset

    for offset, event in iter_new_lines(path, last_offset):
        new_offset = offset
        spans = event_to_spans(event, session_id)
        for s in spans:
            if s.attributes.get("_close"):
                close_events.append(s)
            else:
                new_spans.append(s)

    if not new_spans and not close_events:
        return new_offset, 0

    # Upsert new (open) spans first
    n_added = _spans.upsert_many(conn, new_spans)

    # Apply close events as targeted UPDATEs (preserves start_ts + tool_name)
    for close in close_events:
        end_ts = close.end_ts
        status = close.status
        error_type = close.error_type
        # Compute duration_ms if we know both ends
        cur = conn.execute(
            "SELECT start_ts FROM spans WHERE span_id = ?",
            (close.span_id,),
        ).fetchone()
        duration_ms = None
        if cur and cur["start_ts"]:
            try:
                start = datetime.fromisoformat(cur["start_ts"].replace("Z", "+00:00"))
                end = datetime.fromisoformat(end_ts.replace("Z", "+00:00"))
                duration_ms = int((end - start).total_seconds() * 1000)
            except Exception:
                pass
        conn.execute(
            """
            UPDATE spans
               SET end_ts      = ?,
                   duration_ms = COALESCE(?, duration_ms),
                   status      = ?,
                   error_type  = COALESCE(?, error_type)
             WHERE span_id = ?
            """,
            (end_ts, duration_ms, status, error_type, close.span_id),
        )

    return new_offset, n_added


def maybe_emit_session_span(conn, session_id: str, first_ts: str, last_ts: str) -> None:
    """Best-effort: create a parent 'session' span covering the whole file."""
    span = _spans.Span(
        span_id=f"session:{session_id}",
        parent_span_id=None,
        conversation_id=session_id,
        kind="session",
        name=f"claude-code session {session_id[:8]}",
        start_ts=first_ts,
        end_ts=last_ts,
    )
    _spans.upsert_span(conn, span)


def main() -> int:
    if not CLAUDE_PROJECTS_DIR.exists():
        print(f"[session-parser] no claude projects dir at {CLAUDE_PROJECTS_DIR} — exiting")
        return 0

    files = discover_session_files()
    if not files:
        print("[session-parser] no recent session files")
        return 0

    cursor = load_cursor()
    total_added = 0

    notable_kinds = {"agent_dispatch", "tool_call", "llm_call"}
    notable_added = 0

    with _spans.connect() as conn:
        for path in files:
            key = str(path)
            st = path.stat()
            entry = cursor.get(key, {"offset": 0, "mtime": 0.0})
            # If the file shrank (rotation, truncate), start over
            if st.st_size < entry.get("offset", 0):
                entry = {"offset": 0, "mtime": 0.0}
            new_offset, n_added = parse_one_file(path, entry["offset"], conn)
            cursor[key] = {"offset": new_offset, "mtime": st.st_mtime}
            total_added += n_added

        # Prune old data (30 day window)
        pruned = _spans.prune_older_than(conn, days=30)

        # v2.58.0: count notable spans just added (for SSE broadcast)
        if total_added > 0:
            since = _spans.iso_minus_hours(1)
            rows = conn.execute(
                "SELECT COUNT(*) AS c FROM spans WHERE start_ts >= ? AND kind IN ({})".format(
                    ",".join("?" * len(notable_kinds))
                ),
                (since, *notable_kinds),
            ).fetchone()
            notable_added = rows["c"] if rows else 0

    save_cursor(cursor)

    # v2.58.0: Best-effort audit-event post → SSE broadcast. The dashboard
    # listens for action="spans-added" and triggers a partial refresh of
    # /api/spans.json (without waiting for the 30s poll). Only post when
    # something actually changed so we don't spam subscribers.
    if total_added > 0:
        _post_audit("spans-added", target="session-parser", details={
            "total_added": total_added,
            "notable_added": notable_added,
            "files_scanned": len(files),
        })

    # Drop cursor entries for files that no longer exist
    existing = {str(p) for p in files}
    cursor = {k: v for k, v in cursor.items() if k in existing}
    save_cursor(cursor)

    print(f"[session-parser] files={len(files)} spans_added={total_added} pruned_old={pruned}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
