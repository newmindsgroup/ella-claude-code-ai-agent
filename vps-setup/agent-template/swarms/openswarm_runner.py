#!/usr/bin/env python3
"""Headless runner for VRSEN/OpenSwarm agents.

Invokes the OpenSwarm agency with a task string, captures the result,
saves it to drafts/, and notifies via Telegram + task ledger.

Usage:
    python3 openswarm_runner.py --task "Create a slides deck about AI brand voice" \
        --agent slides --task-id t-XXXXXXXX
"""
import argparse
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

AGENT_HOME = Path(os.environ.get("TENANT_AGENT_HOME", "{{TENANT_AGENT_HOME}}"))
OPENSWARM_DIR = Path(os.environ.get("OPENSWARM_DIR", AGENT_HOME / "openswarm-repo"))
SCRIPTS = AGENT_HOME / "scripts"
DRAFTS = AGENT_HOME / "drafts" / "openswarm"
DRAFTS.mkdir(parents=True, exist_ok=True)

sys.path.insert(0, str(OPENSWARM_DIR))

AGENT_HINTS = {
    "slides":    "Create a slides presentation for",
    "docs":      "Create a document about",
    "data":      "Analyze data and produce a summary for",
    "research":  "Do deep research on",
    "video":     "Generate a video about",
    "image":     "Generate an image for",
    "assistant": "Help with",
    "orchestrator": "",
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tg_send(text: str):
    subprocess.run(
        ["bash", str(SCRIPTS / "tg-send.sh"), "send", "--md", "--text", text],
        capture_output=True,
    )


def task_update(task_id: str, state: str, msg: str):
    if task_id:
        subprocess.run(
            ["bash", str(SCRIPTS / "task-update.sh"), task_id, state, msg],
            capture_output=True,
        )


def run_openswarm_task(task: str, agent_hint: str, task_id: str) -> str:
    """Run a task through the OpenSwarm agency and return the result."""
    import dotenv
    dotenv.load_dotenv(AGENT_HOME / ".env")

    # Apply OpenSwarm patches
    sys.path.insert(0, str(OPENSWARM_DIR))
    from patches.patch_utf8_file_reads import apply_utf8_file_read_patch
    from patches.patch_agency_swarm_dual_comms import apply_dual_comms_patch
    from patches.patch_file_attachment_refs import apply_file_attachment_reference_patch

    apply_utf8_file_read_patch()
    apply_dual_comms_patch()
    apply_file_attachment_reference_patch()

    # Disable tracing (no OpenAI key needed for tracing)
    from agents import set_tracing_disabled
    set_tracing_disabled(True)

    from swarm import create_agency

    task_update(task_id, "in_progress", f"OpenSwarm agency initializing — agent hint: {agent_hint}")

    agency = create_agency()

    # Route to orchestrator — it will hand off to the right specialist
    prefix = AGENT_HINTS.get(agent_hint, "")
    full_task = f"{prefix} {task}".strip() if prefix else task

    tg_send(f"⚙️ *OpenSwarm* — running `{agent_hint}` agent\\.\\.\\.")

    result = agency.get_completion(
        message=full_task,
        recipient_agent=agency.ceo,
    )

    return result or ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", required=True, help="Task description")
    parser.add_argument("--agent", default="orchestrator",
                        choices=list(AGENT_HINTS.keys()),
                        help="Agent type hint")
    parser.add_argument("--task-id", default="", help="Task ledger ID")
    args = parser.parse_args()

    task_id = args.task_id
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    out_file = DRAFTS / f"{args.agent}-{ts}.md"

    try:
        result = run_openswarm_task(args.task, args.agent, task_id)

        # Save result
        out_file.write_text(
            f"# OpenSwarm — {args.agent} — {now_iso()}\n\n"
            f"**Task:** {args.task}\n\n"
            f"---\n\n{result}\n",
            encoding="utf-8",
        )

        task_update(task_id, "awaiting_review", f"Result saved: {out_file}")
        tg_send(
            f"✅ *OpenSwarm `{args.agent}` done*\n"
            f"_Task:_ {args.task[:80]}\n"
            f"_Saved:_ `{out_file}`"
        )
        print(result)

    except Exception as e:
        err = str(e)[:200]
        task_update(task_id, "blocked", f"OpenSwarm error: {err}")
        tg_send(f"🚧 *OpenSwarm blocked* — `{args.agent}`\n_Error:_ {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
