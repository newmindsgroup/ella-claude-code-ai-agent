#!/usr/bin/env python3
"""bizdev-swarm — prospect name/URL → research + outreach draft + proposal outline, one shot.

Usage:
  python3 bizdev_swarm.py --prospect "Company Name" [--url https://...] [--task-id t-XXXX]
  python3 bizdev_swarm.py --brief-file /path/to/brief.json [--task-id t-XXXX]

Brief JSON schema:
  {
    "company": "Company name",
    "contact": "Contact person name (optional)",
    "url": "Website URL (optional)",
    "context": "How {{TENANT_PERSON_FIRST_NAME}} knows them / why they're a fit (optional)",
    "service": "Which service to pitch (optional — defaults to the tenant's flagship offer)"
  }

Output:
  - Prospect card (research summary)
  - Outreach email draft → GHL email template
  - Proposal outline → local draft
  - Memory saved for future reference
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

SWARM = "bizdev"

# Tenant identity — substituted by render-tenant.sh at deploy time.
TENANT_NAME = "{{TENANT_PERSON_FULL_NAME}}"
TENANT_FIRST_NAME = "{{TENANT_PERSON_FIRST_NAME}}"
TENANT_ROLE = "{{TENANT_PERSON_ROLE_DESCRIPTION}}"


def run(brief: dict, task_id: str | None = None) -> None:
    company = brief.get("company", "Unknown")
    contact = brief.get("contact", "")
    url = brief.get("url", "")
    context = brief.get("context", "")
    service = brief.get("service", "the flagship offer")

    log(SWARM, f"Starting — prospect: {company}")
    if task_id:
        update_task(task_id, "in_progress", f"bizdev-swarm researching {company}")

    # --- Step 1: Check existing memories for this prospect ---
    log(SWARM, "Step 1: Checking memory vault for existing context")
    existing = recall_memories(query=f"{company} {contact}", limit=5)
    prior_context = ""
    if existing:
        prior_context = "\n## What we already know:\n"
        for m in existing:
            prior_context += f"- [{m['type']}] {m['text']}\n"
        log(SWARM, f"Found {len(existing)} prior memories")

    # --- Step 2: Research the prospect ---
    log(SWARM, "Step 2: Researching prospect")
    research_prompt = f"""You are a business development researcher for {TENANT_NAME} ({TENANT_ROLE}).

Research this prospect and produce a structured card.

Company: {company}
Contact: {contact or 'unknown'}
Website: {url or 'not provided'}
Known context: {context or 'none'}
{prior_context}

Refer to the canonical services and pricing doc in the brand repo for {TENANT_FIRST_NAME}'s current offers and pricing.

