#!/usr/bin/env python3
"""content-swarm — brief → newsletter + LinkedIn + X + IG carousel, all staged in GHL.

Usage:
  python3 content_swarm.py --brief "Topic or theme" [--task-id t-XXXX]
  python3 content_swarm.py --brief-file /path/to/brief.json [--task-id t-XXXX]

Brief JSON schema:
  {
    "topic": "Main topic or angle",
    "angle": "Optional: specific take or hook",
    "audience": "Optional: who this is for",
    "cta": "Optional: call to action"
  }

Output:
  - Newsletter draft → GHL email template (draft)
  - LinkedIn post → GHL social post (draft)
  - X/Twitter thread → GHL social post (draft)
  - IG carousel script → local draft file
  - Telegram notification with links
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from swarm_base import (
    AGENT_HOME, CLAUDE_MODEL_FAST, CLAUDE_MODEL_MAIN,
    log, now_iso, read_brand_voice, recall_memories,
    run_agent, save_draft, save_memory, tg_send, update_task,
)

import subprocess

SWARM = "content"

# Tenant identity — substituted by render-tenant.sh at deploy time.
TENANT_NAME = "{{TENANT_PERSON_FULL_NAME}}"
TENANT_FIRST_NAME = "{{TENANT_PERSON_FIRST_NAME}}"


def stage_ghl_social(platform: str, text: str, label: str) -> str | None:
    """Stage a social post draft in GHL. Returns post ID or None."""
    result = subprocess.run(
        ["bash", "-c", f"""
        source {{TENANT_AGENT_HOME}}/.env 2>/dev/null || true
        cat > /tmp/ghl-social-draft.json << 'EOF'
{json.dumps({"text": text, "platform": platform})}
EOF
        """],
        capture_output=True, text=True, timeout=10,
    )
    # GHL staging is via MCP — return a placeholder for now, the chief-of-staff MCP does the actual staging
    return None


def run(brief: dict, task_id: str | None = None) -> None:
    swarm_name = SWARM
    log(swarm_name, f"Starting — topic: {brief.get('topic', '?')}")

    if task_id:
        update_task(task_id, "in_progress", "content-swarm starting pipeline")

    # --- Step 1: Load voice DNA + recall relevant memories ---
    log(swarm_name, "Step 1: Loading voice context")
    voice_dna = read_brand_voice()
    memories = recall_memories(
        query=f"{brief.get('topic', '')} {brief.get('angle', '')}",
        tags="voice,newsletter,content,social",
        limit=6,
    )
    memory_context = ""
    if memories:
        memory_context = "\n\n## Past editing signals (apply these):\n"
        for m in memories:
            if m.get("type") in ("pattern", "preference"):
                memory_context += f"- {m['text']}\n"

    # --- Step 2: Core idea + angle (fast model) ---
    log(swarm_name, "Step 2: Generating core angle")
    angle_prompt = f"""You are {TENANT_NAME}'s content strategist. Generate a sharp, specific content angle for this topic.

Topic: {brief.get('topic', '')}
Audience: {brief.get('audience', 'the tenant\'s target audience — see brand canon for ICP')}
Additional angle hint: {brief.get('angle', 'none')}

Return JSON only:
{{
  "hook": "one punchy opening line that earns the scroll",
  "angle": "the specific take — what makes this non-obvious",
  "big_idea": "the core insight in one sentence",
  "evidence": "one concrete example or data point to anchor this",
  "cta": "{brief.get('cta', 'what should readers do or think differently')}"
}}"""

    core = run_agent(angle_prompt, model=CLAUDE_MODEL_FAST, max_tokens=500)
    try:
        import re, json as _json
        core_clean = re.sub(r"^```(?:json)?\s*", "", core.strip(), flags=re.MULTILINE)
        core_clean = re.sub(r"\s*```$", "", core_clean.strip(), flags=re.MULTILINE)
        core_data = _json.loads(core_clean)
    except Exception:
        core_data = {"hook": core[:100], "angle": brief.get("topic", ""), "big_idea": "", "evidence": "", "cta": ""}

    log(swarm_name, f"Core angle: {core_data.get('angle', '')[:60]}")

    # --- Step 3: Newsletter draft ---
    log(swarm_name, "Step 3: Drafting newsletter")

    newsletter_system = f"""You are {TENANT_NAME}'s newsletter ghostwriter.
Voice rules (non-negotiable):
- Friend who happens to know what they're doing. Warm, direct, sometimes funny. Never pompous.
- No "I'm thrilled to" openers. No LinkedIn slide deck language.
- No emojis unless conversational.
- Short paragraphs. White space. Punchy sentences.
- End with a clear, single CTA.

{voice_dna[:2000] if voice_dna else ''}
{memory_context}"""

    newsletter_prompt = f"""Write a newsletter issue on this topic in {TENANT_FIRST_NAME}'s voice.

Hook: {core_data.get('hook', '')}
Angle: {core_data.get('angle', '')}
Big idea: {core_data.get('big_idea', '')}
Evidence: {core_data.get('evidence', '')}
CTA: {core_data.get('cta', '')}

Format:
- Subject line (punchy, <60 chars, no clickbait)
- Preview text (1 sentence, 80-100 chars)
- Body (300-500 words, 3-4 sections, short paragraphs)
- CTA section (1-2 sentences max)

Return as plain text with clear section markers: SUBJECT:, PREVIEW:, BODY:, CTA:"""

    newsletter_text = run_agent(newsletter_prompt, system=newsletter_system, max_tokens=2000, timeout=120)
    newsletter_path = save_draft(swarm_name, f"newsletter-{now_iso()[:10]}.md", newsletter_text)
    log(swarm_name, f"Newsletter saved: {newsletter_path}")

    # --- Step 4: LinkedIn post ---
    log(swarm_name, "Step 4: Drafting LinkedIn post")

    li_prompt = f"""Write a LinkedIn post based on this newsletter angle.

