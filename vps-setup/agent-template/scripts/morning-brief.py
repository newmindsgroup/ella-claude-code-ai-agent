#!/usr/bin/env python3
"""
morning-brief.py — {{TENANT_PERSON_FIRST_NAME}} daily morning brief generator.

Produces a single richly-formatted Telegram HTML message in the style of
Ella's structured briefing, sourced from local agent state + light external
calls. Designed to be invoked by morning-brief.service (systemd timer at
{{TENANT_MORNING_BRIEF_TIME}} {{TENANT_TIMEZONE}}) but is safely re-runnable on demand.

Sections:
  1. Greeting + date
  2. Weather (Open-Meteo)
  3. Verse of the Day (bible-api.com)
  4. Agent Status (.claude/agents/, .claude/skills/)
  5. Today's Priorities (LLM-composed via claude --print)
  6. Pending / Ready to Complete (drafts/)
  7. Goal Progress (goals/active.json)
  8. Upcoming Deadlines (tasks/active.json)
  9. Daily Insight (LLM)
  10. Inline keyboard buttons

Voice rules from the brand playbook are enforced in the LLM prompt and as
a post-render banned-phrase strip.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

# ── Configuration (rendered from tenant.yml) ────────────────────────────────

AGENT_HOME = Path("{{TENANT_AGENT_HOME}}")
USER_HOME = Path("{{TENANT_USER_HOME}}")
CLAUDE_HOME = USER_HOME / ".claude"

TASKS_PATH = AGENT_HOME / "tasks" / "active.json"
GOALS_PATH = AGENT_HOME / "goals" / "active.json"
DRAFTS_DIR = AGENT_HOME / "drafts"
PROJECT_AGENTS_DIR = AGENT_HOME / ".claude" / "agents"
USER_SKILLS_DIR = CLAUDE_HOME / "skills"

TG_ENV = CLAUDE_HOME / "channels" / "telegram" / ".env"
TG_ACCESS = CLAUDE_HOME / "channels" / "telegram" / "access.json"

LOG_DIR = AGENT_HOME / "logs"
PROPOSALS_DIR = AGENT_HOME / "proposals"
PROPOSALS_REJECTED_LOG = PROPOSALS_DIR / "rejected.jsonl"
PROPOSALS_EXECUTED_LOG = PROPOSALS_DIR / "executed.jsonl"
TZ = ZoneInfo("{{TENANT_TIMEZONE}}")
DATE_STR = datetime.now(TZ).strftime("%Y-%m-%d")
LOG_FILE = LOG_DIR / f"morning-brief-{DATE_STR}.log"
PROPOSALS_PATH = PROPOSALS_DIR / f"{DATE_STR}.json"

# Weather coordinates from tenant.yml — Open-Meteo current weather endpoint.
WEATHER_LAT = {{TENANT_WEATHER_LAT}}
WEATHER_LON = {{TENANT_WEATHER_LON}}
WEATHER_LABEL = "{{TENANT_WEATHER_LABEL}}"

OWNER_NAME = "{{TENANT_PERSON_FIRST_NAME}}"

# Banned phrases — sourced from tenant.yml voice_banned_phrases. Hardcoded
# here because Python config-loading at boot is excess for a known-stable list.
BANNED_PHRASES = [
    "thrilled to",
    "excited to share",
    "in today's fast-paced world",
    "humbled to",
    "delve into",
    "in the realm of",
]

# Quick action button targets. Use URL buttons only — callback handling
# requires extending the Telegram bot; URL buttons work today.
QUICK_ACTIONS = [
    {"text": "📋 Tasks",     "url": "https://ella.{{TENANT_BRAND_REPO_NAME}}.com/"},
    {"text": "🎯 Goals",     "url": "https://ella.{{TENANT_BRAND_REPO_NAME}}.com/"},
    {"text": "📊 Dashboard", "url": "https://blueprint.{{TENANT_BRAND_REPO_NAME}}.com/"},
    {"text": "📨 Email",     "url": "https://mail.google.com/mail/u/0/#inbox"},
]

# ── Logging ─────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}\n"
    with LOG_FILE.open("a") as f:
        f.write(line)
    sys.stderr.write(line)


# ── HTML helpers (Telegram parse_mode=HTML) ─────────────────────────────────

def esc(text: str) -> str:
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def progress_bar(pct: float, width: int = 12) -> str:
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / (100.0 / width))
    return "█" * filled + "░" * (width - filled) + f" {round(pct)}%"


def blockquote(title: str, body: str) -> str:
    return f"<blockquote><b>{title}</b>\n{body}</blockquote>"


def strip_banned(text: str) -> str:
    out = text
    for phrase in BANNED_PHRASES:
        out = re.sub(re.escape(phrase), "[redacted]", out, flags=re.IGNORECASE)
    return out


# ── Section: weather (Open-Meteo) ───────────────────────────────────────────

WEATHER_CODES: dict[int, tuple[str, str]] = {
    0:  ("Clear",                "☀️"),
    1:  ("Mainly clear",         "🌤️"),
    2:  ("Partly cloudy",        "⛅"),
    3:  ("Cloudy",               "☁️"),
    45: ("Fog",                  "🌫️"),
    48: ("Rime fog",             "🌫️"),
    51: ("Light drizzle",        "🌦️"),
    53: ("Drizzle",              "🌦️"),
    55: ("Heavy drizzle",        "🌧️"),
    61: ("Light rain",           "🌦️"),
    63: ("Rain",                 "🌧️"),
    65: ("Heavy rain",           "🌧️"),
    71: ("Light snow",           "🌨️"),
    73: ("Snow",                 "❄️"),
    75: ("Heavy snow",           "❄️"),
    80: ("Showers",              "🌦️"),
    81: ("Heavy showers",        "🌧️"),
    82: ("Violent showers",      "⛈️"),
    95: ("Thunderstorm",         "⛈️"),
    96: ("Thunderstorm + hail",  "⛈️"),
    99: ("Severe thunderstorm",  "⛈️"),
}


def get_weather() -> str:
    try:
        url = (
            f"https://api.open-meteo.com/v1/forecast?"
            f"latitude={WEATHER_LAT}&longitude={WEATHER_LON}"
            f"&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code"
            f"&temperature_unit=celsius&timezone={urllib.parse.quote('{{TENANT_TIMEZONE}}')}"
        )
        with urllib.request.urlopen(url, timeout=8) as r:
            data = json.loads(r.read())
        c = data["current"]
        temp_c = round(c["temperature_2m"])
        feels_c = round(c["apparent_temperature"])
        humidity = round(c["relative_humidity_2m"])
        code = int(c["weather_code"])
        label, emoji = WEATHER_CODES.get(code, ("Unknown", "🌍"))
        temp_f = round(temp_c * 9 / 5 + 32)
        feels_f = round(feels_c * 9 / 5 + 32)
        return (
            f"{emoji} <b>{esc(WEATHER_LABEL)}</b> — {temp_f}°F / {temp_c}°C | {esc(label)} | "
            f"💧 {humidity}% | Feels like {feels_f}°F / {feels_c}°C"
        )
    except Exception as e:
        log(f"weather fetch failed: {e}")
        return "🌍 <i>Weather unavailable.</i>"


# ── Section: verse of the day (bible-api.com) ───────────────────────────────

FALLBACK_VERSES = [
    ("luke 14:28", "Stewardship",
     "For which of you, intending to build a tower, does not sit down first and count the cost, "
     "whether he has enough to finish it?"),
    ("proverbs 16:3", "Trust",
     "Commit to the Lord whatever you do, and he will establish your plans."),
    ("colossians 3:23", "Work",
     "Whatever you do, work at it with all your heart, as working for the Lord, not for human masters."),
    ("ecclesiastes 3:1", "Timing",
     "There is a time for everything, and a season for every activity under the heavens."),
    ("proverbs 21:5", "Diligence",
     "The plans of the diligent lead surely to plenty, but those of everyone who is hasty, surely to poverty."),
    ("james 1:5", "Wisdom",
     "If any of you lacks wisdom, you should ask God, who gives generously to all without finding fault."),
    ("philippians 4:13", "Strength",
     "I can do all things through him who strengthens me."),
]


def get_verse() -> str:
    today = datetime.now(TZ).date()
    idx = today.toordinal() % len(FALLBACK_VERSES)
    ref, theme, fallback_text = FALLBACK_VERSES[idx]
    try:
        url = f"https://bible-api.com/{urllib.parse.quote(ref)}"
        with urllib.request.urlopen(url, timeout=8) as r:
            data = json.loads(r.read())
        verse_text = re.sub(r"\s+", " ", (data.get("text") or "").strip().replace("\n", " "))
        ref_pretty = data.get("reference", ref.title())
        if verse_text:
            return f'"{esc(verse_text)}"\n— <b>{esc(ref_pretty)}</b> | <i>{esc(theme)}</i>'
    except Exception as e:
        log(f"verse fetch failed: {e}")
    return f'"{esc(fallback_text)}"\n— <b>{esc(ref.title())}</b> | <i>{esc(theme)}</i>'


# ── Section: agent status ───────────────────────────────────────────────────

def count_agents() -> tuple[int, list[str]]:
    if not PROJECT_AGENTS_DIR.is_dir():
        return 0, []
    names = sorted(p.stem for p in PROJECT_AGENTS_DIR.glob("*.md"))
    return len(names), names


def count_skills() -> tuple[int, list[str]]:
    if not USER_SKILLS_DIR.is_dir():
        return 0, []
    names = sorted(p.name for p in USER_SKILLS_DIR.iterdir() if p.is_dir())
    return len(names), names


def section_agent_status() -> str:
    agent_count, agents = count_agents()
    skill_count, skills = count_skills()
    if not agents and not skills:
        return "🤖 <i>No specialists registered.</i>"
    lines: list[str] = []
    for a in agents:
        pretty = " ".join(w.capitalize() for w in a.split("-"))
        lines.append(f"🤖 <b>{esc(pretty)}</b> — ready")
    if skills:
        lines.append(f"🛠️ <b>{skill_count} skill{'s' if skill_count != 1 else ''}</b> loaded ({esc(', '.join(skills))})")
    return "\n".join(lines)


# ── Section: pending drafts ─────────────────────────────────────────────────

def count_drafts() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    if not DRAFTS_DIR.is_dir():
        return out
    cutoff = datetime.now(timezone.utc) - timedelta(days=7)
    for sub in sorted(DRAFTS_DIR.iterdir()):
        if not sub.is_dir():
            continue
        recent = []
        for f in sub.iterdir():
            if not f.is_file():
                continue
            try:
                mt = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc)
                if mt >= cutoff:
                    recent.append(f.name)
            except Exception:
                pass
        if recent:
            out[sub.name] = sorted(recent)
    return out


def section_pending() -> str:
    drafts = count_drafts()
    if not drafts:
        return "⌛ No drafts pending — clean slate."
    lines: list[str] = []
    for cat, files in drafts.items():
        pretty = cat.replace("-", " ").title()
        lines.append(f"⌛ <b>{esc(pretty)}</b> — {len(files)} pending")
        for f in files[:3]:
            lines.append(f"   ├─ {esc(f)}")
        if len(files) > 3:
            lines.append(f"   └─ <i>+{len(files) - 3} more</i>")
    return "\n".join(lines)


# ── Section: goal progress ──────────────────────────────────────────────────

def section_goals() -> str:
    if not GOALS_PATH.is_file():
        return "📈 <i>No active goals.</i>"
    try:
        goals = json.loads(GOALS_PATH.read_text())
    except Exception as e:
        log(f"goals read failed: {e}")
        return "📈 <i>Could not read goals.</i>"

    active = [g for g in goals.values() if g.get("state") not in ("achieved", "abandoned")]
    if not active:
        return "📈 <i>All goals on track or completed.</i>"

    lines: list[str] = []
    for g in sorted(active, key=lambda x: x.get("target_date", "9999"))[:6]:
        title = g.get("summary", g.get("id", "Goal"))[:60]
        cur = float(g.get("current_value", 0))
        tgt = float(g.get("target_value", 1)) or 1.0
        pct = (cur / tgt) * 100.0 if tgt else 0.0
        lines.append(f"• {esc(title)} {progress_bar(pct)}")
    return "\n".join(lines)


# ── Section: upcoming deadlines ─────────────────────────────────────────────

def section_deadlines() -> str:
    if not TASKS_PATH.is_file():
        return ""
    try:
        tasks = json.loads(TASKS_PATH.read_text())
    except Exception as e:
        log(f"tasks read failed: {e}")
        return ""

    today = datetime.now(TZ).date()
    cutoff = today + timedelta(days=14)
    items: list[tuple[str, str, str]] = []
    for t in tasks.values():
        if t.get("state") in ("completed", "cancelled"):
            continue
        d = t.get("deadline") or ""
        if not d:
            continue
        try:
            dl = datetime.fromisoformat(d.replace("Z", "+00:00")).astimezone(TZ).date()
        except Exception:
            continue
        if today <= dl <= cutoff:
            label = dl.strftime("%A, %b %d")
            stale = "⚠️ " if t.get("state") == "stale" else ""
            items.append((dl.isoformat(), f"{stale}{t.get('summary', '')[:60]}", label))

    if not items:
        return ""
    items.sort()
    return "\n".join(f"└─ {esc(s)} — <i>{esc(d)}</i>" for _, s, d in items[:5])


def count_stale_tasks() -> int:
    if not TASKS_PATH.is_file():
        return 0
    try:
        tasks = json.loads(TASKS_PATH.read_text())
    except Exception:
        return 0
    return sum(1 for t in tasks.values() if t.get("state") == "stale")


# ── LLM section: today's priorities + daily insight ────────────────────────

LLM_PROMPT = """\
It is {day}, {date_str}. Time for {owner}'s morning brief context block.

