#!/usr/bin/env python3
"""One-shot import of Daniel's brand canon into the memory vault.
Run: MEM_DIR={{TENANT_AGENT_HOME}}/memory python3 _memory_import_canon.py
"""
import json, os, sys, subprocess, datetime

SCRIPT = "{{TENANT_AGENT_HOME}}/scripts/memory-vault.sh"
os.environ.setdefault("MEM_DIR", "{{TENANT_AGENT_HOME}}/memory")

def add(type_, text, tags, confidence=0.95):
    result = subprocess.run(
        ["bash", SCRIPT, "add",
         "--type", type_,
         "--text", text,
         "--tags", ",".join(tags),
         "--source", "brand-canon-import",
         "--confidence", str(confidence)],
        capture_output=True, text=True
    )
    mid = result.stdout.strip()
    if mid:
        print(f"  ✓ {mid}  [{type_}] {text[:70]}")
    else:
        print(f"  ✗ FAILED: {result.stderr.strip()[:120]}")
    return mid

memories = [
    # ── PERSONAL BACKGROUND ─────────────────────────────────────────────────
    ("fact",
     "Daniel Gonell — born 1985 in the Dominican Republic. Moved to the United States and built a 20+ year career in design, branding, UX, and AI implementation. Based in Santo Domingo, DR (remote/travel). Originally based in Atlanta, Georgia.",
     ["daniel","background","origin","career","dominican-republic"], 1.0),

    ("fact",
     "Daniel is bilingual — English and Spanish, both at full professional proficiency. Born in DR, built career in the US.",
     ["daniel","language","bilingual","english","spanish"], 1.0),

    ("fact",
     "Daniel has 17+ years of professional experience spanning brand strategy, UX design, no-code development, CRM implementation, and AI-driven business automation.",
     ["daniel","experience","skills","career"], 1.0),

    # ── FAMILY ──────────────────────────────────────────────────────────────
    ("relationship",
     "Lorena — Daniel's wife, married ~20 years. Co-owner of New Minds Group. Family is Daniel's deepest priority. Her name is public as co-owner; family-life framing stays personal.",
     ["lorena","family","wife","new-minds-group","private"], 1.0),

    ("relationship",
     "Diego — Daniel's older son, born 2017. Private — not to be used in public-facing content without explicit direction.",
     ["diego","family","son","private"], 1.0),

    ("relationship",
     "Oliver — Daniel's younger son, born 2021. Private — not to be used in public-facing content without explicit direction.",
     ["oliver","family","son","private"], 1.0),

    # ── FAITH & VALUES ──────────────────────────────────────────────────────
    ("fact",
     "Daniel runs a Bible-believing, Christ-centered household. Faith is a foundational operating principle — shapes how he builds relationships, runs the business with integrity, and parents. Shows up as leading with integrity, treating clients as people first, working hard but not worshipping work. Not worn on the sleeve; expressed through behavior, not statements.",
     ["daniel","faith","values","integrity","christ"], 1.0),

    # ── WORK LOVES & MOTIVATION ─────────────────────────────────────────────
    ("preference",
     "Daniel's deepest professional love is the zero-to-one phase of building a business — naming it, defining its essence, brand identity, visual system, marketing, and operational processes from scratch. He's most alive in the architect role, not day-to-day execution.",
     ["daniel","work","zero-to-one","motivation","architect"], 1.0),

    ("preference",
     "Daniel describes AI-assisted building as 'vibe coding' — a superpower that lets one person with AI do what used to require large teams, long timelines, and large budgets. He frames this as a lever he wants other founders to experience.",
     ["daniel","ai","vibe-coding","leverage","motivation"], 1.0),

    ("preference",
     "Daniel prefers to architect and strategize rather than execute day-to-day. He wants skilled collaborators (from New Minds Group or extended networks) to run implementation. His superpower is seeing the whole system before it exists.",
     ["daniel","work-style","delegation","architect","strategy"], 1.0),

    # ── PERSONAL INTERESTS ──────────────────────────────────────────────────
    ("fact",
     "Daniel's personal interests outside work: aggressive inline skating, surf skating, surfing, skim boarding. Electronic music (deep house, tech house, 124–126 BPM) and jazz. DJing at home for friends on a Pioneer XDJ-RX3. Studies brand and customer experience when traveling — Zurich left a lasting impression. Loves clean, intentional design.",
     ["daniel","personal","hobbies","skating","music","dj"], 1.0),

    # ── AESTHETIC SENSIBILITY ───────────────────────────────────────────────
    ("preference",
     "Daniel's design aesthetic: minimalist (lots of clean white space), mature (not trendy or gimmicky), modern, timeless (not dated in 2 years), forward-thinking, Apple-like. He names Apple as his explicit reference point. Applies to his website, brand materials, and how he directs designers.",
     ["daniel","aesthetic","design","minimalist","apple","style"], 1.0),

    # ── MISSION & VISION ────────────────────────────────────────────────────
    ("fact",
     "Daniel's mission: inspire and empower young entrepreneurs, solopreneurs, and small teams to see what's possible with AI, design, and systems thinking. Core belief: 'If I can see it, I want others to see it.' He gives them usable clarity, not inspiration.",
     ["daniel","mission","inspiration","founders","empowerment"], 1.0),

    ("fact",
     "Daniel's purpose statement: 'To pass on the clarity I was given — so a generation of founders can build businesses that outlast the trend cycle.' Rooted in being first-generation immigrant — knowledge transfers across generations.",
     ["daniel","purpose","vision","founders","legacy"], 1.0),

    # ── BUSINESS ENTITIES ───────────────────────────────────────────────────
    ("fact",
     "Business entity architecture: New Minds Group is Daniel's primary consulting brand (co-owned with Lorena, since 2011) — branding, UX, digital strategy, AI implementation. e²=p, Inc. is the legal parent entity. CreateMomento is a DBA/venture under New Minds Group, not a separate company — SaaS platform for content publishing and AI automation. {{TENANT_LINUX_USER}}.com is the personal brand front door. Future Fluent is his newsletter.",
     ["business","new-minds-group","createmomento","entity","structure"], 1.0),

    ("fact",
     "Entity separation rule: In any client-facing output as Daniel Gonell, he is a solo consultant. Never name New Minds Group or CreateMomento in Daniel's personal brand materials unless specifically relevant and approved.",
     ["entity-separation","brand","client-facing","rules"], 1.0),

    # ── BRAND POSITIONING ───────────────────────────────────────────────────
    ("fact",
     "Daniel's positioning: 'I design brand systems and digital experiences that convert — guiding service-based founders, agencies, and creators through strategy, UX, and automation to replace guesswork with clarity and scale their business with confidence.'",
     ["positioning","brand","messaging","ICP"], 1.0),

    ("fact",
     "Daniel's Ideal Client Profile (ICP): service-based founders, agencies, creators. Revenue stage $100K–$1M annually. Core pain: overwhelmed by tools, decisions, fragmented systems. Desired outcome: clarity, systems that scale, a brand that converts. Roles: Founder, Creative Director, Agency Owner, Consultant. Action-oriented but needs trusted expert guidance.",
     ["ICP","target-client","positioning","services"], 1.0),

    ("fact",
     "Daniel's brand archetypes: Sage (primary) — wisdom, clarity, expertise, trusted advisor. Creator (secondary) — craft, innovation, bringing ideas to life. This pairing differentiates from AI-adjacent consultants who lean Magician or Hero (reads as hype). Sage-first = trusted advisor, not vendor.",
     ["brand","archetypes","sage","creator","voice"], 1.0),

    # ── SERVICES & OFFERS ───────────────────────────────────────────────────
    ("fact",
     "Daniel's four core service pillars: (1) Brand Systems & Positioning — full brand identity, positioning, messaging, visual identity systems. (2) UX Design & Digital Experience — website design, accessible UX, conversion optimization. (3) AI & Business Automation — custom AI assistants, no-code automation, CRM, workflow optimization. (4) No-Code & CRM Systems — no-code tool stacks, CRM setup, client portals.",
     ["services","pillars","brand","UX","AI","CRM"], 1.0),

    ("fact",
     "Daniel's four signature offers — ladder from strategic to ongoing: (1) Brand Blueprint Intensive — complete brand strategy, positioning, messaging, visual identity. (2) Launch-Ready Website — full website design and development with brand alignment. (3) AI Ops System Setup — custom AI assistant, workflow automation, operational system integration. (4) CX Clarity Retainer — ongoing strategic advisory (brand, UX, automation) monthly or quarterly.",
     ["services","offers","brand-blueprint","website","ai-ops","retainer"], 1.0),

    ("fact",
     "Brand Blueprint Intensive pricing as of May 2026: $12,000. Updated from earlier $10,000 rate.",
     ["pricing","brand-blueprint","services","revenue"], 1.0),

    # ── CAREER HIGHLIGHTS ───────────────────────────────────────────────────
    ("fact",
     "Daniel's notable career credentials and proof points: Brand work with Coca-Cola, Pepsi, Canada Dry, 7-Up, Mission Foods (AI recipe/drink assistants). Country-level branding for Dominican Republic Export & Investment Center (2004–2007). Accessibility-first UX for KCDD, GCDD, NCCDD, Disability Rights North Carolina. Co-founder of New Minds Group (since 2011) and CreateMomento.",
     ["career","credentials","clients","proof-points","enterprise"], 1.0),

    ("fact",
     "Daniel's certifications: UX Design — NYU School of Professional Studies (2014–2015). UX Design Management — Interaction Design Foundation (2019–2020). Branding Certificate — Parsons School of Design (2019). Design Business Development — Pratt Institute (2014). Inbound Marketing — HubSpot Academy (2019–2021).",
     ["certifications","education","credentials","career"], 1.0),

    ("fact",
     "Key case study outcomes: Lift-and-Learn Smart Displays — +28% engagement increase for retail client (AI-powered retail displays). Custom AI for Designers — deployed custom AI assistant for design agency workflow. Accessible UX Redesign — WCAG-compliant redesign resulting in 3x usage improvement. Superior One Roofing — 40% lead growth, 25% brand recognition lift via digital strategy.",
     ["case-studies","proof-points","outcomes","results"], 1.0),

    # ── BRAND VOICE RULES ───────────────────────────────────────────────────
    ("fact",
     "Daniel's voice DNA: direct but empathetic, strategic not salesy, clarity over cleverness, calm confidence. DO: short declarative sentences, name the pain specifically, use concrete examples. DO NOT: 'revolutionary/disruptive/game-changing/unlock your potential', exclamation-heavy hype, corporate jargon, passive voice. No emojis in client-facing written copy.",
     ["voice","brand","writing","rules","tone"], 1.0),

    ("fact",
     "Daniel's signature phrases (use across site, social, newsletter, speaking): 'Build Brands, Systems, and AI That Work for You.' | 'Turn brand and tech chaos into clarity, scale, and systems.' | 'You think you need a better website. What you need is a system that converts.' | 'I don't do fluff. I do function.' | 'Strategy. Systems. Scale.' | 'Clarity over cleverness. Function over flash.'",
     ["voice","phrases","messaging","brand","copy"], 1.0),

    # ── GOALS & AMBITIONS ───────────────────────────────────────────────────
    ("goal",
     "Website ambition ({{TENANT_LINUX_USER}}.com): build a site that wins at the 'Tier 2' level — not just technically impressive, but with a signature interaction that proves the brand thesis. Top priority feature: 'Ask Daniel' — a grounded RAG-powered site assistant over the brand canon. Proves the AI thesis. Target: Awwwards-level quality.",
     ["goal","website","ask-daniel","RAG","design"], 0.95),

    ("goal",
     "Daniel's business model goal: transition from project-by-project consulting to a portfolio of scalable offers — Brand Blueprint Intensives, Launch-Ready Websites, AI Ops System Setups, and a CX Clarity Retainer for ongoing advisory. Build systems that run with him, not on top of him.",
     ["goal","business","revenue","scalable","model"], 0.95),

    ("goal",
     "Daniel's mission-level goal: inspire and empower a generation of young entrepreneurs and solopreneurs to see what's possible with AI, design, and systems. Public speaking, newsletter (Future Fluent), and content are the channels. Long-term: become the reference for 'what's possible for a small team with AI.'",
     ["goal","mission","speaking","newsletter","future-fluent","impact"], 0.95),

    # ── NEWSLETTER ──────────────────────────────────────────────────────────
    ("fact",
     "Future Fluent is Daniel's newsletter — lives under his personal brand ({{TENANT_LINUX_USER}}.com). Theme: what's possible for founders with AI, design, and systems. Voice: Sage/Creator. Audience: service-based founders, solopreneurs, small teams. Not yet live at time of last canon update.",
     ["future-fluent","newsletter","content","brand"], 0.95),

    # ── STORYBRAND FRAMEWORK ────────────────────────────────────────────────
    ("fact",
     "Daniel's StoryBrand positioning: He is the GUIDE, not the hero. The hero is the service-based founder at $100K-$1M. The three-step plan: (1) Clarity — Brand Blueprint Intensive. (2) Systems — Launch-Ready Website + AI Ops System Setup. (3) Scale — CX Clarity Retainer. Failure avoided: another year guessing, another rebuild that doesn't convert, losing to AI-savvy competitors.",
     ["storybrand","positioning","guide","hero","messaging"], 1.0),
]

print(f"Importing {len(memories)} memories from brand canon...\n")
added = 0
for type_, text, tags, conf in memories:
    mid = add(type_, text, tags, conf)
    if mid:
        added += 1

print(f"\nDone — {added}/{len(memories)} memories imported.")