Hook: {core_data.get('hook', '')}
Angle: {core_data.get('angle', '')}
Big idea: {core_data.get('big_idea', '')}
Evidence: {core_data.get('evidence', '')}

LinkedIn rules for {TENANT_FIRST_NAME}:
- Start with a hook that earns the scroll (not "I'm excited to share")
- 150-250 words total
- Short lines — max 2 sentences per paragraph
- No hashtag dumps. 1-2 relevant hashtags max, end only.
- End with a question or provocation, not "What do you think?"
- Voice: direct, warm, smart. Friend-vibe not corporate.
{memory_context}

Return plain text only — the post, nothing else."""

    linkedin_text = run_agent(li_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Step 5: X/Twitter thread ---
    log(swarm_name, "Step 5: Drafting X thread")

    x_prompt = f"""Write a 4-tweet thread for X/Twitter based on this angle.

Hook: {core_data.get('hook', '')}
Big idea: {core_data.get('big_idea', '')}
Evidence: {core_data.get('evidence', '')}
CTA: {core_data.get('cta', '')}

Rules:
- Tweet 1: hook only, <240 chars, earns the click to expand
- Tweets 2-3: the insight unpacked, 1 idea per tweet
- Tweet 4: provocation or CTA, no cringe endings
- Voice: conversational, no buzzwords, no "🧵 thread" opener
{memory_context}

Format as:
Tweet 1: [text]
Tweet 2: [text]
Tweet 3: [text]
Tweet 4: [text]"""

    x_thread_text = run_agent(x_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Step 6: IG Carousel script ---
    log(swarm_name, "Step 6: Writing IG carousel script")

    ig_prompt = f"""Write a 6-slide Instagram carousel script based on this angle.

Hook: {core_data.get('hook', '')}
Big idea: {core_data.get('big_idea', '')}
Evidence: {core_data.get('evidence', '')}

Carousel rules:
- Slide 1: bold hook statement (cover — earns the swipe)
- Slides 2-5: one idea per slide, max 15 words headline + 1-2 sentence body
- Slide 6: CTA / follow prompt
- Voice: punchy, visual, text that works without design context

Format as:
Slide 1 - COVER: [headline]
Slide 2: [headline] | [body]
...
Slide 6 - CTA: [text]
Caption: [caption text with 3-5 hashtags]"""

    ig_text = run_agent(ig_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Step 7: Save all drafts ---
    log(swarm_name, "Step 7: Saving all drafts")
    li_path = save_draft(swarm_name, f"linkedin-{now_iso()[:10]}.md", linkedin_text)
    x_path = save_draft(swarm_name, f"x-thread-{now_iso()[:10]}.md", x_thread_text)
    ig_path = save_draft(swarm_name, f"ig-carousel-{now_iso()[:10]}.md", ig_text)

    # Save the full bundle
    bundle = {
        "topic": brief.get("topic", ""),
        "generated_at": now_iso(),
        "core_angle": core_data,
        "newsletter_path": str(newsletter_path),
        "linkedin_path": str(li_path),
        "x_path": str(x_path),
        "ig_path": str(ig_path),
    }
    bundle_path = save_draft(swarm_name, f"bundle-{now_iso()[:10]}.json", json.dumps(bundle, indent=2))

    # --- Step 8: Save pattern memory ---
    save_memory(
        type_="pattern",
        text=f"Content swarm ran for topic '{brief.get('topic', '')}' — angle: {core_data.get('angle', '')[:100]}",
        tags="content-swarm,social,newsletter",
        source="content-swarm",
        confidence=0.75,
    )

    # --- Step 9: Telegram notification ---
    log(swarm_name, f"Step 9: Notifying {TENANT_FIRST_NAME}")
    topic_esc = brief.get("topic", "").replace("-", "\\-").replace(".", "\\.").replace("(", "\\(").replace(")", "\\)")

    # Extract subject line for preview
    subject = ""
    for line in newsletter_text.split("\n"):
        if line.startswith("SUBJECT:"):
            subject = line.replace("SUBJECT:", "").strip()
            break

    tg_msg = f"""⚙️ *content\\-swarm* — 4 drafts ready

*Topic:* {topic_esc}
*Angle:* {core_data.get('angle', '')[:80].replace('-', '\\-').replace('.', '\\.').replace('(', '\\(').replace(')', '\\)')}

*Drafts staged:*
• Newsletter → `{newsletter_path.name}`
• LinkedIn post → `{li_path.name}`
• X thread → `{x_path.name}`
• IG carousel → `{ig_path.name}`

_All in_ `{str(AGENT_HOME / 'drafts' / swarm_name)}`"""

    if task_id:
        tg_send(tg_msg, callback_buttons=f"✅ GHL Stage All|swarm:stage:{task_id},✏️ Revise|swarm:revise:{task_id},❌ Discard|swarm:discard:{task_id}")
        update_task(task_id, "awaiting_review", f"4 drafts ready — {str(bundle_path)}")
    else:
        tg_send(tg_msg)

    log(swarm_name, "Pipeline complete")
    print(json.dumps(bundle, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--brief", help="Topic/brief text")
    parser.add_argument("--brief-file", help="Path to JSON brief file")
    parser.add_argument("--task-id", help="Task ledger ID")
    args = parser.parse_args()

    if args.brief_file:
        brief = json.loads(Path(args.brief_file).read_text())
    elif args.brief:
        brief = {"topic": args.brief}
    else:
        parser.error("Either --brief or --brief-file required")

    run(brief, task_id=args.task_id)


if __name__ == "__main__":
    main()
