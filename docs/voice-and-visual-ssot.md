# Brand voice + visual single source of truth

The pattern that makes the agent trustworthy with brand-aligned output. Two markdown files, declared in precedence order, read by the agent (and any voice-aware sub-agent) before drafting copy or generating visuals.

---

## The pattern

```
   ┌──────────────────────┐         ┌──────────────────────┐
   │  Voice Playbook      │         │  DESIGN.md           │
   │  (brand voice SSOT)  │         │  (visual SSOT)       │
   │                      │         │                      │
   │  • Voice DNA         │         │  • Visual theme      │
   │  • Banned phrases    │         │  • Color palette     │
   │  • Tone calibration  │         │  • Typography        │
   │  • Channel rules     │         │  • Components        │
   │                      │         │  • Layout principles │
   │  Read before any     │         │  • Do's and don'ts   │
   │  human-facing copy   │         │                      │
   └──────────┬───────────┘         │  Read before any     │
              │                     │  UI / image / deck   │
              │                     └──────────┬───────────┘
              │                                │
              ▼                                ▼
    ┌─────────────────────┐        ┌──────────────────────┐
    │ linkedin-content-   │        │ image-prompt-        │
    │ creator             │        │ engineer             │
    │                     │        │                      │
    │ carousel-growth-    │        │ document-generator   │
    │ engine              │        │ (visual artifacts)   │
    │                     │        └──────────────────────┘
    │ ai-citation-        │
    │ strategist          │
    │                     │
    │ document-generator  │
    │ (copy)              │
    └─────────────────────┘
```

Both files are markdown. Both live at the project root. Both get read by the relevant sub-agents at draft time.

---

## Why two files

`AGENTS.md` is the open standard ([agents.md](https://agents.md/)) for "how to build" — it tells AI agents what kind of project they're in, what's in scope, what's out of bounds, who the audience is. The voice playbook is a deeper canonical reference for VOICE specifically — it's referenced from `AGENTS.md` but lives separately because it's longer and gets updated independently.

`DESIGN.md` is the [Stitch DESIGN.md format](https://stitch.withgoogle.com/docs/design-md/format/) popularized by [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) — the visual companion to AGENTS.md. AI tools (Cursor, v0, Lovable, Claude Code, Stitch) read it before generating UI.

---

## Voice Playbook structure

The [example voice playbook](../examples/voice-playbook.example.md) walks through 8 sections. The non-negotiable ones:

1. **Voice DNA in one paragraph** — specific, no generic adjectives. AI agents read this paragraph as a top-level prompt.
2. **Voice attributes (the checklist)** — applied to every draft.
3. **Banned phrases** — absolute, no exceptions. A draft containing any banned phrase is incomplete.
4. **Phrases to reuse** — signature lines.
5. **Channel-specific tone calibration** — LinkedIn vs. newsletter vs. email reply vs. SMS.
6. **The canonical Voice DNA spec** — the section voice-aware sub-agents quote verbatim.

### How voice-aware sub-agents enforce it

When `07-install-agency-agents.sh` runs with `BRAND_VOICE_PATHS_FILE` set, it injects this block at the top of the system prompt for each voice-aware agent:

```markdown
## 🔒 Brand Voice Lock — READ FIRST (single source of truth)

Before producing ANY human-facing copy, read the brand voice from these files (in order):
  - <path 1>
  - <path 2>
  - ...

Apply the Voice DNA documented in those files. If your draft conflicts with the
playbook, the playbook wins — rewrite, do not compromise. This rule overrides
any tone/personality guidance below.
```

The 5 voice-aware agents are:
- `linkedin-content-creator`
- `carousel-growth-engine`
- `ai-citation-strategist`
- `image-prompt-engineer`
- `document-generator`

---

## DESIGN.md structure

The [example DESIGN.md](../examples/DESIGN.md) walks through the 9-section Stitch format:

1. Visual Theme & Atmosphere
2. Color Palette & Roles
3. Typography Rules
4. Component Stylings
5. Layout Principles
6. Depth & Elevation
7. Do's and Don'ts (anti-patterns + AI-image tells to avoid)
8. Responsive Behavior
9. Agent Prompt Guide (quick references + ready-to-use prompt fragments)

### Frontmatter

The top of every DESIGN.md should declare:

```yaml
---
version: 1.0.0
name: <Brand Name>
owner: <Org>
last_updated: <YYYY-MM-DD>
description: "One-paragraph description AI agents read as a top-level prompt before drilling into sections..."
canonical_sources:
  tokens: design-system/tokens/tokens.json
  visual_identity: <path-to-deeper-doc>
---
```

`description` is the single most important field — that paragraph becomes the agent's overview when it's first asked to generate something visual.

### Tokens file as machine canonical

If you have a real implemented design system with a `tokens.json`, declare it in `canonical_sources.tokens`. The convention is: **DESIGN.md is the agent navigator; `tokens.json` is machine-canonical.** When they disagree, `tokens.json` wins and DESIGN.md gets updated to match. This avoids drift between human-readable rules and the values your build pipeline ships.

---

## Wiring it up in CLAUDE.md

For the user-level Claude Code config (`~/.claude/CLAUDE.md`):

```markdown
## Brand Voice — Single Source of Truth

For ANY human-facing copy, the canonical voice spec lives in this exact order:
1. `brand-voice-playbook.md` (project root)
2. `AGENTS.md` (project root)

If those files exist, read them before drafting. If a sub-agent provides
its own tone/personality guidance that conflicts with the playbook, the
playbook wins.

Banned phrases (do not use): "thrilled to", "excited to share",
"in today's fast-paced world", "humbled to", "delve into", "in the realm of",
<your additions>

## Brand Visual — Single Source of Truth

For ANY UI / image / deck / visual artifact:
1. `DESIGN.md` (project root)
2. `design-system/tokens/tokens.json` (machine canonical)
3. `<other supporting visual docs>`

DESIGN.md is the navigator; tokens.json wins on conflicts.
```

The chief-of-staff agent's behavioral spec ([`vps-setup/agent-template/CLAUDE.md.tmpl`](../vps-setup/agent-template/CLAUDE.md.tmpl)) inherits this pattern and adds tenant-specific paths via `{{TENANT_VOICE_PLAYBOOK_PATH}}` substitution.

---

## Reusing this for client projects

If you're a consultant/agency standing up Ella for client engagements, the voice + DESIGN.md pattern is itself a deliverable:

1. Run a brand discovery session with the client
2. Use the [examples](../examples/) as templates — fill in their voice DNA, banned phrases, palette, typography, layout principles
3. Drop the completed `voice-playbook.md` and `DESIGN.md` into the client's repo
4. Their AI tools (Cursor, v0, Lovable, Claude Code, Cowork) now generate brand-consistent output without you re-explaining the rules every session

This is what turns the brand voice + visual rules from "tribal knowledge in your head" into "version-controlled, agent-readable, contractually deliverable artifacts."

---

## Drift detection

A drift-scanner sub-agent (or skill) reads recently published content and flags:
- Banned-phrase violations
- Tone-drift hits (specific patterns the playbook said to avoid)
- Entity-separation violations (if your business is structured with multiple legal entities)
- AI-tells (the patterns in `25_AI_Tell_Guidelines.md` or your equivalent)

Run it weekly against your last 7 days of published output. Any hits feed back into the voice playbook (tighten the rule) or the source content (rewrite). Over time, drift drops to near-zero.
