#!/usr/bin/env python3
"""
brief-summary.py — generate the 1–3 sentence Overview brief strip.

Runs on a schedule (05:00 + 19:00 in tenant TZ) and on demand from the
dashboard's refresh button. Writes state/brief-summary-latest.json which
dashboard-sync.sh copies to /api/brief.json.

Design tenets (see vps-setup/design/overview-wave-1-brief-strip.md):
  - Real data or honest empty, never placeholder.
  - Use ONLY existing state files; if a file is missing or empty,
    silently omit that input from the prompt — never synthesize.
  - Hard cap 240 chars on output.
  - Chief-of-staff voice, second person, names {{TENANT_PERSON_FIRST_NAME}}
    directly. Honest about uncertainty. No fluff.

Cost: uses `claude --print` (CLI, not API) — effectively free.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

AGENT_HOME = Path("{{TENANT_AGENT_HOME}}")
USER_HOME = Path("{{TENANT_USER_HOME}}")
TENANT_NAME = "{{TENANT_PERSON_FIRST_NAME}}"

STATE_DIR = AGENT_HOME / "state"
STATE_DIR.mkdir(parents=True, exist_ok=True)

OUT_PATH = STATE_DIR / "brief-summary-latest.json"
FRUGAL_FLAG = STATE_DIR / "frugal-mode"

# Real state files this script may read. If a file is missing, the
# corresponding section is omitted from the LLM prompt entirely — no
# placeholders, no synthesis.
INPUTS = {
    "cost_today": STATE_DIR / "cost-today.json",
    "spend_guard": STATE_DIR / "spend-guard.json",
    "roi_digest": STATE_DIR / "roi-digest-latest.json",
    "tasks_active": AGENT_HOME / "tasks" / "active.json",
    "goals_active": AGENT_HOME / "goals" / "active.json",
}

HARD_CHAR_CAP = 240


# ── helpers ────────────────────────────────────────────────────────────────


def read_json(path: Path):
    """Read a JSON file; return None if missing, empty, or unparseable."""
    try:
        if not path.exists():
            return None
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            return None
        return json.loads(text)
    except (OSError, json.JSONDecodeError):
        return None


def truncate_to_cap(text: str, cap: int = HARD_CHAR_CAP) -> str:
    """Truncate at the last sentence boundary that fits the cap."""
    text = text.strip()
    if len(text) <= cap:
        return text
    cut = text[:cap]
    # Prefer the last sentence terminator inside the cap.
    m = re.search(r"^.*[.!?](?=[^.!?]*$)", cut, re.DOTALL)
    if m:
        return m.group(0).strip()
    # Fallback: cut at last whitespace inside the cap.
    sp = cut.rfind(" ")
    if sp > cap * 0.6:
        return cut[:sp].rstrip(",;:") + "."
    return cut.rstrip(",;:") + "…"


def summarize_tasks(data) -> dict | None:
    if not isinstance(data, dict) or not data:
        return None
    tasks = list(data.values()) if isinstance(data, dict) else []
    open_count = sum(1 for t in tasks if t.get("state") not in ("completed", "cancelled"))
    blocked = sum(1 for t in tasks if t.get("state") == "blocked")
    awaiting = sum(1 for t in tasks if t.get("state") == "in_review")
    stale = sum(1 for t in tasks if t.get("state") == "stale")
    if open_count == 0 and blocked == 0 and awaiting == 0 and stale == 0:
        return None
    return {
        "open": open_count,
        "blocked": blocked,
        "awaiting_you": awaiting,
        "stale": stale,
    }


def summarize_goals(data) -> dict | None:
    if not isinstance(data, dict) or not data:
        return None
    goals = list(data.values()) if isinstance(data, dict) else []
    active = [g for g in goals if g.get("state") not in ("achieved", "abandoned")]
    if not active:
        return None
    on_track = sum(1 for g in active if (g.get("pace_pct") or 100) >= 80)
    behind = len(active) - on_track
    return {
        "active": len(active),
        "on_track": on_track,
        "behind": behind,
    }


def build_prompt_inputs() -> dict:
    """Read only-real inputs. Omit anything missing/empty/zero-sum."""
    inputs: dict = {}
    cost = read_json(INPUTS["cost_today"])
    if isinstance(cost, dict) and cost.get("today_usd") is not None:
        inputs["cost_today"] = {
            "today_usd": cost.get("today_usd"),
            "week_avg_usd": cost.get("baseline_week_avg_usd"),
            "spike_ratio": cost.get("spike_ratio"),
            "is_spike": cost.get("is_spike"),
            "cache_hit_ratio": cost.get("cache_hit_ratio"),
            "headline_cost_usd": cost.get("headline_cost_usd"),
        }

    sg = read_json(INPUTS["spend_guard"])
    if isinstance(sg, dict) and sg.get("ceiling_usd"):
        inputs["spend_guard"] = {
            "ceiling_usd": sg.get("ceiling_usd"),
            "spent_usd": sg.get("spent_usd"),
            "pct_of_ceiling": sg.get("pct_of_ceiling"),
            "frugal_mode": sg.get("frugal_mode", False),
        }

    roi = read_json(INPUTS["roi_digest"])
    if isinstance(roi, dict) and roi.get("week_value_usd") is not None:
        inputs["roi_week"] = {
            "value_usd": roi.get("week_value_usd"),
            "cost_usd": roi.get("week_cost_usd"),
            "roi_multiple": roi.get("week_roi_multiple"),
        }

    tasks = summarize_tasks(read_json(INPUTS["tasks_active"]))
    if tasks:
        inputs["tasks"] = tasks

    goals = summarize_goals(read_json(INPUTS["goals_active"]))
    if goals:
        inputs["goals"] = goals

    return inputs


def has_high_priority(inputs: dict) -> bool:
    """High-priority = something the user should look at TODAY."""
    t = inputs.get("tasks") or {}
    if t.get("blocked") and int(t.get("blocked")) > 0:
        return True
    if t.get("awaiting_you") and int(t.get("awaiting_you")) > 0:
        return True
    c = inputs.get("cost_today") or {}
    if c.get("is_spike"):
        return True
    g = inputs.get("goals") or {}
    if g.get("behind") and int(g.get("behind")) >= 2:
        return True
    return False


# ── LLM call ───────────────────────────────────────────────────────────────


SYSTEM_PROMPT = """You are a chief-of-staff briefing TENANT_NAME's day. You write
a SINGLE block of 1–3 sentences, HARD MAX 240 characters. Second person.
Name TENANT_NAME directly when natural. Chief-of-staff voice — direct, honest,
no fluff, no hedging language.

