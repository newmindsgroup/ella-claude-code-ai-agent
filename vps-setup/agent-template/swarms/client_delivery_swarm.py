#!/usr/bin/env python3
"""client-delivery-swarm — Brand Blueprint brief → full strategy deliverable.

Agents:
  1. Brief parser — extracts structured context from the raw brief
  2. Competitive analyst — maps the landscape, names key players
  3. Brand strategist — positioning, differentiation, pillars
  4. Visual direction writer — mood, references, aesthetic direction notes
  5. Document assembler — compiles all into a single coherent strategy doc

Usage:
  python3 client_delivery_swarm.py --brief "Client brief text" [--task-id t-XXXX]
  python3 client_delivery_swarm.py --brief-file /path/to/brief.json [--task-id t-XXXX]

Brief JSON schema:
  {
    "client_name": "Acme Corp",
    "contact": "Sarah Kim",
    "industry": "B2B SaaS",
    "current_situation": "...",
    "goals": "...",
    "competitors": ["Co A", "Co B"],
    "audience": "...",
    "budget_signal": "Brand Blueprint Intensive"
  }
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from swarm_base import (
    AGENT_HOME, CLAUDE_MODEL_FAST, CLAUDE_MODEL_MAIN,
    log, now_iso, recall_memories,
    run_agent, save_draft, save_memory, tg_send, update_task,
)

SWARM = "client-delivery"


def run(brief: dict, task_id: str | None = None) -> None:
    client = brief.get("client_name", "Client")
    log(SWARM, f"Starting — client: {client}")
    if task_id:
        update_task(task_id, "in_progress", f"client-delivery-swarm building strategy doc for {client}")

    # Recall any prior memories about this client
    client_memories = recall_memories(query=client, limit=5)
    prior = "\n".join([f"- {m['text']}" for m in client_memories]) if client_memories else "None"

    # --- Agent 1: Parse brief into structured context ---
    log(SWARM, "Agent 1: Parsing brief")
    parse_prompt = f"""You are a brand strategy consultant parsing a client brief. Extract structured context.

Raw brief:
{json.dumps(brief, indent=2)}

Prior context from memory: {prior}

Return JSON:
{{
  "client_name": "...",
  "industry": "...",
  "company_stage": "startup/growth/established",
  "primary_audience": "...",
  "current_brand_problem": "the core issue in one sentence",
  "business_goals": ["goal 1", "goal 2"],
  "competitors": ["co 1", "co 2", "co 3"],
  "differentiators": ["what makes them potentially different"],
  "constraints": ["budget/time/team constraints if mentioned"],
  "success_looks_like": "what a great outcome means for this client"
}}"""

    context_raw = run_agent(parse_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)
    try:
        import re, json as _json
        clean = re.sub(r"^```(?:json)?\s*", "", context_raw.strip(), flags=re.MULTILINE)
        clean = re.sub(r"\s*```$", "", clean.strip(), flags=re.MULTILINE)
        ctx = _json.loads(clean)
    except Exception:
        ctx = {**brief, "current_brand_problem": "", "business_goals": [], "success_looks_like": ""}

    # --- Agent 2: Competitive landscape ---
    log(SWARM, "Agent 2: Competitive analysis")
    comp_prompt = f"""You are a brand strategist mapping the competitive landscape for {client}.

Industry: {ctx.get('industry', 'unknown')}
Known competitors: {', '.join(ctx.get('competitors', []))}
Client's potential differentiators: {', '.join(ctx.get('differentiators', []))}

Analyze the competitive landscape and identify:
1. How competitors typically position (the generic playbook)
2. The white space — what positioning angles are underused
3. The "table stakes" that {client} must meet to compete
4. One contrarian positioning opportunity

Keep it tight — 250 words max. Be specific about named players where possible."""

    comp_analysis = run_agent(comp_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Agent 3: Brand positioning & strategy ---
    log(SWARM, "Agent 3: Brand positioning")
    strategy_prompt = f"""You are a senior brand strategist building the positioning for {client}.

Client context:
- Industry: {ctx.get('industry', '')}
- Core brand problem: {ctx.get('current_brand_problem', '')}
- Primary audience: {ctx.get('primary_audience', '')}
- Business goals: {', '.join(ctx.get('business_goals', []))}
- Success looks like: {ctx.get('success_looks_like', '')}

Competitive landscape summary:
{comp_analysis}

Produce:
1. **Positioning Statement** (one crisp sentence — what they do, for whom, differently than whom)
2. **Brand Promise** (what the audience can always expect)
3. **3 Brand Pillars** (the themes that anchor all content and communication)
4. **Voice Direction** (3 adjectives with brief explanation of what each means in practice)
5. **The Big Idea** (the single organizing idea behind the brand — the thing that makes it coherent)