Pull live data using your MCPs:
- Pipeline: mcp__ghl__get_pipelines + mcp__ghl__search_opportunities — open opps total value (USD), open count, stalled count, AND list the top 3 stalled opps by value (name, $, days_since_last_contact)
- Calendar: mcp__claude_ai_Google_Calendar__list_events for today ({tz} timezone) — also identify free slots ≥30 min between meetings
- Inbox: mcp__claude_ai_Gmail__search_threads with newer_than:1d — count threads, AND flag any thread from a known prospect (cross-reference with GHL contacts)

Read these local files to ground proposals:
- Active goals: {agent_home}/goals/active.json (target_date, current_value vs target_value)
- Drafts ready to ship: {agent_home}/drafts/replies/, {agent_home}/drafts/social/, {agent_home}/drafts/self-improvement/ — list filenames + first-line preview
- Yesterday's proposals + outcomes: {agent_home}/proposals/{yesterday}.json (if exists) — DO NOT propose anything that was already approved+executed yesterday OR rejected within the last 14 days. Read the rejected log at {agent_home}/proposals/rejected.jsonl for prior skip patterns.

Then write a JSON object with EXACTLY this schema, nothing else (no markdown fences, no preamble):

{{{{
  "priorities": ["actionable line 1", "actionable line 2", "actionable line 3"],
  "pipeline_summary": "$X open across N opps, M stalled",
  "calendar_summary": "Description of today's meetings or 'no meetings scheduled'",
  "inbox_summary": "N unread threads since yesterday",
  "insight": "1-2 sentences of practical insight tying today's priorities to a current goal or stalled item. Direct. No platitudes.",
  "proposals": [
    {{{{
      "id": "p-{date_compact}-aaaa",
      "archetype": "pipeline_unstick | asset_deploy | inbound_trigger | goal_deep_work | system_leverage",
      "title": "Verb-led, ≤80 chars, names the artifact/person ('Reply to Sarah Chen on the GHL audit thread' not 'Reply to email')",
      "rationale": "1-2 sentences: which goal/deal/lever this moves and by how much. Cite numbers.",
      "executor": "comms-agent | content-agent | pipeline-agent | research-agent | drift-scanner | self",
      "effort": "S | M | L",
      "expected_outcome": "Concrete: '$X closer to revenue goal', 'Stalled deal Z re-opened', 'Newsletter draft #N shipped'",
      "linked_goal_id": "g-YYYYMMDD-xxxx | null"
    }}}}
  ]
}}}}

