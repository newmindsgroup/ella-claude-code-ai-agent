#!/usr/bin/env python3
"""One-shot import of brand canon into the memory vault.

Run after first deploy to seed the agent's memory with the canonical facts,
relationships, preferences, and goals that should be treated as ground truth
across all future sessions.

Usage:
    MEM_DIR={{TENANT_AGENT_HOME}}/memory python3 _memory_import_canon.py

Customize the `memories` list below for your tenant. The agent will reference
these whenever it answers a question, drafts content, or plans a move — they
become baseline `confidence: 1.0` facts the LLM can rely on without
re-discovering them every session.

Memory types (must match memory-vault.sh schema):
    fact          — objective truth about the tenant / business / world
    relationship  — about a person (family, client, collaborator)
    preference    — how the tenant likes to work / communicate / build
    goal          — a target with a horizon
    decision      — a choice already made, locked in
    pattern       — a recurring shape the agent should recognize
    commitment    — a promise made to a person with a deadline
    context       — situational state that's true right now

Tags are free-form lowercase-kebab-case strings. Use them generously — they
drive semantic recall later.
"""
import os
import subprocess

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


# ─────────────────────────────────────────────────────────────────────────────
# CUSTOMIZE THIS LIST FOR YOUR TENANT BEFORE RUNNING.
# Each tuple: (type, text, tags, confidence)
#
# The examples below are placeholder shapes — replace with your real facts.
# A typical first-deploy canon import is 20–40 memories spanning:
#   - personal/founder background
#   - family + close collaborators (privacy-sensitive, mark as private)
#   - faith / values / operating principles
#   - business entity architecture + entity-separation rules
#   - brand positioning + ICP + archetypes + voice DNA
#   - services + offers + pricing
#   - notable career credentials + case studies
#   - signature phrases
#   - active goals (with deadlines for the deadline-watcher)
# ─────────────────────────────────────────────────────────────────────────────
memories = [
    # ── PERSONAL BACKGROUND ────────────────────────────────────────────────
    # ("fact",
    #  "{{TENANT_PERSON_FULL_NAME}} — short bio, where based, languages spoken, years of experience.",
    #  ["founder","background","origin"], 1.0),

    # ── FAMILY (privacy-sensitive — flag private!) ──────────────────────────
    # ("relationship",
    #  "<Partner/Spouse name> — role + relationship to tenant. Privacy framing: how to refer to them publicly vs privately.",
    #  ["family","partner","private"], 1.0),

    # ── VALUES & OPERATING PRINCIPLES ───────────────────────────────────────
    # ("fact",
    #  "Operating principle: <e.g. integrity-first; clarity over cleverness; work-life balance>. Shows up as <concrete behaviors>.",
    #  ["values","principles"], 1.0),

    # ── BUSINESS ENTITIES + SEPARATION RULES ────────────────────────────────
    # ("fact",
    #  "Business entity architecture: <Brand A> is <description>. <Brand B> is <description>. {{TENANT_WEBSITE_URL}} is the public-facing front door.",
    #  ["business","entity-structure"], 1.0),
    # ("fact",
    #  "Entity separation rule: never mention <Other Brand / Holding Co> in public-facing output for {{TENANT_PERSON_FULL_NAME}} unless explicitly approved.",
    #  ["entity-separation","privacy","client-facing"], 1.0),

    # ── BRAND POSITIONING ───────────────────────────────────────────────────
    # ("fact",
    #  "Positioning statement: <one-paragraph positioning that answers who-for, what-pain, what-outcome>.",
    #  ["positioning","brand"], 1.0),
    # ("fact",
    #  "Ideal Client Profile: <segment + revenue-stage + pain + desired-outcome + decision-makers>.",
    #  ["ICP","target"], 1.0),

    # ── VOICE ───────────────────────────────────────────────────────────────
    # ("fact",
    #  "Voice DNA: <primary descriptors>. DO: <patterns to use>. DO NOT: <patterns + banned phrases to avoid>.",
    #  ["voice","brand","writing"], 1.0),

    # ── SERVICES / OFFERS ───────────────────────────────────────────────────
    # ("fact",
    #  "Core service pillars: (1) <pillar 1>. (2) <pillar 2>. (3) <pillar 3>.",
    #  ["services","pillars"], 1.0),
    # ("fact",
    #  "Signature offers + pricing: <Offer name> — <description> — <price>.",
    #  ["services","offers","pricing"], 1.0),

    # ── GOALS ───────────────────────────────────────────────────────────────
    # ("goal",
    #  "Active goal: <what + by when + why it matters>.",
    #  ["goal","priority"], 0.95),
]


if __name__ == "__main__":
    if not memories:
        print("ERROR: no memories defined. Edit this file to add your canonical")
        print("       facts before running the import.")
        raise SystemExit(2)

    print(f"Importing {len(memories)} memories from brand canon...\n")
    added = 0
    for type_, text, tags, conf in memories:
        mid = add(type_, text, tags, conf)
        if mid:
            added += 1
    print(f"\nDone — {added}/{len(memories)} memories imported.")