Based on what you know about this company/person (be specific, cite what you know, don't fabricate):

Return JSON:
{{
  "company": "{company}",
  "contact": "{contact or 'TBD'}",
  "tldr": "2 sentences: who they are and why they might fit",
  "snapshot": {{
    "sector": "industry/sector",
    "stage": "startup/growth/enterprise/unknown",
    "signals": ["signal 1 — why {TENANT_FIRST_NAME} is relevant", "signal 2"],
    "pain_points": ["likely pain point 1", "likely pain point 2"]
  }},
  "fit_score": "high/medium/low",
  "fit_reason": "why this is a good or weak fit",
  "best_service": "which service maps best",
  "opening_angle": "the one thing {TENANT_FIRST_NAME} should lead with in an outreach"
}}"""

    research_raw = run_agent(research_prompt, model=CLAUDE_MODEL_FAST, max_tokens=800, timeout=60)
    try:
        import re, json as _json
        clean = re.sub(r"^```(?:json)?\s*", "", research_raw.strip(), flags=re.MULTILINE)
        clean = re.sub(r"\s*```$", "", clean.strip(), flags=re.MULTILINE)
        research = _json.loads(clean)
    except Exception:
        research = {
            "company": company, "contact": contact, "tldr": research_raw[:200],
            "snapshot": {}, "fit_score": "unknown", "fit_reason": "",
            "best_service": service, "opening_angle": ""
        }

    log(SWARM, f"Fit score: {research.get('fit_score', '?')}")

    # --- Step 3: Outreach email draft ---
    log(SWARM, "Step 3: Drafting outreach email")
    voice_dna = read_brand_voice()
    voice_memories = recall_memories(tags="voice,email,outreach", limit=4)
    voice_context = "\n".join([f"- {m['text']}" for m in voice_memories if m.get("type") in ("pattern", "preference")])

    outreach_system = f"""You are {TENANT_NAME}'s ghostwriter for business development outreach.
Voice: warm, direct, confident without being pushy. Friend who knows their stuff. No hype. No "I hope this finds you well."
{voice_dna[:1500] if voice_dna else ''}
{f'Past editing signals: {voice_context}' if voice_context else ''}"""

    outreach_prompt = f"""Write a cold outreach email from {TENANT_NAME} to this prospect.

Prospect: {research.get('contact') or company}
Company: {company}
Opening angle: {research.get('opening_angle', 'a specific, recent reason this prospect would care')}
Best service to pitch: {research.get('best_service', service)}
Fit reason: {research.get('fit_reason', '')}

Rules:
- Subject: <60 chars, specific, earns the open
- Body: 3 short paragraphs max (under 150 words total)
- Para 1: specific hook — why them, why now. No generic openers.
- Para 2: what {TENANT_FIRST_NAME} does, one sentence. The value, not the features.
- Para 3: low-friction ask (15-min call, not "let's jump on a call")
- No "synergies", no "leverage", no "thrilled to"
- Sign as {TENANT_FIRST_NAME}, no title

Format:
SUBJECT: [subject]
BODY: [email body]"""

    outreach_text = run_agent(outreach_prompt, system=outreach_system, max_tokens=500, timeout=60)

    # --- Step 4: Proposal outline ---
    log(SWARM, "Step 4: Building proposal outline")
    proposal_prompt = f"""Create a proposal outline for {TENANT_NAME} pitching {research.get('best_service', service)} to {company}.

What we know:
- Pain points: {', '.join(research.get('snapshot', {}).get('pain_points', ['operational gaps', 'tooling lag']))}
- Fit: {research.get('fit_reason', '')}
- Signals: {', '.join(research.get('snapshot', {}).get('signals', []))}

Produce a proposal outline (not a full proposal):
1. Problem framing (2-3 bullets from their world)
2. Proposed engagement (scope, timeline, deliverables — based on {research.get('best_service', service)})
3. Why {TENANT_FIRST_NAME} (3 proof points — be specific)
4. Investment (placeholder: "{service} — see tenant's services doc for current pricing")
5. Next step

Keep it tight — this is an outline, not a deck. Bullets only."""

    proposal_text = run_agent(proposal_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Step 5: Save everything ---
    log(SWARM, "Step 5: Saving drafts")
    slug = company.lower().replace(" ", "-").replace("/", "")[:30]
    ts = now_iso()[:10]

    prospect_card = f"""# {company}
Generated: {now_iso()}

## TL;DR
{research.get('tldr', '')}

## Snapshot
- Sector: {research.get('snapshot', {}).get('sector', 'unknown')}
- Stage: {research.get('snapshot', {}).get('stage', 'unknown')}
- Fit: {research.get('fit_score', '?')} — {research.get('fit_reason', '')}
- Best service: {research.get('best_service', service)}

## Signals
{chr(10).join('- ' + s for s in research.get('snapshot', {}).get('signals', []))}

## Pain Points
{chr(10).join('- ' + p for p in research.get('snapshot', {}).get('pain_points', []))}

## Opening Angle
{research.get('opening_angle', '')}
"""

    card_path = save_draft(SWARM, f"{slug}-card-{ts}.md", prospect_card)
    outreach_path = save_draft(SWARM, f"{slug}-outreach-{ts}.md", outreach_text)
    proposal_path = save_draft(SWARM, f"{slug}-proposal-outline-{ts}.md", proposal_text)

    bundle = {
        "company": company, "generated_at": now_iso(),
        "fit_score": research.get("fit_score", "?"),
        "card_path": str(card_path),
        "outreach_path": str(outreach_path),
        "proposal_path": str(proposal_path),
    }
    save_draft(SWARM, f"{slug}-bundle-{ts}.json", json.dumps(bundle, indent=2))

    # --- Step 6: Save relationship memory ---
    mem_text = f"{company}{f' / {contact}' if contact else ''} — {research.get('tldr', '')[:200]} Fit: {research.get('fit_score', '?')}."
    save_memory("relationship", mem_text, f"prospect,bizdev,{slug}", "bizdev-swarm", 0.85)

    # --- Step 7: Telegram notification ---
    log(SWARM, f"Step 7: Notifying {TENANT_FIRST_NAME}")

    def esc(s: str) -> str:
        for c in r"_*[]()~`>#+-=|{}.!\\":
            s = s.replace(c, f"\\{c}")
        return s

    fit_emoji = {"high": "🟢", "medium": "🟡", "low": "🔴"}.get(research.get("fit_score", ""), "⚪")

    tg_msg = f"""⚙️ *bizdev\\-swarm* — {esc(company)} ready

{fit_emoji} *Fit:* {esc(research.get('fit_score', '?'))} — {esc(research.get('fit_reason', '')[:80])}
*Best pitch:* {esc(research.get('best_service', service))}
*Opening angle:* {esc(research.get('opening_angle', '')[:100])}

*3 drafts ready:*
• Prospect card → `{card_path.name}`
• Outreach email → `{outreach_path.name}`
• Proposal outline → `{proposal_path.name}`"""

    if task_id:
        tg_send(tg_msg, callback_buttons=f"✉️ Stage Email|swarm:stage-email:{task_id},✏️ Revise|swarm:revise:{task_id},❌ Discard|swarm:discard:{task_id}")
        update_task(task_id, "awaiting_review", f"bizdev drafts ready for {company} — fit: {research.get('fit_score', '?')}")
    else:
        tg_send(tg_msg)

    log(SWARM, "Pipeline complete")
    print(json.dumps(bundle, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prospect", help="Company or person name")
    parser.add_argument("--url", help="Website URL")
    parser.add_argument("--brief-file", help="Path to JSON brief file")
    parser.add_argument("--task-id", help="Task ledger ID")
    args = parser.parse_args()

    if args.brief_file:
        brief = json.loads(Path(args.brief_file).read_text())
    elif args.prospect:
        brief = {"company": args.prospect, "url": args.url or ""}
    else:
        parser.error("Either --prospect or --brief-file required")

    run(brief, task_id=args.task_id)


if __name__ == "__main__":
    main()