Generate EXACTLY 3 proposals. Use stable lowercase-letter suffixes (aaaa, bbbb, cccc) so IDs are unique within the day.

PROPOSAL ARCHETYPE PRIORITY ORDER (pick the highest-priority that has real material):
  1. pipeline_unstick — a stalled deal worth ≥$2K with last_contact ≥7d. Title: 'Re-engage <name> on <deal-summary> with <specific-talking-point-from-deal-notes>'. Executor: comms-agent.
  2. asset_deploy — a draft already exists in drafts/. Title: 'Publish <filename> to <channel> at <time>'. Executor: content-agent (social/newsletter) or comms-agent (replies).
  3. inbound_trigger — a topical post that hits an active goal. Title: 'Draft <platform> post on <specific-topic-tied-to-goal>'. Executor: content-agent.
  4. goal_deep_work — concrete chunk that moves a goal's current_value. Title: 'Advance <goal-summary> by <specific-output>'. Executor: depends on goal type.
  5. system_leverage — only when there's evidence in the agent stack of repeated waste (e.g. 5+ stale tasks of the same shape). Title: 'Build <small-tool> that eliminates <observed-waste>'. Executor: self.

REJECT shapes that are too vague to autonomously execute:
- 'Review pipeline' / 'Triage inbox' / 'Check on X' — these are not actions, they're meta-tasks
- 'Reach out to your network' — needs a named person
- 'Post something on LinkedIn' — needs a named topic + draft
- Anything that requires info the agent doesn't have (proposals must be executable end-to-end without asking {owner} for input)

