#!/usr/bin/env python3
"""
dashboard-chat / server.py — FastAPI backend that gives the mission-control
dashboard a chat surface to the same agent that runs on Telegram.

Each user message:
  1. Creates a task in the ledger (so it shows up in /tasks and the telemetry
     pipeline picks up tokens for it)
  2. Invokes `claude --print` with the agent's resumable session id so the
     conversation, memory, and tools are exactly the same as Telegram
  3. Captures token usage + Sonnet 4.6 pricing and returns it inline
  4. Appends a transcript line to history.jsonl

Bound to 127.0.0.1:8001 — nginx fronts it with HTTP basic-auth at /api/chat.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuration — render-tenant.sh substitutes the {{TENANT_*}} placeholders
# ---------------------------------------------------------------------------

TENANT_ID    = "{{TENANT_ID}}"
LINUX_USER   = "{{TENANT_LINUX_USER}}"
AGENT_HOME   = "{{TENANT_AGENT_HOME}}"
LEDGER_BIN   = f"{AGENT_HOME}/scripts/task-ledger.sh"
HISTORY_PATH = f"{AGENT_HOME}/dashboard-chat/history.jsonl"
SESSION_FILE = f"{AGENT_HOME}/dashboard-chat/session.txt"
# Auto-detect the Claude CLI so the same image works on apt-installed VPSes
# (/usr/bin/claude) and manually-installed ones (/usr/local/bin/claude).
# Override with CLAUDE_BIN env var in the systemd unit if needed.
CLAUDE_BIN   = os.environ.get("CLAUDE_BIN") or shutil.which("claude") or "/usr/local/bin/claude"

# Sonnet 4.6 pricing (USD per 1M tokens)
PRICE_INPUT       = 3.00
PRICE_OUTPUT      = 15.00
PRICE_CACHE_WRITE = 3.75
PRICE_CACHE_READ  = 0.30

UTC = timezone.utc

# Make agents/scripts importable for shared helpers (_budget, _spans, _roi, etc.)
_SCRIPTS_DIR = f"{AGENT_HOME}/scripts"
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# v2.61.0: unified conversation store lives next to this file (dashboard-chat/).
_THIS_DIR = str(Path(__file__).resolve().parent)
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)
try:
    import _conversation  # noqa: E402
except Exception:  # pragma: no cover — store is optional during early boot
    _conversation = None

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title=f"{TENANT_ID} dashboard chat", version="2.61.0")

# Same-origin in production via nginx; CORS is open for local dev only
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    message: str
    source: str = "dashboard"   # dashboard | voice — where the message originated
    attachments: list = []      # v2.64.0 — [{name, path, url, mime, is_image}, ...]


class ChatResponse(BaseModel):
    task_id: str
    request_id: str
    response: str
    tokens: dict
    cost_usd: float
    duration_seconds: float
    started_at: str
    finished_at: str


# ---------------------------------------------------------------------------
# Schema validation (v2.21.0+) — shape contract enforcement, gated.
#
# When DASHBOARD_DEBUG_VALIDATE=1 in the environment, every JSON response is
# validated against its schema before being returned. Violations are LOGGED
# (stderr + journalctl) but do NOT break the response — the goal is to surface
# drift between server output and the dashboard's expected shape, not to take
# down the chat surface.
#
# Default: off. Ships safely in v2.21.0 with zero behavior change. v2.22.0
# deploys schemas/ alongside server.py and flips it on via the systemd unit.
# ---------------------------------------------------------------------------

_VALIDATE_LOG = logging.getLogger("dashboard_chat.schema")
_SCHEMA_DIR = Path(os.environ.get("DASHBOARD_SCHEMAS_DIR") or (Path(__file__).resolve().parent / "schemas"))
_VALIDATE_ENABLED = os.environ.get("DASHBOARD_DEBUG_VALIDATE") == "1"
_SCHEMAS: dict[str, object] = {}
_VALIDATE_FN = None

def _init_validation() -> None:
    """Load schemas + jsonschema lazily. No-op on any failure (validation off)."""
    global _SCHEMAS, _VALIDATE_FN
    if not _VALIDATE_ENABLED:
        return
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        _VALIDATE_LOG.warning("DASHBOARD_DEBUG_VALIDATE=1 but jsonschema not installed — skipping")
        return
    if not _SCHEMA_DIR.is_dir():
        _VALIDATE_LOG.warning("DASHBOARD_SCHEMAS_DIR=%s does not exist — skipping", _SCHEMA_DIR)
        return
    for f in _SCHEMA_DIR.glob("*.schema.json"):
        try:
            _SCHEMAS[f.stem.replace(".schema", "")] = json.loads(f.read_text())
        except Exception as e:
            _VALIDATE_LOG.warning("failed to load %s: %s", f, e)
    _VALIDATE_FN = Draft202012Validator
    _VALIDATE_LOG.info("schema validation ON — %d schemas loaded from %s", len(_SCHEMAS), _SCHEMA_DIR)

def _validate(payload: object, schema_name: str) -> None:
    """Validate `payload` against the named schema. Log violations, don't raise."""
    if not _VALIDATE_FN or schema_name not in _SCHEMAS:
        return
    errors = list(_VALIDATE_FN(_SCHEMAS[schema_name]).iter_errors(payload))
    if errors:
        for e in errors[:3]:
            path = "/".join(str(p) for p in e.path) or "<root>"
            _VALIDATE_LOG.error("schema(%s) violation at %s: %s", schema_name, path, e.message[:200])

_init_validation()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(UTC).isoformat()


def load_session_id() -> str | None:
    p = Path(SESSION_FILE)
    if not p.exists():
        return None
    sid = p.read_text(encoding="utf-8").strip()
    return sid or None


def save_session_id(sid: str) -> None:
    p = Path(SESSION_FILE)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(sid, encoding="utf-8")


