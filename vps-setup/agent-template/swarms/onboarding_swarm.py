#!/usr/bin/env python3
"""onboarding-swarm — new client → welcome kit + kickoff agenda + project timeline.

Agents:
  1. Client profiler — structures all known info
  2. Welcome email writer — warm, on-brand, sets the tone
  3. Kickoff agenda builder — structured meeting plan
  4. Project timeline generator — phased milestones
  5. Assembler — compiles into a sharable welcome kit

Usage:
  python3 onboarding_swarm.py --client "Acme Corp" [--contact "Sarah Kim"] [--task-id t-XXXX]
  python3 onboarding_swarm.py --brief-file /path/to/brief.json [--task-id t-XXXX]

Brief JSON schema:
  {
    "client_name": "Acme Corp",
    "contact": "Sarah Kim",
    "service": "Flagship Engagement",
    "start_date": "2026-05-14",
    "kickoff_date": "2026-05-15",
    "duration_weeks": 4,
    "context": "Background on this client"
  }
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

SWARM = "onboarding"

# Tenant identity — substituted by render-tenant.sh at deploy time.
TENANT_NAME = "{{TENANT_PERSON_FULL_NAME}}"
TENANT_FIRST_NAME = "{{TENANT_PERSON_FIRST_NAME}}"


def run(brief: dict, task_id: str | None = None) -> None:
    client = brief.get("client_name", "Client")
    contact = brief.get("contact", "")
    service = brief.get("service", "Flagship Engagement")
    start_date = brief.get("start_date", "TBD")
    kickoff_date = brief.get("kickoff_date", "TBD")
    duration = brief.get("duration_weeks", 4)
    context = brief.get("context", "")

    log(SWARM, f"Starting — client: {client}, service: {service}")
    if task_id:
        update_task(task_id, "in_progress", f"onboarding-swarm building kit for {client}")

    # Recall prior memories
    prior = recall_memories(query=f"{client} {contact}", limit=4)
    prior_text = "\n".join([f"- {m['text']}" for m in prior]) if prior else "First engagement"

    voice_dna = read_brand_voice()

    # --- Agent 1: Welcome email ---
    log(SWARM, "Agent 1: Welcome email")
    welcome_system = f"""You are {TENANT_NAME}'s ghostwriter. Write client communications in their voice.
Voice: warm, direct, confident. Friend who knows what they're doing.
No corporate fluff. No "thrilled to have you aboard." Start with something specific.
{voice_dna[:1500] if voice_dna else ''}"""

    welcome_prompt = f"""Write a welcome email to a new client starting their engagement with {TENANT_FIRST_NAME}.

Client: {contact or client}
Company: {client}
Service: {service}
Start date: {start_date}
Kickoff: {kickoff_date}
Context: {context or prior_text}

Email should:
- Open with something specific (not generic excitement)
- Set clear expectations for the first week
- Give them 1-2 things to prepare before kickoff
- Feel personal, not templated
- Close warmly, sign as {TENANT_FIRST_NAME}

Format: SUBJECT: / BODY:"""

    welcome_email = run_agent(welcome_prompt, system=welcome_system, max_tokens=500, timeout=60)

    # --- Agent 2: Kickoff agenda ---
    log(SWARM, "Agent 2: Kickoff agenda")
    agenda_prompt = f"""Build a 60-minute kickoff meeting agenda for a {service} engagement.

Client: {client}
Date: {kickoff_date}
Service details: {service} — {duration} weeks

Create a practical, time-boxed agenda that:
- Opens with relationship-building (5 min)
- Clarifies the client's actual goals (not what they said in the brief, but what matters to them)
- Surfaces constraints and must-nots
- Aligns on working style and communication preferences
- Ends with clear next steps and owner

Format as:
[TIME] AGENDA ITEM — what to cover, what to get out of it

