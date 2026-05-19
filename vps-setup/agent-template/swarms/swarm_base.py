#!/usr/bin/env python3
"""Swarm base utilities — shared across all swarm orchestrators.

Each swarm is a multi-agent pipeline:
  brief → agent_1 → agent_2 → ... → assembled_output → Telegram + GHL staging

Agents run via `claude --print` (OAuth, no API key needed).
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AGENT_HOME = Path(os.environ.get("TENANT_AGENT_HOME", "{{TENANT_AGENT_HOME}}"))
SCRIPTS = AGENT_HOME / "scripts"
DRAFTS = AGENT_HOME / "drafts"
LOGS = AGENT_HOME / "logs"
LOGS.mkdir(exist_ok=True)

CLAUDE_MODEL_FAST = "claude-haiku-4-5-20251001"
CLAUDE_MODEL_MAIN = "claude-sonnet-4-6"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(swarm_name: str, msg: str) -> None:
    log_path = LOGS / f"swarm-{swarm_name}.log"
    line = f"[{now_iso()}] {msg}\n"
    with open(log_path, "a") as f:
        f.write(line)
    print(line, end="", file=sys.stderr)


def run_agent(
    prompt: str,
    model: str = CLAUDE_MODEL_MAIN,
    max_tokens: int = 4000,
    system: str | None = None,
    timeout: int = 120,
) -> str:
    """Run a single claude --print agent call and return the response text."""
    cmd = [
        "claude",
        "--model", model,
        "--print",
    ]
    if system:
        # Pass system prompt via stdin prefixing
        full_prompt = f"<system>\n{system}\n</system>\n\n{prompt}"
    else:
        full_prompt = prompt

    result = subprocess.run(
        cmd,
        input=full_prompt,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(f"claude exited {result.returncode}: {result.stderr[:200]}")
    return result.stdout.strip()


def run_agent_json(
    prompt: str,
    model: str = CLAUDE_MODEL_MAIN,
    max_tokens: int = 2000,
    system: str | None = None,
    timeout: int = 90,
) -> dict | list:
    """Run an agent that must return JSON. Strips markdown fences, validates."""
    raw = run_agent(prompt, model=model, max_tokens=max_tokens, system=system, timeout=timeout)
    # Strip markdown code fences
    raw = re.sub(r"^```(?:json)?\s*", "", raw.strip(), flags=re.MULTILINE)
    raw = re.sub(r"\s*```$", "", raw.strip(), flags=re.MULTILINE)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Try to extract JSON from within the text
        m = re.search(r"\{.*\}", raw, re.DOTALL)
        if m:
            return json.loads(m.group())
        m = re.search(r"\[.*\]", raw, re.DOTALL)
        if m:
            return json.loads(m.group())
        raise ValueError(f"Agent did not return valid JSON: {raw[:200]}")


def recall_memories(query: str = "", tags: str = "", limit: int = 5) -> list[dict]:
    """Query the memory vault for relevant context."""
    cmd = ["bash", str(SCRIPTS / "memory-vault.sh"), "recall", "--limit", str(limit)]
    if query:
        cmd += ["--query", query]
    if tags:
        cmd += ["--tags", tags]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if result.returncode == 0 and result.stdout.strip():
        try:
            return json.loads(result.stdout)
        except Exception:
            pass
    return []


def save_memory(type_: str, text: str, tags: str, source: str, confidence: float = 0.85) -> str:
    """Save a memory to the vault. Returns the new memory ID."""
    result = subprocess.run(
        ["bash", str(SCRIPTS / "memory-vault.sh"), "add",
         "--type", type_, "--text", text, "--tags", tags,
         "--source", source, "--confidence", str(confidence)],
        capture_output=True, text=True, timeout=15,
    )
    return result.stdout.strip()


def update_task(task_id: str, state: str, note: str) -> None:
    """Update the task ledger state."""
    subprocess.run(
        ["bash", str(SCRIPTS / "task-update.sh"), task_id, state, note],
        capture_output=True, timeout=10,
    )


def tg_send(text: str, callback_buttons: str | None = None) -> None:
    """Send a Telegram message."""
    cmd = ["bash", str(SCRIPTS / "tg-send.sh"), "send", "--md", "--text", text]
    if callback_buttons:
        cmd += ["--callback-buttons", callback_buttons]
    subprocess.run(cmd, capture_output=True, timeout=15)


def save_draft(swarm_name: str, filename: str, content: str) -> Path:
    """Save draft output to the drafts directory. Returns the path."""
    draft_dir = DRAFTS / swarm_name
    draft_dir.mkdir(parents=True, exist_ok=True)
    path = draft_dir / filename
    path.write_text(content)
    return path


def read_brand_voice() -> str:
    """Read the Voice DNA section from brand canon for injection into prompts."""
    canon_dir = AGENT_HOME / "daniel-personal-brand"
    playbook = canon_dir / "15_Brand_Behavior_Playbook.md"
    if not playbook.exists():
        return ""
    text = playbook.read_text()
    # Extract section 7 (Voice DNA)
    m = re.search(r"(## (?:Section )?7[^#]{500,}?)(?=\n## |\Z)", text, re.DOTALL | re.IGNORECASE)
    if m:
        return m.group(1)[:3000]
    # Fallback: first 2000 chars of the doc
    return text[:2000]