Voice DNA (HARD RULES — enforce as filters before you finalize text):
- Direct, empathetic, clarity over cleverness, brevity over flourish
- NO emojis inside the JSON values (the renderer adds them)
- NEVER use any of these phrases: "thrilled to", "excited to share", "in today's fast-paced world", "humbled to", "delve into", "in the realm of"
- Numbers and names, not abstractions ("3 stalled deals worth $12K" not "some pipeline activity")
- "{owner}" is the individual consultant; never mention organizational names

Priorities should be ACTIONABLE — start with a verb, name the artifact or person, include rough time if relevant.
If a data source returns nothing, write a one-line summary saying so (e.g. "no meetings scheduled"). Do not invent.
If genuinely no archetype has material to propose (extremely rare — even a quiet day has stale deals or undeployed drafts), generate proposals tied to the highest-priority active goal's next concrete step.
"""


def call_claude_for_priorities(day: str, date_str: str) -> dict[str, Any]:
    yesterday = (datetime.now(TZ).date() - timedelta(days=1)).isoformat()
    date_compact = datetime.now(TZ).strftime("%Y%m%d")
    prompt = LLM_PROMPT.format(
        day=day,
        date_str=date_str,
        owner=OWNER_NAME,
        tz="{{TENANT_TIMEZONE}}",
        agent_home=str(AGENT_HOME),
        yesterday=yesterday,
        date_compact=date_compact,
    )
    try:
        # 360s — proposal generation reads 3+ local files and calls 3 MCPs;
        # observed wall time 90-180s in the happy path, occasional 240s outliers.
        result = subprocess.run(
            ["claude", "--permission-mode", "dontAsk", "--print", prompt],
            cwd=str(AGENT_HOME),
            capture_output=True,
            text=True,
            timeout=360,
            env={**os.environ, "HOME": str(USER_HOME)},
        )
        if result.returncode != 0:
            log(f"claude --print failed (rc={result.returncode}): {result.stderr[:500]}")
            return {}
        out = result.stdout.strip()
        m = re.search(r"\{[\s\S]*\}", out)
        if not m:
            log(f"no JSON object in claude output: {out[:300]}")
            return {}
        return json.loads(m.group(0))
    except Exception as e:
        log(f"claude --print exception: {e}")
        return {}


# ── Section: Proposed Moves (Chief of Staff layer) ──────────────────────────

# Stable executor → emoji map for the proposal section
EXECUTOR_EMOJI = {
    "comms-agent":     "📨",
    "content-agent":   "✍️",
    "pipeline-agent":  "💼",
    "research-agent":  "🔬",
    "drift-scanner":   "🎯",
    "self":            "🛠️",
}

ARCHETYPE_LABEL = {
    "pipeline_unstick": "Pipeline unstick",
    "asset_deploy":     "Asset deploy",
    "inbound_trigger":  "Inbound trigger",
    "goal_deep_work":   "Goal deep work",
    "system_leverage":  "System leverage",
}


def normalize_proposal_id(raw_id: str, idx: int) -> str:
    """Coerce LLM-supplied IDs to canonical p-YYYYMMDD-aaaa format."""
    date_compact = datetime.now(TZ).strftime("%Y%m%d")
    suffix = ["aaaa", "bbbb", "cccc", "dddd", "eeee"][idx] if idx < 5 else f"x{idx:03d}"
    expected_prefix = f"p-{date_compact}-"
    if raw_id and raw_id.startswith(expected_prefix) and len(raw_id) == len(expected_prefix) + 4:
        return raw_id
    return f"{expected_prefix}{suffix}"


def persist_proposals(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize, persist, and return the list of proposals for rendering.

    Defensive: if the LLM call returned an empty list AND today's file already
    has live proposals (from an earlier successful run), preserve them. Same-day
    re-runs of the brief should never clobber state changes the agent has made
    (state=approved/skipped) just because the LLM happened to time out.
    """
    PROPOSALS_DIR.mkdir(parents=True, exist_ok=True)
    if not raw and PROPOSALS_PATH.is_file():
        try:
            existing = json.loads(PROPOSALS_PATH.read_text())
            old = existing.get("proposals") or []
            if old:
                log(f"LLM returned no proposals; preserving {len(old)} existing in {PROPOSALS_PATH}")
                return old
        except Exception as e:
            log(f"could not read existing proposals: {e}")
    out: list[dict[str, Any]] = []
    for i, p in enumerate(raw[:3]):  # cap at 3 — keeps the keyboard sane
        norm = {
            "id":               normalize_proposal_id(p.get("id", ""), i),
            "archetype":        p.get("archetype", "goal_deep_work"),
            "title":            strip_banned((p.get("title") or "").strip())[:160],
            "rationale":        strip_banned((p.get("rationale") or "").strip())[:400],
            "executor":         (p.get("executor") or "self").strip(),
            "effort":           (p.get("effort") or "M").upper()[:1],
            "expected_outcome": strip_banned((p.get("expected_outcome") or "").strip())[:200],
            "linked_goal_id":   p.get("linked_goal_id") or None,
            "created_at":       datetime.now(timezone.utc).isoformat(),
            "state":            "proposed",  # → approved | skipped | executed | expired
        }
        out.append(norm)
    payload = {
        "date":      DATE_STR,
        "proposals": out,
    }
    PROPOSALS_PATH.write_text(json.dumps(payload, indent=2))
    log(f"persisted {len(out)} proposals → {PROPOSALS_PATH}")
    return out