Format clearly with bold headers. Be specific and opinionated — no hedge language."""

    strategy_doc = run_agent(strategy_prompt, model=CLAUDE_MODEL_MAIN, max_tokens=1200, timeout=120)

    # --- Agent 4: Visual direction ---
    log(SWARM, "Agent 4: Visual direction notes")
    visual_prompt = f"""You are a creative director writing visual direction notes for {client}'s brand refresh.

Brand positioning summary:
{strategy_doc[:800]}

Industry: {ctx.get('industry', '')}
Audience: {ctx.get('primary_audience', '')}

Write visual direction notes (NOT a design brief — these are direction notes for the designer):
1. **Overall aesthetic feeling** — 2-3 sentences on the visual world this brand lives in
2. **Color direction** — the emotional territory, not specific hex codes
3. **Typography direction** — character of type (geometric/humanist/editorial/etc.) and what it should feel like
4. **Photography / imagery style** — what kinds of images, what to avoid
5. **What to avoid** — specific things that would feel off-brand

150-200 words. Confident, specific direction."""

    visual_notes = run_agent(visual_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Agent 5: Assemble final strategy document ---
    log(SWARM, "Agent 5: Assembling strategy doc")
    assemble_prompt = f"""Assemble a clean strategy document for {client} from these components.

## Brief Summary
Client: {client}
Industry: {ctx.get('industry', '')}
Core problem: {ctx.get('current_brand_problem', '')}
Primary audience: {ctx.get('primary_audience', '')}

## Competitive Landscape
{comp_analysis}

## Brand Strategy
{strategy_doc}

## Visual Direction
{visual_notes}

Format as a professional strategy document with:
- Clean section headers (no emoji)
- Executive summary at the top (3 bullets: situation, opportunity, recommendation)
- Each section clearly labeled
- Confident, direct language — no hedge words like "could", "might", "potentially"

This is a client-facing document. Daniel's name goes on it."""

    final_doc = run_agent(assemble_prompt, model=CLAUDE_MODEL_MAIN, max_tokens=2500, timeout=150)

    # --- Save outputs ---
    log(SWARM, "Saving deliverables")
    slug = client.lower().replace(" ", "-")[:30]
    ts = now_iso()[:10]

    doc_path = save_draft(SWARM, f"{slug}-strategy-{ts}.md", final_doc)
    comp_path = save_draft(SWARM, f"{slug}-competitive-{ts}.md", comp_analysis)
    visual_path = save_draft(SWARM, f"{slug}-visual-direction-{ts}.md", visual_notes)

    bundle = {
        "client": client, "generated_at": now_iso(),
        "strategy_doc": str(doc_path),
        "competitive_analysis": str(comp_path),
        "visual_direction": str(visual_path),
    }
    save_draft(SWARM, f"{slug}-bundle-{ts}.json", json.dumps(bundle, indent=2))

    # Save memory
    save_memory(
        "relationship",
        f"{client} — Brand Blueprint deliverable generated {ts}. Problem: {ctx.get('current_brand_problem', '')}",
        f"client,brand-blueprint,{slug}",
        "client-delivery-swarm", 0.9
    )

    # Telegram notification
    def esc(s: str) -> str:
        for c in r"_*[]()~`>#+-=|{}.!\\":
            s = s.replace(c, f"\\{c}")
        return s

    tg_msg = f"""⚙️ *client\\-delivery\\-swarm* — {esc(client)} complete

*3 deliverables ready:*
• Strategy doc → `{doc_path.name}`
• Competitive analysis → `{comp_path.name}`
• Visual direction notes → `{visual_path.name}`

_All in_ `{str(AGENT_HOME / 'drafts' / SWARM)}`"""

    if task_id:
        tg_send(tg_msg, callback_buttons=f"✅ Approve|swarm:approve:{task_id},✏️ Revise|swarm:revise:{task_id}")
        update_task(task_id, "awaiting_review", f"Brand Blueprint deliverable ready for {client}")
    else:
        tg_send(tg_msg)

    log(SWARM, "Pipeline complete")
    print(json.dumps(bundle, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--brief", help="Client brief text")
    parser.add_argument("--client", help="Client name")
    parser.add_argument("--brief-file", help="Path to JSON brief file")
    parser.add_argument("--task-id", help="Task ledger ID")
    args = parser.parse_args()

    if args.brief_file:
        brief = json.loads(Path(args.brief_file).read_text())
    elif args.brief:
        brief = {"client_name": args.client or "Client", "current_situation": args.brief}
    else:
        parser.error("Either --brief or --brief-file required")

    run(brief, task_id=args.task_id)


if __name__ == "__main__":
    main()