ABSOLUTE RULE: use ONLY the fields present in the JSON input. If a field
is missing, do NOT mention that topic at all. NEVER invent numbers, NEVER
say things like "N/A" or "0 tasks blocked" as filler. If the input JSON
is mostly empty, write a single honest line like "Quiet day so far —
nothing needs your attention."

BANNED phrases (these read as AI-generated): "thrilled to", "excited to
share", "in today's fast-paced world", "humbled to", "delve into",
"in the realm of", "moreover", "furthermore", "it's worth noting".

Voice DNA: direct, empathetic, clarity over cleverness, brevity over
flourish. Cut the lead, get to the point. Lowercase em dashes are fine.

Format guide:
  - Sentence 1 (required): the headline — what stands out today.
  - Sentence 2 (optional): the one decision or action that matters.
  - Sentence 3 (optional): a quiet positive or quiet warning.

Output ONLY the brief text. No JSON, no markdown, no labels, no
explanation. Just the prose."""


def call_claude(inputs: dict) -> str | None:
    claude = shutil.which("claude")
    if not claude:
        print("brief-summary: claude CLI not on PATH", file=sys.stderr)
        return None

    prompt = (
        SYSTEM_PROMPT.replace("TENANT_NAME", TENANT_NAME)
        + "\n\nINPUT JSON (real data only):\n"
        + json.dumps(inputs, indent=2)
        + "\n\nWrite the brief now (max 240 chars):"
    )

    try:
        result = subprocess.run(
            [claude, "--print", "--dangerously-skip-permissions"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, "HOME": str(USER_HOME)},
        )
    except subprocess.TimeoutExpired:
        print("brief-summary: claude --print timed out (60s)", file=sys.stderr)
        return None

    if result.returncode != 0:
        print(f"brief-summary: claude --print failed: {result.stderr[:300]}", file=sys.stderr)
        return None

    out = result.stdout.strip()
    if not out:
        return None
    # Strip surrounding quotes if model added them
    if (out.startswith('"') and out.endswith('"')) or (
        out.startswith("'") and out.endswith("'")
    ):
        out = out[1:-1].strip()
    return truncate_to_cap(out)


# ── main ───────────────────────────────────────────────────────────────────


def main(argv: list[str]) -> int:
    source = "scheduled"
    if "--source=on_demand" in argv:
        source = "on_demand"

    # Frugal mode: skip LLM, keep last cached if present.
    if FRUGAL_FLAG.exists():
        if OUT_PATH.exists():
            print("brief-summary: frugal mode — keeping last cached", file=sys.stderr)
            return 0
        # No cache to keep AND frugal — write a minimal honest record so
        # the dashboard shows the frugal empty state with a timestamp.
        OUT_PATH.write_text(
            json.dumps(
                {
                    "summary": None,
                    "generated_at": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "source": "frugal_mode_skip",
                    "high_priority": False,
                    "stale_after_hours": 6,
                },
                indent=2,
            )
            + "\n"
        )
        return 0

    inputs = build_prompt_inputs()

    # Quiet-world special case: NO real inputs at all. We still write a
    # record (with summary set to the honest line) so dashboard shows
    # something real instead of "never generated".
    if not inputs:
        OUT_PATH.write_text(
            json.dumps(
                {
                    "summary": f"Quiet day so far, {TENANT_NAME} — nothing needs your attention.",
                    "generated_at": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "source": source,
                    "high_priority": False,
                    "stale_after_hours": 6,
                },
                indent=2,
            )
            + "\n"
        )
        print("brief-summary: wrote quiet-day summary (no real inputs)")
        return 0

    summary = call_claude(inputs)
    if not summary:
        # LLM error — don't overwrite a good cached brief. Exit non-zero
        # so systemd marks the run failed and the dashboard's error
        # state can surface (we still keep the cached brief).
        print("brief-summary: LLM call failed — keeping last cached", file=sys.stderr)
        return 2

    record = {
        "summary": summary,
        "generated_at": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": source,
        "high_priority": has_high_priority(inputs),
        "stale_after_hours": 6,
    }
    OUT_PATH.write_text(json.dumps(record, indent=2) + "\n")
    print(f"brief-summary: wrote {len(summary)}-char summary "
          f"(high_priority={record['high_priority']}, source={source})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