def section_proposals(proposals: list[dict[str, Any]]) -> str:
    if not proposals:
        return (
            "🤖 <i>No moves proposed today — agent stack reports nothing actionable. "
            "If this persists, check the proposal generator prompt.</i>"
        )
    lines: list[str] = []
    for i, p in enumerate(proposals, start=1):
        emoji = EXECUTOR_EMOJI.get(p["executor"], "🤖")
        archetype = ARCHETYPE_LABEL.get(p["archetype"], p["archetype"])
        lines.append(
            f"<b>#{i}. {emoji} {esc(p['title'])}</b>\n"
            f"   ├─ <i>{esc(archetype)}</i> · {esc(p['executor'])} · effort {esc(p['effort'])}\n"
            f"   ├─ Why: {esc(p['rationale'])}\n"
            f"   └─ Outcome: {esc(p['expected_outcome'])}"
        )
    return "\n\n".join(lines)


def proposal_buttons(proposals: list[dict[str, Any]]) -> list[list[dict[str, str]]]:
    """One row per proposal: [✅ Run #N | callback prop:run:<id>] [⏭️ Skip #N | callback prop:skip:<id>]."""
    rows: list[list[dict[str, str]]] = []
    for i, p in enumerate(proposals, start=1):
        rows.append([
            {"text": f"✅ Run #{i}",  "callback_data": f"prop:run:{p['id']}"},
            {"text": f"⏭️ Skip #{i}", "callback_data": f"prop:skip:{p['id']}"},
        ])
    return rows