def append_history(entry: dict) -> None:
    p = Path(HISTORY_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def cost_from_usage(u: dict) -> float:
    return round(
        (u.get("input_tokens", 0)               / 1_000_000.0) * PRICE_INPUT  +
        (u.get("output_tokens", 0)              / 1_000_000.0) * PRICE_OUTPUT +
        (u.get("cache_creation_input_tokens", 0)/ 1_000_000.0) * PRICE_CACHE_WRITE +
        (u.get("cache_read_input_tokens", 0)    / 1_000_000.0) * PRICE_CACHE_READ,
        6,
    )


def create_ledger_task(summary: str) -> str:
    """Return a synthetic id for this chat turn. Returns a synthetic id.

    v2.66.0: this NO LONGER writes to the task ledger. Previously it called
    task-ledger.sh create with --loud false to stay silent, but in the live
    environment that ledger create fired a "🔧 Working on it … Tracking it"
    Telegram ping for every casual dashboard message — cross-surface noise.
    The unified conversation store (_conversation.append_message) already
    records every chat message with tokens + cost, so a separate ledger task
    is redundant. Dropping it kills the ping bulletproofly AND declutters the
    Tasks tab (chat messages aren't really tasks). The synthetic id keeps the
    /api/chat response shape (task_id) intact for the dashboard.
    """
    return f"dchat_{uuid.uuid4().hex[:12]}"


def complete_ledger_task(tid: str, summary: str) -> None:
    """No-op (v2.66.0). See create_ledger_task — chat is tracked in the
    conversation store, not the task ledger."""
    return None


# ---------------------------------------------------------------------------
# Claude invocation — uses --print and a resumable session
# ---------------------------------------------------------------------------

def invoke_claude(message: str) -> tuple[str, dict, str]:
    """Run `claude --print` and return (text_response, usage_dict, session_id)."""
    sid = load_session_id()

    # --verbose is required when --print is combined with --output-format=stream-json.
    # --include-partial-messages is a boolean flag (no value); omitting it = false.
    cmd = [
        CLAUDE_BIN, "--print", "--output-format", "stream-json", "--verbose",
        "--add-dir", AGENT_HOME,
        "--permission-mode", "acceptEdits",
    ]
    if sid:
        cmd += ["--resume", sid]

    proc = subprocess.run(
        cmd,
        input=message,
        capture_output=True,
        text=True,
        timeout=180,
    )

    text_chunks: list[str] = []
    usage = {"input_tokens": 0, "output_tokens": 0,
             "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
    new_sid: str | None = None

    if proc.stdout:
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("type") == "system" and rec.get("session_id"):
                new_sid = rec["session_id"]
            msg = rec.get("message") or {}
            if isinstance(msg, dict):
                content = msg.get("content")
                if isinstance(content, list):
                    for blk in content:
                        if isinstance(blk, dict) and blk.get("type") == "text":
                            text_chunks.append(blk.get("text") or "")
                u = msg.get("usage")
                if isinstance(u, dict):
                    for k in usage:
                        v = u.get(k)
                        if isinstance(v, int):
                            usage[k] += v

    text = "".join(text_chunks).strip()
    if not text and proc.stdout:
        # Fallback: not stream-json, treat raw stdout as the response
        text = proc.stdout.strip()
    if not text and proc.stderr:
        text = f"(no response — stderr: {proc.stderr.strip()[:400]})"

    # Approximate token counts if claude didn't surface usage
    if usage["input_tokens"] == 0 and usage["output_tokens"] == 0:
        usage["input_tokens"]  = max(1, len(message) // 4)
        usage["output_tokens"] = max(1, len(text) // 4)

    if new_sid:
        save_session_id(new_sid)

    return text, usage, (new_sid or sid or "")


def invoke_claude_streaming(message: str):
    """Generator variant of invoke_claude for v2.61.0 streaming chat.

    Yields ('delta', text_chunk) tuples as the agent generates, then a final
    ('done', {text, usage, session_id}) tuple. Uses --include-partial-messages
    so the stream-json output carries token-level text deltas, giving the
    dashboard a ChatGPT-style progressive render.
    """
    sid = load_session_id()
    cmd = [
        CLAUDE_BIN, "--print", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages",
        "--add-dir", AGENT_HOME,
        "--permission-mode", "acceptEdits",
    ]
    if sid:
        cmd += ["--resume", sid]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,  # line-buffered
    )
    # Feed the prompt then close stdin so claude knows input is complete
    try:
        proc.stdin.write(message)
        proc.stdin.close()
    except BrokenPipeError:
        pass

    text_chunks: list[str] = []
    usage = {"input_tokens": 0, "output_tokens": 0,
             "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
    new_sid: str | None = None

    for line in proc.stdout:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue

        rtype = rec.get("type")
        if rtype == "system" and rec.get("session_id"):
            new_sid = rec["session_id"]

        # Partial deltas (the streaming bit)
        if rtype == "stream_event":
            ev = rec.get("event") or {}
            if ev.get("type") == "content_block_delta":
                delta = ev.get("delta") or {}
                if delta.get("type") == "text_delta":
                    chunk = delta.get("text") or ""
                    if chunk:
                        text_chunks.append(chunk)
                        yield ("delta", chunk)
            continue

        # Final assistant message — capture usage; if we somehow missed deltas,
        # fall back to the complete text block.
        msg = rec.get("message") or {}
        if isinstance(msg, dict):
            u = msg.get("usage")
            if isinstance(u, dict):
                for k in usage:
                    v = u.get(k)
                    if isinstance(v, int):
                        usage[k] += v
            if not text_chunks:
                content = msg.get("content")
                if isinstance(content, list):
                    for blk in content:
                        if isinstance(blk, dict) and blk.get("type") == "text":
                            t = blk.get("text") or ""
                            if t:
                                text_chunks.append(t)
                                yield ("delta", t)

    proc.wait()
    text = "".join(text_chunks).strip()
    if not text:
        err = (proc.stderr.read() if proc.stderr else "") or ""
        text = f"(no response{(' — ' + err.strip()[:300]) if err.strip() else ''})"
        yield ("delta", text)

    if usage["input_tokens"] == 0 and usage["output_tokens"] == 0:
        usage["input_tokens"]  = max(1, len(message) // 4)
        usage["output_tokens"] = max(1, len(text) // 4)

    if new_sid:
        save_session_id(new_sid)

    yield ("done", {"text": text, "usage": usage, "session_id": new_sid or sid or ""})


def record_message(**kwargs) -> None:
    """Best-effort append to the unified conversation store + SSE fan-out.
    Never raises — chat must work even if the store is unavailable."""
    if _conversation is None:
        return
    try:
        stored = _conversation.append_message(**kwargs)
        # Fan out to any open dashboard tabs so the thread stays live across
        # surfaces (and, post Phase B, across Telegram too).
        _publish_event("chat-message", stored)
    except Exception as e:  # pragma: no cover
        logging.getLogger("dashboard_chat.conversation").warning("record_message failed: %s", e)


# v2.62.0 — Phase C: mirror dashboard chat to Telegram so the Telegram thread
# shows messages typed in the dashboard. Gated by env so operators who don't
# want the mirror can disable it. Passes --no-conversation-log so tg-send.sh
# does NOT tee these back into the store (they're already recorded here).
_TG_SEND = f"{AGENT_HOME}/scripts/tg-send.sh"
_MIRROR_TO_TELEGRAM = os.environ.get("MIRROR_DASHBOARD_TO_TELEGRAM", "1") != "0"


# v2.65.0: framing directive prepended to every dashboard/voice chat message.
# The dashboard chat is an INTERACTIVE surface — the agent must answer inline,
# not treat each message as dispatchable "work". Without this, the delegation-
# first operating model (background-job dispatch + loud ledger-task pings) fires
# on casual questions, creating "🔧 Working on it … Tracking it" noise in
# Telegram for a simple "what are you up to?". The backend already logs a SILENT
# task for telemetry; the agent should not log another or dispatch a job.
_DASHBOARD_CHAT_GUARD = (
    "[Interactive dashboard chat — reply directly and conversationally, right here. "
    "Do NOT create a ledger task, do NOT dispatch a background job, and do NOT send "
    "separate Telegram messages for this; the backend already logged a silent task "
    "and your reply is mirrored automatically. Only dispatch background work if I "
    "EXPLICITLY ask for something heavy or long-running (research, a build, a swarm). "
    "For questions, status checks, and chit-chat: just answer.]\n\n"
)


def build_agent_prompt(message: str, attachments: list | None, source: str = "dashboard") -> str:
    """v2.64.0: prepend attachment references so the agent can Read uploaded
    files by path (they live under AGENT_HOME, exposed via --add-dir).
    v2.65.0: also prepend the interactive-chat framing guard for dashboard/voice
    so the agent answers inline instead of dispatching/logging loudly."""
    parts: list[str] = []
    if source in ("dashboard", "voice"):
        parts.append(_DASHBOARD_CHAT_GUARD)
    atts = attachments or []
    if atts:
        lines = ["[The user attached the following file(s). Use your Read tool to view them if relevant:]"]
        for a in atts:
            if not isinstance(a, dict):
                continue
            path = a.get("path") or ""
            name = a.get("name") or os.path.basename(path)
            mime = a.get("mime") or ""
            if path:
                lines.append(f"  - {name} ({mime}): {path}")
        lines.append("")
        parts.append("\n".join(lines) + "\n")
    return "".join(parts) + message


def mirror_to_telegram(text: str, *, prefix: str = "") -> None:
    """Fire-and-forget post to Telegram. Best-effort; never blocks chat."""
    if not _MIRROR_TO_TELEGRAM or not text.strip():
        return
    if not os.path.exists(_TG_SEND):
        return
    body = (prefix + text)[:3800]  # Telegram hard-caps ~4096; leave headroom
    try:
        subprocess.Popen(
            ["bash", _TG_SEND, "send", "--text", body, "--no-conversation-log"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass  # mirror is best-effort


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/api/chat/health")
def health():
    sid = load_session_id()
    payload = {
        "ok": True,
        "tenant_id": TENANT_ID,
        "session_id": sid,
        "history_path": HISTORY_PATH,
        "claude_bin": CLAUDE_BIN,
        "claude_bin_exists": os.path.exists(CLAUDE_BIN),
        "now": now_iso(),
    }
    _validate(payload, "chat-health")
    return payload


@app.get("/api/chat/history")
def history(limit: int = 50):
    # v2.61.0: prefer the unified conversation store (per-message, source-tagged).
    # Falls back to the legacy history.jsonl (per round-trip) if the store is
    # empty or unavailable, so nothing breaks during the migration window.
    if _conversation is not None:
        try:
            msgs = _conversation.recent_messages(limit=limit)
            if msgs:
                return {"messages": msgs, "format": "unified"}
        except Exception:
            pass

    p = Path(HISTORY_PATH)
    if not p.exists():
        return {"messages": [], "format": "legacy"}
    lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
    out: list[dict] = []
    for line in lines[-limit:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    payload = {"messages": out, "format": "legacy"}
    _validate(payload, "chat-history")
    return payload


@app.delete("/api/chat/history")
def clear_history():
    """Wipe the unified conversation store (Clear history button)."""
    removed = 0
    if _conversation is not None:
        try:
            removed = _conversation.clear_all()
        except Exception:
            pass
    _append_audit(AuditEvent(action="chat-history-clear", target="conversation",
                             details={"removed": removed}, source="dashboard"))
    return {"removed": removed}


@app.post("/api/chat", response_model=ChatResponse)
def chat(req: ChatRequest):
    msg = (req.message or "").strip()
    if not msg:
        raise HTTPException(status_code=400, detail="message is required")
    if len(msg) > 12000:
        raise HTTPException(status_code=400, detail="message too long (12000 char limit)")

    request_id = uuid.uuid4().hex[:12]
    started = time.time()
    started_iso = now_iso()
    tid = create_ledger_task(f"Dashboard chat: {msg[:80]}")

    # v2.61.0: record the user message in the unified store BEFORE invoking the
    # agent, so it shows up immediately on other open surfaces.
    src = (req.source if req.source in ("dashboard", "voice") else "dashboard")
    record_message(role="user", source=src, text=msg, request_id=request_id,
                   ts=started_iso, attachments=req.attachments or [])

    try:
        # v2.64.0: include attachment refs so the agent can Read uploaded files.
        text, usage, _sid = invoke_claude(build_agent_prompt(msg, req.attachments, src))
    except subprocess.TimeoutExpired:
        complete_ledger_task(tid, "Dashboard chat — timed out")
        raise HTTPException(status_code=504, detail="claude --print timed out")
    except FileNotFoundError:
        complete_ledger_task(tid, "Dashboard chat — claude binary missing")
        raise HTTPException(status_code=500, detail=f"claude binary not found at {CLAUDE_BIN}")
    except Exception as e:
        complete_ledger_task(tid, f"Dashboard chat — error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

    duration = round(time.time() - started, 3)
    finished_iso = now_iso()
    cost = cost_from_usage(usage)

    entry = {
        "request_id": request_id,
        "task_id": tid,
        "started_at": started_iso,
        "finished_at": finished_iso,
        "duration_seconds": duration,
        "prompt": msg,
        "response": text,
        "tokens": usage,
        "cost_usd": cost,
    }
    append_history(entry)
    # v2.61.0: record the agent reply in the unified store too.
    record_message(role="agent", source=src, text=text, request_id=request_id,
                   tokens=usage, cost_usd=cost, duration_ms=int(duration * 1000),
                   ts=finished_iso)
    # v2.62.0 (Phase C): mirror the exchange to Telegram for cross-surface parity.
    mirror_to_telegram(msg, prefix="💻 (dashboard) ")
    mirror_to_telegram(text)
    complete_ledger_task(tid, f"Dashboard chat done — {usage['input_tokens']}↓/{usage['output_tokens']}↑ tok, ${cost:.4f}")

    resp = ChatResponse(
        task_id=tid,
        request_id=request_id,
        response=text,
        tokens=usage,
        cost_usd=cost,
        duration_seconds=duration,
        started_at=started_iso,
        finished_at=finished_iso,
    )
    _validate(resp.model_dump() if hasattr(resp, "model_dump") else resp.dict(), "chat-response")
    return resp


# ============================================================================
# v2.61.0 — Streaming chat (ChatGPT-style progressive render)
# ============================================================================
# POST /api/chat/stream returns a text/event-stream where each chunk is an SSE
# event: `delta` events carry token text, a final `done` event carries usage +
# cost. The frontend appends deltas to the live message bubble. Records both the
# user prompt and the agent reply to the unified conversation store.

@app.post("/api/chat/stream")
def chat_stream(req: ChatRequest):
    msg = (req.message or "").strip()
    if not msg:
        raise HTTPException(status_code=400, detail="message is required")
    if len(msg) > 12000:
        raise HTTPException(status_code=400, detail="message too long (12000 char limit)")

    request_id = uuid.uuid4().hex[:12]
    started = time.time()
    started_iso = now_iso()
    tid = create_ledger_task(f"Dashboard chat: {msg[:80]}")
    src = (req.source if req.source in ("dashboard", "voice") else "dashboard")

    # Record the user message immediately (visible on other surfaces via SSE).
    record_message(role="user", source=src, text=msg, request_id=request_id,
                   ts=started_iso, attachments=req.attachments or [])
    agent_prompt = build_agent_prompt(msg, req.attachments, src)

    def gen():
        # Opening frame so the client can flip to "streaming" state.
        yield f"event: start\ndata: {json.dumps({'request_id': request_id, 'task_id': tid})}\n\n"
        final = {"text": "", "usage": {}, "session_id": ""}
        try:
            for kind, payload in invoke_claude_streaming(agent_prompt):
                if kind == "delta":
                    yield f"event: delta\ndata: {json.dumps({'text': payload})}\n\n"
                elif kind == "done":
                    final = payload
        except Exception as e:
            yield f"event: error\ndata: {json.dumps({'detail': str(e)})}\n\n"
            complete_ledger_task(tid, f"Dashboard chat (stream) — error: {e}")
            return

        duration = round(time.time() - started, 3)
        finished_iso = now_iso()
        usage = final.get("usage") or {}
        text = final.get("text") or ""
        cost = cost_from_usage(usage)

        # Persist to legacy history.jsonl (round-trip shape) + unified store.
        append_history({
            "request_id": request_id, "task_id": tid,
            "started_at": started_iso, "finished_at": finished_iso,
            "duration_seconds": duration, "prompt": msg, "response": text,
            "tokens": usage, "cost_usd": cost,
        })
        record_message(role="agent", source=src, text=text, request_id=request_id,
                       tokens=usage, cost_usd=cost, duration_ms=int(duration * 1000),
                       ts=finished_iso)
        # v2.62.0 (Phase C): mirror the exchange to Telegram for parity.
        mirror_to_telegram(msg, prefix="💻 (dashboard) ")
        mirror_to_telegram(text)
        complete_ledger_task(tid, f"Dashboard chat (stream) done — ${cost:.4f}")

        yield ("event: done\ndata: " + json.dumps({
            "request_id": request_id, "task_id": tid, "response": text,
            "tokens": usage, "cost_usd": cost, "duration_seconds": duration,
            "started_at": started_iso, "finished_at": finished_iso,
        }) + "\n\n")

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


# ============================================================================
# v2.62.0 — Conversation ingest (Telegram → unified store)
# ============================================================================
# The Telegram channel plugin (via patch-channels-plugin.sh PASS 6) and
# tg-send.sh POST inbound/outbound Telegram messages here so they land in the
# same conversation.db the dashboard reads. This is the Telegram→Dashboard half
# of chat parity (Phase B). 127.0.0.1-only; nginx never exposes it externally
# beyond the existing basic-auth on /api/chat/*.

class IngestMessage(BaseModel):
    role: str = "user"          # user | agent
    source: str = "telegram"    # telegram | voice | system
    text: str = ""
    request_id: str | None = None
    cost_usd: float = 0.0
    duration_ms: int | None = None
    attachments: list | None = None


@app.post("/api/chat/ingest")
def post_ingest(msg: IngestMessage):
    """Append a message from another surface (Telegram, voice) to the unified
    conversation store + broadcast it on SSE so the dashboard updates live."""
    text = (msg.text or "").strip()
    if not text and not (msg.attachments or []):
        raise HTTPException(status_code=400, detail="text or attachments required")
    if len(text) > 24000:
        text = text[:24000]
    record_message(
        role=msg.role if msg.role in ("user", "agent") else "user",
        source=msg.source if msg.source in ("telegram", "voice", "system") else "telegram",
        text=text,
        request_id=msg.request_id,
        cost_usd=msg.cost_usd or 0.0,
        duration_ms=msg.duration_ms,
        attachments=msg.attachments or [],
    )
    return {"ok": True}


# ============================================================================
# v2.63.0 — Voice (Phase D): browser mic → transcribe, agent reply → TTS
# ============================================================================
# Reuses the existing whisper.cpp (voice-transcribe.sh) + edge-tts
# (voice-reply.sh) scripts built for Telegram voice notes. Both run as the
# tenant user with TENANT_USER_HOME set so whisper/edge-tts resolve their dirs.

USER_HOME = str(Path(AGENT_HOME).parent)  # /opt/<user>/agents → /opt/<user>
_VOICE_TRANSCRIBE = f"{AGENT_HOME}/scripts/voice-transcribe.sh"
_VOICE_REPLY = f"{AGENT_HOME}/scripts/voice-reply.sh"
_VOICE_ENV = {**os.environ, "TENANT_USER_HOME": USER_HOME}


@app.post("/api/chat/transcribe")
async def post_transcribe(audio: UploadFile = File(...), lang: str = "auto"):
    """Accept a browser-recorded audio blob, transcribe via whisper.cpp.
    Returns {lang, text}. ffmpeg inside voice-transcribe.sh handles whatever
    container MediaRecorder produced (webm/ogg/opus/wav)."""
    if not os.path.exists(_VOICE_TRANSCRIBE):
        raise HTTPException(status_code=503, detail="voice-transcribe.sh not installed")
    suffix = os.path.splitext(audio.filename or "")[1] or ".webm"
    tmp = Path(tempfile.gettempdir()) / f"mc-voice-{uuid.uuid4().hex[:10]}{suffix}"
    try:
        data = await audio.read()
        if not data:
            raise HTTPException(status_code=400, detail="empty audio upload")
        if len(data) > 25 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="audio too large (25MB limit)")
        tmp.write_bytes(data)
        lang_flag = lang if lang in ("auto", "en", "es", "fr", "de", "pt", "it") else "auto"
        proc = subprocess.run(
            ["bash", _VOICE_TRANSCRIBE, str(tmp), "--lang", lang_flag],
            capture_output=True, text=True, timeout=120, env=_VOICE_ENV,
        )
        if proc.returncode != 0:
            raise HTTPException(status_code=500,
                                detail=f"transcription failed: {proc.stderr.strip()[:300]}")
        out = proc.stdout.strip()
        # Output shape: "[LANG=xx] transcript text..."
        detected = lang_flag
        text = out
        m = re.match(r"^\[LANG=([a-z]{2})\]\s*(.*)$", out, re.DOTALL)
        if m:
            detected, text = m.group(1), m.group(2).strip()
        return {"lang": detected, "text": text}
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


class TTSRequest(BaseModel):
    text: str
    lang: str = "auto"


@app.post("/api/chat/tts")
def post_tts(req: TTSRequest):
    """Synthesize text → OGG/Opus via edge-tts (voice-reply.sh). Returns the
    audio bytes for inline <audio> playback in the dashboard."""
    if not os.path.exists(_VOICE_REPLY):
        raise HTTPException(status_code=503, detail="voice-reply.sh not installed")
    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    if len(text) > 4000:
        text = text[:4000]
    lang_flag = req.lang if req.lang in ("auto", "en", "es") else "auto"
    out_path = Path(tempfile.gettempdir()) / f"mc-tts-{uuid.uuid4().hex[:10]}.ogg"
    try:
        proc = subprocess.run(
            ["bash", _VOICE_REPLY, "--lang", lang_flag, "--out", str(out_path), text],
            capture_output=True, text=True, timeout=60, env=_VOICE_ENV,
        )
        if proc.returncode != 0 or not out_path.exists():
            raise HTTPException(status_code=500,
                                detail=f"TTS failed: {proc.stderr.strip()[:300]}")
        audio_bytes = out_path.read_bytes()
        return Response(content=audio_bytes, media_type="audio/ogg",
                        headers={"Cache-Control": "no-store"})
    finally:
        try:
            out_path.unlink(missing_ok=True)
        except Exception:
            pass


# ============================================================================
# v2.64.0 — File + image attachments (Phase E)
# ============================================================================
# Uploaded files land under dashboard-chat/uploads/ (inside AGENT_HOME, which
# `claude --print --add-dir AGENT_HOME` already exposes — so the agent can Read
# an uploaded image/doc by path). Each chat message carries attachment metadata
# in the unified store; the dashboard renders images inline and files as links.

UPLOADS_DIR = Path(AGENT_HOME) / "dashboard-chat" / "uploads"
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)

# Allowlisted extensions → mime. Anything else is rejected (defense in depth:
# we never want to host arbitrary executables behind basic-auth).
_UPLOAD_MIME = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
    ".pdf": "application/pdf", ".txt": "text/plain", ".md": "text/markdown",
    ".csv": "text/csv", ".json": "application/json",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".webm": "video/webm", ".mp4": "video/mp4", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
}


@app.post("/api/chat/upload")
async def post_upload(file: UploadFile = File(...)):
    """Store an uploaded file; return its metadata. The agent reads it by the
    returned `path` (inside AGENT_HOME); the dashboard renders it via `url`."""
    name = os.path.basename(file.filename or "file")
    ext = os.path.splitext(name)[1].lower()
    if ext not in _UPLOAD_MIME:
        raise HTTPException(status_code=415, detail=f"file type {ext or '?'} not allowed")
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="empty file")
    if len(data) > 30 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="file too large (30MB limit)")
    file_id = uuid.uuid4().hex[:16]
    stored = UPLOADS_DIR / f"{file_id}{ext}"
    stored.write_bytes(data)
    return {
        "id": file_id,
        "name": name,
        "mime": _UPLOAD_MIME[ext],
        "size": len(data),
        "url": f"/api/chat/upload/{file_id}{ext}",
        "path": str(stored),
        "is_image": _UPLOAD_MIME[ext].startswith("image/"),
    }


@app.get("/api/chat/upload/{filename}")
def get_upload(filename: str):
    """Serve a previously-uploaded file for inline rendering. Path-traversal
    safe — only the basename is honored and it must live in UPLOADS_DIR."""
    safe = os.path.basename(filename)
    ext = os.path.splitext(safe)[1].lower()
    if ext not in _UPLOAD_MIME:
        raise HTTPException(status_code=404, detail="not found")
    target = UPLOADS_DIR / safe
    if not target.is_file():
        raise HTTPException(status_code=404, detail="not found")
    return Response(content=target.read_bytes(), media_type=_UPLOAD_MIME[ext],
                    headers={"Cache-Control": "private, max-age=86400"})


# ============================================================================
# v2.46.0 — Audit log endpoint
# ============================================================================
# Append-only JSONL log of dashboard user actions (tab switches, snooze clicks,
# manual refreshes, etc.). Enables "what did Daniel do at 3pm last Tuesday"
# auditability + future behavioral pattern analysis.
#
# Storage: state/audit.jsonl (one event per line).
# Auth: relies on the existing nginx basic-auth in front of /api/chat/*.
# Cleanup: caller of GET /api/chat/audit can limit; no automated trim yet
# (jsonl files are tiny — ~100 bytes/event × 100 events/day × 365 = 3.6 MB/yr).

STATE_DIR = Path(AGENT_HOME) / "dashboard-chat" / "state"
STATE_DIR.mkdir(parents=True, exist_ok=True)
AUDIT_LOG = STATE_DIR / "audit.jsonl"


class AuditEvent(BaseModel):
    action: str        # tab-switch, snooze, unsnooze, refresh, click-card, etc.
    target: str = ""   # tab name, signal id, task id, etc.
    details: dict = {} # arbitrary metadata
    source: str = "dashboard"  # dashboard|telegram|cli — caller identifies


class AuditEventStored(AuditEvent):
    ts: str
    request_id: str


def _append_audit(event: AuditEvent) -> AuditEventStored:
    stored = AuditEventStored(
        ts=now_iso(),
        request_id=str(uuid.uuid4()),
        **event.model_dump() if hasattr(event, "model_dump") else event.dict(),
    )
    line = json.dumps(stored.model_dump() if hasattr(stored, "model_dump") else stored.dict())
    with AUDIT_LOG.open("a") as f:
        f.write(line + "\n")
    return stored


@app.post("/api/chat/audit", response_model=AuditEventStored)
def post_audit(event: AuditEvent):
    """Append an audit event. Returns the stored event with server-assigned ts + request_id."""
    if not event.action or len(event.action) > 100:
        raise HTTPException(status_code=400, detail="action required, max 100 chars")
    if len(event.target) > 200:
        raise HTTPException(status_code=400, detail="target max 200 chars")
    return _append_audit(event)


@app.get("/api/chat/audit")
def get_audit(limit: int = 50, action: str = "", source: str = ""):
    """Read recent audit events, most recent first. Optional filters: action prefix, source."""
    if limit < 1 or limit > 1000:
        raise HTTPException(status_code=400, detail="limit must be 1..1000")
    events = []
    if AUDIT_LOG.exists():
        with AUDIT_LOG.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if action and not d.get("action", "").startswith(action):
                    continue
                if source and d.get("source", "") != source:
                    continue
                events.append(d)
    events.reverse()
    return {
        "events": events[:limit],
        "total": len(events),
        "returned": min(limit, len(events)),
    }


# ============================================================================
# v2.46.1 — Server-side snooze sync
# ============================================================================
# Cross-device snooze persistence. Replaces (well, augments) the v2.35.0
# localStorage-only snooze with a server-backed registry. Snooze on laptop →
# visible on phone after next dashboard poll.
#
# Storage: state/snoozes.json — dict of {slot: snoozed_until_iso}. Whole-file
# read/write; bounded by ~50 slots × 50 bytes ≈ 2.5 KB so atomic write is fine.

SNOOZE_FILE = STATE_DIR / "snoozes.json"
DEFAULT_SNOOZE_SECONDS = 24 * 60 * 60  # 24 hours


def _load_snoozes():
    if not SNOOZE_FILE.exists():
        return {}
    try:
        return json.loads(SNOOZE_FILE.read_text() or "{}")
    except Exception:
        return {}


def _save_snoozes(d):
    tmp = SNOOZE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, indent=2))
    tmp.replace(SNOOZE_FILE)


def _prune_expired(d):
    """Drop expired snoozes; return {slot: iso} of active ones."""
    now = datetime.now(timezone.utc)
    out = {}
    for slot, iso in d.items():
        try:
            until = datetime.fromisoformat(iso.replace("Z", "+00:00"))
            if until > now:
                out[slot] = iso
        except Exception:
            continue
    return out


class SnoozeRequest(BaseModel):
    slot: str
    snooze_seconds: int = DEFAULT_SNOOZE_SECONDS


@app.post("/api/chat/snooze")
def post_snooze(req: SnoozeRequest):
    """Snooze a signal slot. Defaults to 24h. Returns the active snooze entry."""
    if not req.slot or len(req.slot) > 100:
        raise HTTPException(status_code=400, detail="slot required, max 100 chars")
    if req.snooze_seconds < 60 or req.snooze_seconds > 30 * 86400:
        raise HTTPException(status_code=400, detail="snooze_seconds must be 60..2592000 (30d)")
    d = _prune_expired(_load_snoozes())
    until = datetime.now(timezone.utc) + timedelta(seconds=req.snooze_seconds)
    until_iso = until.isoformat().replace("+00:00", "Z")
    d[req.slot] = until_iso
    _save_snoozes(d)
    # Also log to audit
    _append_audit(AuditEvent(action="snooze-set", target=req.slot,
                             details={"snoozed_until": until_iso, "seconds": req.snooze_seconds},
                             source="dashboard"))
    return {"slot": req.slot, "snoozed_until": until_iso, "seconds": req.snooze_seconds}


@app.delete("/api/chat/snooze")
def delete_snooze(slot: str):
    """Clear a snooze. 200 even if it didn't exist (idempotent)."""
    if not slot or len(slot) > 100:
        raise HTTPException(status_code=400, detail="slot required, max 100 chars")
    d = _prune_expired(_load_snoozes())
    existed = slot in d
    d.pop(slot, None)
    _save_snoozes(d)
    if existed:
        _append_audit(AuditEvent(action="snooze-clear", target=slot, source="dashboard"))
    return {"slot": slot, "cleared": existed}


@app.get("/api/chat/snooze")
def get_snoozes():
    """List active (not-expired) snoozes. Also writes the pruned set back to disk."""
    d = _prune_expired(_load_snoozes())
    _save_snoozes(d)  # prune-on-read keeps the file small
    return {
        "snoozes": d,
        "count": len(d),
        "generated_at": now_iso(),
    }


# ============================================================================
# v2.47.0 — Run-now buttons for Skills tab
# ============================================================================
# Lets the dashboard fire a skill / watcher / lifecycle service on demand.
# Defense in depth: backend allowlist regex + the sudoers wrapper has its own
# allowlist. The actual systemctl call is gated by /etc/sudoers.d/* which
# only permits scripts under {{TENANT_AGENT_HOME}}/scripts/ops/.
#
# This wrapper is `ops-service-restart.sh` (already exists). For oneshot
# services (every skill + watcher), restart == fire-once.

import re as _re

# Backend allowlist — matches the wrapper's allowlist. Reject upstream so
# bad requests never reach sudo.
_UNIT_ALLOWLIST_REGEX = _re.compile(
    r"^(agent-skill@[a-z0-9_-]+|"
    r"[a-z0-9_-]+-watcher|"
    r"morning-brief|evening-rollup|"
    r"dashboard-sync|telemetry-calc|deploy-timeout-sweep|"
    r"graphify-rebuild|rules-engine|anomaly-detect|session-parser|roi-digest|"
    r"claude-agent|dashboard-chat|nginx|{{TENANT_WEBSITE_SYSTEMD_SERVICE}}|"
    r"telegram-poller-watchdog)"
    r"(\.service|\.timer)?$"
)


class SkillRunRequest(BaseModel):
    unit: str
    source: str = "dashboard"


@app.post("/api/chat/skills/run")
def post_skills_run(req: SkillRunRequest):
    """Fire a skill/watcher/lifecycle service. Defense in depth: regex check
    here + the sudoers wrapper has its own allowlist. Logs an audit event
    on every invocation regardless of outcome.

    v2.57.0: also checks _budget.is_blocked() — refuses to run with 423 Locked
    if a circuit breaker is engaged for this skill or globally.
    """
    unit = req.unit.strip()
    if not unit or len(unit) > 100:
        raise HTTPException(status_code=400, detail="unit required, max 100 chars")
    if not _UNIT_ALLOWLIST_REGEX.match(unit):
        _append_audit(AuditEvent(action="skill-run-denied", target=unit,
                                 details={"reason": "regex_allowlist_miss"},
                                 source=req.source))
        raise HTTPException(status_code=403, detail=f"unit '{unit}' not in allowlist")

    # v2.57.0: budget circuit-breaker check
    try:
        import _budget  # noqa: E402
        # Strip @instance suffix for the lookup so blocks like "agent-skill@brand-drift-scanner"
        # match both per-skill and global rules. We try the unit, the basename, and __global__.
        skill_basename = unit.split("@", 1)[-1].replace(".service", "").replace(".timer", "")
        block = _budget.is_blocked(unit) or _budget.is_blocked(skill_basename)
        if block:
            _append_audit(AuditEvent(action="skill-run-blocked", target=unit,
                                     details={"reason": block.reason, "until": block.until_ts,
                                              "blocked_by": block.blocked_by},
                                     source=req.source))
            raise HTTPException(status_code=423,
                                detail=f"blocked: {block.reason} (until {block.until_ts})")
    except HTTPException:
        raise
    except Exception:
        # Fail-open: a broken budget module shouldn't stop legit skill runs.
        pass

    # Audit BEFORE invoking so we have a record even if the call hangs
    _append_audit(AuditEvent(action="skill-run-start", target=unit, source=req.source))

    try:
        # v2.47.1: --no-block returns once systemd accepts the start request
        # rather than waiting for ExecStart to complete. LLM-driven skills
        # (drift-scanner, weekly-insight, etc.) can run 30+ seconds; blocking
        # made the dashboard button time out before the skill even kicked off.
        result = subprocess.run(
            ["sudo", "-n", "{{TENANT_AGENT_HOME}}/scripts/ops/ops-service-restart.sh",
             unit, "--no-block"],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        _append_audit(AuditEvent(action="skill-run-timeout", target=unit, source=req.source))
        raise HTTPException(status_code=504, detail="systemctl start timed out")
    except Exception as e:
        _append_audit(AuditEvent(action="skill-run-error", target=unit,
                                 details={"error": str(e)}, source=req.source))
        raise HTTPException(status_code=500, detail=str(e))

    success = result.returncode == 0
    _append_audit(AuditEvent(
        action="skill-run-complete" if success else "skill-run-failed",
        target=unit,
        details={
            "returncode": result.returncode,
            "stdout_tail": result.stdout[-500:] if result.stdout else "",
            "stderr_tail": result.stderr[-500:] if result.stderr else "",
        },
        source=req.source,
    ))
    if not success:
        raise HTTPException(status_code=500,
                            detail=f"wrapper exited {result.returncode}: {result.stderr[-200:]}")
    return {
        "unit": unit,
        "started_at": now_iso(),
        "stdout_tail": result.stdout[-500:] if result.stdout else "",
    }


# ============================================================================
# Task state write-back — powers the dashboard Kanban drag-and-drop.
# ============================================================================
# Free, instant, deterministic: validates id + state then runs the canonical
# task-ledger lifecycle wrapper. No LLM call (unlike /api/chat), so dragging a
# card costs nothing and keeps the task ledger as the single source of truth.

_TASK_ID_RE = re.compile(r"^[A-Za-z0-9._\-]{1,64}$")
_TASK_STATES = {
    "queued", "committed", "in_progress", "in_review",
    "blocked", "awaiting_external", "stale", "done", "cancelled",
}
TASK_UPDATE_BIN = f"{AGENT_HOME}/scripts/task-update.sh"


class TaskStateRequest(BaseModel):
    id: str
    state: str
    source: str = "dashboard"


@app.post("/api/task/state")
def post_task_state(req: TaskStateRequest):
    """Set a task's lifecycle state (Kanban drag-and-drop). Runs
    task-update.sh ID STATE "msg" → task-ledger.sh. Deterministic + free."""
    tid = (req.id or "").strip()
    new_state = (req.state or "").strip()
    if not tid or not _TASK_ID_RE.match(tid):
        raise HTTPException(status_code=400, detail="invalid task id")
    if new_state not in _TASK_STATES:
        raise HTTPException(status_code=400, detail=f"invalid state '{new_state}'")

    _append_audit(AuditEvent(action="task-state-set", target=tid,
                             details={"state": new_state}, source=req.source))
    try:
        result = subprocess.run(
            [TASK_UPDATE_BIN, tid, new_state, "moved via dashboard kanban"],
            capture_output=True, text=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="task-update timed out")
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail=f"task-update.sh not found at {TASK_UPDATE_BIN}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    if result.returncode != 0:
        _append_audit(AuditEvent(action="task-state-failed", target=tid,
                                 details={"rc": result.returncode, "stderr": result.stderr[-300:]},
                                 source=req.source))
        raise HTTPException(status_code=500,
                            detail=f"task-update exited {result.returncode}: {result.stderr[-200:]}")
    return {"id": tid, "state": new_state, "updated_at": now_iso()}


# ============================================================================
# v2.57.0 — Cost ceilings (budget circuit breakers)
# ============================================================================
# Hard guardrails: refuse-to-run state file consulted by /api/chat/skills/run
# above. Surface here for the dashboard + Telegram /budget command + manual
# override.

class BudgetBlockRequest(BaseModel):
    skill: str
    reason: str = "manual"
    duration_hours: int = 24


@app.get("/api/chat/budget")
def get_budget():
    """List active budget blocks (with auto-expired entries already pruned)."""
    try:
        import _budget  # noqa: E402
        blocks = _budget.load_blocked()
        return {
            "blocks": [{
                "skill":      b.skill,
                "is_global":  b.is_global,
                "reason":     b.reason,
                "until_ts":   b.until_ts,
                "set_at":     b.set_at,
                "blocked_by": b.blocked_by,
            } for b in blocks],
            "count": len(blocks),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"budget module unavailable: {e}")


@app.post("/api/chat/budget")
def post_budget(req: BudgetBlockRequest):
    """Manually engage a circuit breaker. Useful for emergency kill-switch."""
    try:
        import _budget  # noqa: E402
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    skill = req.skill.strip()
    if not skill or len(skill) > 100:
        raise HTTPException(status_code=400, detail="skill required, max 100 chars")
    duration = max(1, min(int(req.duration_hours), 168))  # clamp 1h..7d
    block = _budget.block(skill, req.reason or "manual block", duration_hours=duration,
                          blocked_by="api")
    _append_audit(AuditEvent(action="budget-block-set", target=skill,
                             details={"reason": block.reason, "until_ts": block.until_ts,
                                      "duration_hours": duration},
                             source="dashboard"))
    return {"skill": block.skill, "until_ts": block.until_ts, "reason": block.reason}


@app.delete("/api/chat/budget")
def delete_budget(skill: str):
    """Clear a specific block (use skill=__global__ for the kill-switch)."""
    try:
        import _budget  # noqa: E402
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    removed = _budget.unblock(skill)
    _append_audit(AuditEvent(action="budget-block-clear", target=skill,
                             details={"removed": removed}, source="dashboard"))
    return {"skill": skill, "removed": removed}


# ============================================================================
# v2.48.0 — Behavioral rules engine (read-only view + manual trigger)
# ============================================================================
# The rules engine runs as its own systemd-timed service (rules-engine.timer
# every 5 min). This endpoint just surfaces its state for the dashboard:
#   - List of loaded rules (from rules/*.yaml)
#   - Per-rule state from state/rules-engine.json (last_evaluated, last_fired,
#     fire_count, last_matched)

RULES_DIR = Path(AGENT_HOME) / "rules"
RULES_STATE_FILE = STATE_DIR / "rules-engine.json"


@app.get("/api/chat/rules")
def get_rules():
    """List rules + their current state."""
    rules = []
    if RULES_DIR.exists():
        try:
            import yaml  # type: ignore
        except ImportError:
            raise HTTPException(status_code=500, detail="PyYAML not installed")
        for f in sorted(RULES_DIR.glob("*.yaml")):
            try:
                d = yaml.safe_load(f.read_text())
                if not isinstance(d, dict) or "name" not in d:
                    continue
                rules.append({
                    "name": d.get("name"),
                    "description": d.get("description", ""),
                    "enabled": d.get("enabled", False),
                    "filename": f.name,
                    "when_count": len(d.get("when", [])),
                    "then_count": len(d.get("then", [])),
                    "throttle_minutes": d.get("throttle_minutes", 1440),
                })
            except Exception:
                continue

    state = {}
    if RULES_STATE_FILE.exists():
        try:
            state = json.loads(RULES_STATE_FILE.read_text() or "{}")
        except Exception:
            state = {}

    # Merge state into each rule
    for r in rules:
        s = state.get(r["name"], {})
        r["last_evaluated"] = s.get("last_evaluated_iso", "")
        r["last_fired"] = s.get("last_fired_iso", "")
        r["fire_count"] = s.get("fire_count", 0)
        r["last_matched"] = s.get("last_matched", False)

    return {
        "rules": rules,
        "total": len(rules),
        "enabled_count": sum(1 for r in rules if r["enabled"]),
        "generated_at": now_iso(),
    }


@app.post("/api/chat/rules/run")
def post_rules_run():
    """Trigger an immediate rules-engine evaluation (out-of-band from the timer)."""
    _append_audit(AuditEvent(action="rules-run-manual", target="rules-engine", source="dashboard"))
    try:
        result = subprocess.run(
            ["sudo", "-n", "{{TENANT_AGENT_HOME}}/scripts/ops/ops-service-restart.sh",
             "rules-engine.service", "--no-block"],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="rules-engine start timed out")
    if result.returncode != 0:
        raise HTTPException(status_code=500,
                            detail=f"wrapper exited {result.returncode}: {result.stderr[-200:]}")
    return {"started_at": now_iso(), "stdout_tail": result.stdout[-300:] if result.stdout else ""}


# ============================================================================
# v2.51.0 — Server-Sent Events push channel (/api/chat/events)
# ============================================================================
# In-process pub/sub backed by asyncio.Queue per subscriber. Events published
# when audit entries are written; dashboard subscribes via EventSource and
# updates its in-memory state immediately rather than waiting for the next
# 30s poll. Polling stays as fallback: if SSE drops, the dashboard's existing
# 30s refresh fills the gap.
#
# nginx must be configured with `proxy_buffering off` for this location for
# events to actually stream (default buffering holds the response until full).

import asyncio
from contextlib import suppress

# In-process pub/sub. Each connected SSE client gets a Queue. Events are
# dropped silently if a client's queue fills (slow consumer / disconnected
# client) — backpressure rather than memory growth.
_EVENT_SUBSCRIBERS: set[asyncio.Queue] = set()
_EVENT_QUEUE_MAXSIZE = 100


def _publish_event(event_type: str, payload: dict) -> None:
    """Synchronously enqueue an event for all current SSE subscribers.
    Safe to call from sync code paths (FastAPI route handlers). Dropped
    silently for slow consumers."""
    if not _EVENT_SUBSCRIBERS:
        return
    msg = {
        "type": event_type,
        "ts": now_iso(),
        "payload": payload,
    }
    # Snapshot the set since put_nowait could fire callbacks. Best-effort
    # delivery — slow consumers get their oldest event dropped, not their queue.
    for q in list(_EVENT_SUBSCRIBERS):
        try:
            q.put_nowait(msg)
        except asyncio.QueueFull:
            # Drop the oldest event for this slow consumer rather than block
            with suppress(asyncio.QueueEmpty):
                q.get_nowait()
            with suppress(asyncio.QueueFull):
                q.put_nowait(msg)


# Hook into the existing audit append so every audit event also fans out
# to SSE subscribers. _append_audit is defined earlier in the file.
_original_append_audit = _append_audit


def _append_audit(event: AuditEvent) -> AuditEventStored:  # type: ignore[no-redef]
    stored = _original_append_audit(event)
    payload = stored.model_dump() if hasattr(stored, "model_dump") else stored.dict()
    _publish_event("audit", payload)
    return stored


async def _sse_stream(request):
    """Yield SSE-formatted events for one subscriber until they disconnect."""
    q: asyncio.Queue = asyncio.Queue(maxsize=_EVENT_QUEUE_MAXSIZE)
    _EVENT_SUBSCRIBERS.add(q)

    # Tell the client we're ready (helps frontend transition from polling
    # fallback to live mode quickly).
    yield f": connected at {now_iso()}\n\n"
    yield f"event: hello\ndata: {json.dumps({'ts': now_iso(), 'subscribers': len(_EVENT_SUBSCRIBERS)})}\n\n"

    try:
        while True:
            # Periodic heartbeat keeps proxies from killing the connection
            # and lets the client detect a silent drop.
            try:
                msg = await asyncio.wait_for(q.get(), timeout=20.0)
            except asyncio.TimeoutError:
                yield ": heartbeat\n\n"
                continue

            yield f"event: {msg['type']}\ndata: {json.dumps(msg)}\n\n"
    except asyncio.CancelledError:
        # Client disconnected. Clean up.
        raise
    finally:
        _EVENT_SUBSCRIBERS.discard(q)


@app.get("/api/chat/events")
async def get_events(request: Request) -> StreamingResponse:  # noqa: F821 (Request below)
    """SSE stream — pushes audit events (and future event types) as they happen."""
    return StreamingResponse(
        _sse_stream(request),
        media_type="text/event-stream",
        headers={
            # Standard SSE no-cache directives + nginx hint
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",  # nginx-specific: disable response buffering
            "Connection": "keep-alive",
        },
    )


@app.get("/api/chat/events/status")
def get_events_status():
    """Lightweight readiness probe — returns subscriber count without opening a stream."""
    return {
        "subscribers": len(_EVENT_SUBSCRIBERS),
        "queue_maxsize": _EVENT_QUEUE_MAXSIZE,
        "now": now_iso(),
    }
