"""
test_conversation.py — verify the unified conversation store (v2.61.0).

The store backs chat parity between Mission Control and Telegram: both surfaces
write to + read from one SQLite db, tagged by source. These tests pin:
  - per-message append + chronological read
  - source tagging (dashboard / telegram / voice)
  - token + cost round-trip
  - clear-all
  - the API token shape the dashboard expects

_conversation.py lives in dashboard-chat/ with a {{TENANT_AGENT_HOME}}
placeholder, so we load it with the placeholder stubbed to a tmp dir.
"""
from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CONV_SRC = REPO_ROOT / "vps-setup" / "agent-template" / "dashboard-chat" / "_conversation.py"


@pytest.fixture
def conv(tmp_path):
    """Load _conversation.py with AGENT_HOME pointed at a tmp dir."""
    src = CONV_SRC.read_text().replace("{{TENANT_AGENT_HOME}}", str(tmp_path))
    mod = types.ModuleType("_conversation_test")
    mod.__file__ = str(CONV_SRC)
    exec(compile(src, str(CONV_SRC), "exec"), mod.__dict__)
    return mod


def test_append_and_read_roundtrip(conv):
    conv.append_message(role="user", source="dashboard", text="hello", request_id="r1")
    conv.append_message(role="agent", source="dashboard", text="hi there",
                        request_id="r1", tokens={"input_tokens": 10, "output_tokens": 5},
                        cost_usd=0.001, duration_ms=1200)
    msgs = conv.recent_messages(limit=10)
    assert len(msgs) == 2
    assert msgs[0]["role"] == "user" and msgs[0]["text"] == "hello"
    assert msgs[1]["role"] == "agent"
    assert msgs[1]["tokens"]["input_tokens"] == 10
    assert msgs[1]["tokens"]["output_tokens"] == 5
    assert abs(msgs[1]["cost_usd"] - 0.001) < 1e-9


def test_chronological_order(conv):
    conv.append_message(role="user", source="dashboard", text="first",
                        ts="2026-05-19T01:00:00Z")
    conv.append_message(role="user", source="dashboard", text="third",
                        ts="2026-05-19T03:00:00Z")
    conv.append_message(role="user", source="dashboard", text="second",
                        ts="2026-05-19T02:00:00Z")
    texts = [m["text"] for m in conv.recent_messages(limit=10)]
    assert texts == ["first", "second", "third"]


def test_source_tagging(conv):
    conv.append_message(role="user", source="telegram", text="from phone")
    conv.append_message(role="user", source="voice", text="spoken")
    conv.append_message(role="user", source="dashboard", text="typed")
    by_text = {m["text"]: m["source"] for m in conv.recent_messages()}
    assert by_text["from phone"] == "telegram"
    assert by_text["spoken"] == "voice"
    assert by_text["typed"] == "dashboard"


def test_invalid_source_falls_back_to_dashboard(conv):
    conv.append_message(role="user", source="carrier-pigeon", text="x")
    assert conv.recent_messages()[0]["source"] == "dashboard"


def test_invalid_role_normalizes(conv):
    conv.append_message(role="robot", source="dashboard", text="x")
    # anything not "user" becomes "agent"
    assert conv.recent_messages()[0]["role"] == "agent"


def test_attachments_roundtrip(conv):
    atts = [{"type": "image", "url": "/uploads/a.png", "name": "a.png", "mime": "image/png"}]
    conv.append_message(role="user", source="dashboard", text="see this", attachments=atts)
    m = conv.recent_messages()[0]
    assert m["attachments"] == atts


def test_clear_all(conv):
    conv.append_message(role="user", source="dashboard", text="a")
    conv.append_message(role="agent", source="dashboard", text="b")
    assert conv.message_count() == 2
    removed = conv.clear_all()
    assert removed == 2
    assert conv.message_count() == 0
    assert conv.recent_messages() == []


def test_recent_limit_respected(conv):
    for i in range(10):
        conv.append_message(role="user", source="dashboard", text=f"m{i}",
                            ts=f"2026-05-19T01:00:{i:02d}Z")
    msgs = conv.recent_messages(limit=3)
    # most-recent 3, returned chronological
    assert [m["text"] for m in msgs] == ["m7", "m8", "m9"]


def test_idempotent_by_id(conv):
    conv.append_message(role="user", source="dashboard", text="first", msg_id="fixed")
    conv.append_message(role="user", source="dashboard", text="second", msg_id="fixed")
    msgs = conv.recent_messages()
    assert len(msgs) == 1
    assert msgs[0]["text"] == "second"