# ── Greeting ────────────────────────────────────────────────────────────────

def greeting() -> str:
    h = datetime.now(TZ).hour
    if h < 12:
        return f"Good Morning, {OWNER_NAME}"
    if h < 18:
        return f"Good Afternoon, {OWNER_NAME}"
    return f"Good Evening, {OWNER_NAME}"


# ── Compose the full message ────────────────────────────────────────────────

def compose_message(llm: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    """Returns (html_message, persisted_proposals)."""
    now = datetime.now(TZ)
    day_long = now.strftime("%A, %B %d, %Y")

    priorities = llm.get("priorities") or [
        "Review pipeline state",
        "Triage inbox",
        "Pick top draft to finish",
    ]
    pipe = llm.get("pipeline_summary") or "Pipeline data unavailable"
    cal = llm.get("calendar_summary") or "Calendar unavailable"
    inbox = llm.get("inbox_summary") or "Inbox unavailable"
    insight = llm.get("insight") or "Pick the smallest unblockable thing and ship it before lunch."
    proposals = persist_proposals(llm.get("proposals") or [])

    pr_lines = []
    sliced = priorities[:5]
    for i, p in enumerate(sliced):
        prefix = "└─" if i == len(sliced) - 1 else "├─"
        pr_lines.append(f"{prefix} {esc(strip_banned(p))}")
    priorities_block = "\n".join(pr_lines)

    snapshot = (
        f"📦 <b>Pipeline</b> — {esc(strip_banned(pipe))}\n"
        f"📅 <b>Calendar</b> — {esc(strip_banned(cal))}\n"
        f"📨 <b>Inbox</b> — {esc(strip_banned(inbox))}"
    )

    stale_count = count_stale_tasks()
    stale_line = (
        f"⚠️ <b>{stale_count} stale task{'s' if stale_count != 1 else ''}</b> — review or close."
        if stale_count
        else ""
    )

    deadlines = section_deadlines()
    deadlines_block = blockquote("⏰ Upcoming Deadlines", deadlines) if deadlines else ""

    parts = [
        f"<b>{esc(greeting())}</b> ☀️",
        "",
        f"📅 {esc(day_long)}",
        "",
        blockquote("🌤️ Weather", get_weather()),
        "",
        blockquote("✝️ Verse of the Day", get_verse()),
        "",
        blockquote("🤖 Agent Status", section_agent_status()),
        "",
        blockquote("📊 Snapshot", snapshot),
        "",
        blockquote("🎯 Today's Priorities", priorities_block),
        "",
        blockquote("⌛ Pending / Ready to Complete", section_pending()),
        "",
        blockquote("📈 Goal Progress", section_goals()),
    ]
    if deadlines_block:
        parts.extend(["", deadlines_block])
    if stale_line:
        parts.extend(["", stale_line])
    parts.extend(["", blockquote("💡 Daily Insight", esc(strip_banned(insight)))])
    parts.extend(["", blockquote("🤖 Proposed Moves — Tap to Approve", section_proposals(proposals))])
    return "\n".join(parts), proposals


# ── Telegram delivery ───────────────────────────────────────────────────────

def load_tg_creds() -> tuple[str, str]:
    token = ""
    for line in TG_ENV.read_text().splitlines():
        if line.startswith("TELEGRAM_BOT_TOKEN="):
            token = line.split("=", 1)[1].strip()
            break
    if not token:
        raise RuntimeError(f"no TELEGRAM_BOT_TOKEN in {TG_ENV}")
    access = json.loads(TG_ACCESS.read_text())
    return token, str(access["allowFrom"][0])


def send_telegram(message: str, proposals: list[dict[str, Any]]) -> int:
    token, chat = load_tg_creds()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    # Layout: proposal rows first (most actionable), then quick-action rows.
    keyboard_rows: list[list[dict[str, str]]] = list(proposal_buttons(proposals))
    keyboard_rows.append([QUICK_ACTIONS[0], QUICK_ACTIONS[1]])
    keyboard_rows.append([QUICK_ACTIONS[2], QUICK_ACTIONS[3]])
    payload = {
        "chat_id": chat,
        "text": message,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
        "reply_markup": {"inline_keyboard": keyboard_rows},
    }
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        resp = json.loads(r.read())
    if not resp.get("ok"):
        raise RuntimeError(f"telegram error: {resp}")
    return int(resp["result"]["message_id"])


# ── Main ────────────────────────────────────────────────────────────────────

def persist_llm_summary(llm: dict[str, Any], date_str: str) -> None:
    """Persist the LLM-composed narrative so the dashboard's Daily Briefing can
    surface the SAME insight the Telegram brief uses — zero extra LLM cost.
    Read by dashboard-sync-autonomy.py into daily-brief.json.executive_summary.
    """
    try:
        state_dir = AGENT_HOME / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "generated_at": datetime.now(TZ).isoformat(),
            "date": date_str,
            "insight": llm.get("insight", ""),
            "priorities": llm.get("priorities", []) if isinstance(llm.get("priorities"), list) else [],
            "pipeline_summary": llm.get("pipeline_summary", ""),
            "calendar_summary": llm.get("calendar_summary", ""),
            "inbox_summary": llm.get("inbox_summary", ""),
        }
        tmp = state_dir / "morning-brief-llm.json.tmp"
        tmp.write_text(json.dumps(payload, indent=2))
        tmp.replace(state_dir / "morning-brief-llm.json")
    except Exception as e:
        log(f"persist_llm_summary failed: {e}")


def main() -> int:
    log("=== morning-brief.py started ===")
    now = datetime.now(TZ)
    day = now.strftime("%A")
    date_str = now.strftime("%Y-%m-%d")

    llm: dict[str, Any] = {}
    frugal = (AGENT_HOME / "state" / "frugal-mode").exists()
    if frugal:
        log("frugal mode ON — skipping LLM section of the brief")
    if "--no-llm" not in sys.argv and not frugal:
        log("invoking claude --print for priorities + insight")
        llm = call_claude_for_priorities(day, date_str)
        log(f"claude returned: keys={list(llm.keys())}")

    msg, proposals = compose_message(llm)
    log(f"composed message ({len(msg)} chars, {len(proposals)} proposals)")
    persist_llm_summary(llm, date_str)

    if "--dry-run" in sys.argv:
        sys.stdout.write(msg + "\n")
        log("dry-run — not sending")
        return 0

    msg_id = send_telegram(msg, proposals)
    log(f"sent telegram message id={msg_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