Keep it tight — a kickoff that respects everyone's time."""

    kickoff_agenda = run_agent(agenda_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Agent 3: Project timeline ---
    log(SWARM, "Agent 3: Project timeline")
    timeline_prompt = f"""Build a {duration}-week project timeline for a {service} for {client}.

Start: {start_date}
Kickoff: {kickoff_date}

Create a phased timeline with:
- Week-by-week milestones
- Key deliverables per phase
- Client review checkpoints (where their input is needed)
- Buffer built in (don't pack every week)

For a typical multi-week engagement, common phases are:
- Week 1: Discovery + audit
- Week 2: Strategy / planning
- Week 3: Draft deliverable
- Week 4: Refinement + handoff

Adapt for the actual service. Format as a clean table or structured list."""

    timeline = run_agent(timeline_prompt, model=CLAUDE_MODEL_FAST, max_tokens=600, timeout=60)

    # --- Agent 4: Assemble welcome kit ---
    log(SWARM, "Agent 4: Assembling welcome kit")
    kit_prompt = f"""Compile a client welcome kit for {client} starting a {service} with {TENANT_NAME}.

Include:
1. A brief intro section ("What to expect from this engagement")
2. How {TENANT_FIRST_NAME} works (communication style, response times, revision policy)
3. What the client needs to bring (assets, access, decisions)
4. Project timeline summary
5. Kickoff agenda

Keep it scannable — they'll read this once and refer back to it. Headers and bullets.
Professional but warm tone.

Source material:
TIMELINE:
{timeline}

KICKOFF AGENDA:
{kickoff_agenda}"""

    welcome_kit = run_agent(kit_prompt, model=CLAUDE_MODEL_MAIN, max_tokens=1200, timeout=120)

    # --- Save everything ---
    log(SWARM, "Saving onboarding kit")
    slug = client.lower().replace(" ", "-")[:30]
    ts = now_iso()[:10]

    email_path = save_draft(SWARM, f"{slug}-welcome-email-{ts}.md", welcome_email)
    agenda_path = save_draft(SWARM, f"{slug}-kickoff-agenda-{ts}.md", kickoff_agenda)
    timeline_path = save_draft(SWARM, f"{slug}-timeline-{ts}.md", timeline)
    kit_path = save_draft(SWARM, f"{slug}-welcome-kit-{ts}.md", welcome_kit)

    bundle = {
        "client": client, "generated_at": now_iso(),
        "welcome_email": str(email_path),
        "kickoff_agenda": str(agenda_path),
        "project_timeline": str(timeline_path),
        "welcome_kit": str(kit_path),
    }
    save_draft(SWARM, f"{slug}-bundle-{ts}.json", json.dumps(bundle, indent=2))

    # Save memory
    save_memory(
        "commitment",
        f"{client} / {contact} — {service} starts {start_date}, kickoff {kickoff_date}. Onboarding kit generated.",
        f"client,onboarding,{slug},commitment",
        "onboarding-swarm", 0.95
    )

    # Telegram notification
    def esc(s: str) -> str:
        for c in r"_*[]()~`>#+-=|{}.!\\":
            s = s.replace(c, f"\\{c}")
        return s

    tg_msg = f"""⚙️ *onboarding\\-swarm* — {esc(client)} kit ready

*Service:* {esc(service)}
*Kickoff:* `{esc(kickoff_date)}`

*4 pieces generated:*
• Welcome email → `{email_path.name}`
• Kickoff agenda → `{agenda_path.name}`
• Project timeline → `{timeline_path.name}`
• Welcome kit \(compiled\) → `{kit_path.name}`"""

    if task_id:
        tg_send(tg_msg, callback_buttons=f"✅ Send Email|swarm:send-welcome:{task_id},✏️ Revise|swarm:revise:{task_id}")
        update_task(task_id, "awaiting_review", f"Onboarding kit ready for {client} — {service}")
    else:
        tg_send(tg_msg)

    log(SWARM, "Pipeline complete")
    print(json.dumps(bundle, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", help="Client company name")
    parser.add_argument("--contact", help="Contact person name")
    parser.add_argument("--service", default="Flagship Engagement")
    parser.add_argument("--start-date")
    parser.add_argument("--kickoff-date")
    parser.add_argument("--brief-file", help="Path to JSON brief file")
    parser.add_argument("--task-id", help="Task ledger ID")
    args = parser.parse_args()

    if args.brief_file:
        brief = json.loads(Path(args.brief_file).read_text())
    elif args.client:
        brief = {
            "client_name": args.client,
            "contact": args.contact or "",
            "service": args.service,
            "start_date": args.start_date or "TBD",
            "kickoff_date": args.kickoff_date or "TBD",
        }
    else:
        parser.error("Either --client or --brief-file required")

    run(brief, task_id=args.task_id)


if __name__ == "__main__":
    main()
