# Tool-Leverage Heuristics

The autonomy playbook. This is what makes the agent *strategic* instead of reactive — it knows which tool combos to fire for which situations without you having to remember names.

These heuristics live in the chief-of-staff agent's `CLAUDE.md` (rendered from [`vps-setup/agent-template/CLAUDE.md.tmpl`](../vps-setup/agent-template/CLAUDE.md.tmpl)) so the agent reads them before deciding how to handle every incoming message.

---

## The trigger → tool combo table

| Trigger phrase or situation | Tools/agents to fire |
|---|---|
| "AI-search visibility" / "AEO" / "are we cited?" | `firecrawl_search` + `ai-citation-strategist` |
| "Write a LinkedIn post" / "thought leadership content" | Read voice playbook → `linkedin-content-creator` |
| "Generate a Midjourney/DALL-E/SD prompt" | Read `DESIGN.md` → `image-prompt-engineer` |
| "Build a deck/report/proposal as PDF/PPTX/DOCX" | `document-generator` (auto-defers to voice playbook) |
| "Production is down" / "service crashed" / "[your stack]'s broken" | `incident-response-commander` |
| "Ready to ship?" / "is this done?" | `reality-checker` |
| "Map this codebase" / "before I work on it" | `/graphify <path>` |
| "Find/explain X in this repo" (large repo) | `graphify query` if `graphify-out/` exists, else grep |
| "Optimize the agent stack costs" / "LLM cost" | `autonomous-optimization-architect` |
| "Multi-agent workflow" / "coordinate agents" | `agents-orchestrator` |
| "Dedupe contacts" / "entity resolution" / "merge across data sources" | `identity-graph-operator` |
| "Map every path through X" / "before we code" | `workflow-architect` |
| "Run a security/compliance check before merge" | `code-reviewer` (security-focused review) |
| "This query is slow" / "schema for X" | `database-optimizer` |
| "Research this prospect" / "competitive intel" | `firecrawl_*` + `research-agent` (or your equivalent) |
| "Set SLOs" / "error budget for X" / "observability gap" | `sre` |

---

## When NOT to reach for tools

- A trivial canon lookup will do. Don't fire `firecrawl_search` for "what's my tagline" — read the brand identity doc.
- The user explicitly says "skip the heavy lift" / "just answer in one line".
- The work is one-off shell or config — engineering rituals don't apply.
- The user is in conversational / meta mode ("how are you doing", "what do you know about me") — answer briefly from canon, no tool calls.

---

## How the agent decides

Per [`vps-setup/agent-template/CLAUDE.md.tmpl`](../vps-setup/agent-template/CLAUDE.md.tmpl), every incoming message gets routed in one of four ways:

| Classification | What it means | Action |
|---|---|---|
| **Trivial lookup** | Single fact, file path, status check, definition from canon | Answer directly with one tool call. Do not delegate. |
| **Specialized work** | Drafting, analysis, research, audit that matches a sub-agent's domain | Delegate via the Task tool. Pass tight context. |
| **Conversational** | Meta, identity, mood, casual check-in | Answer briefly from canon, no tool calls unless one is obviously needed. |
| **Ambiguous** | Intent unclear, scope unclear, missing one critical input | Ask exactly one clarifying question. |

The combo table above operates within "Specialized work." When the message matches a trigger, the agent fires the listed tool combo BEFORE drafting a reply.

---

## The brand-voice + brand-visual lock

Two non-negotiables that override everything else:

**Brand voice playbook** (`<your voice playbook path>`):
- ALWAYS read before producing any human-facing copy. Non-negotiable.
- Banned phrases are absolute. A draft containing any banned phrase is incomplete.

**Brand visual SSOT** (`DESIGN.md` at project root):
- ALWAYS read before generating any UI, image prompt, deck, or visual artifact.
- DESIGN.md is the navigator; `design-system/tokens/tokens.json` is machine-canonical. When they disagree, tokens.json wins.

These are enforced two ways:
1. **Inline injection** — script `07-install-agency-agents.sh` injects a "Brand Voice Lock" block at the top of voice-aware sub-agents (linkedin, carousel, ai-citation, image-prompt, document-generator) at install time.
2. **User-level CLAUDE.md precedence** — even non-voice-aware agents inherit the rule via the user-level `~/.claude/CLAUDE.md` declaration of voice precedence.

---

## How to extend

If you find your agent NOT firing a tool combo it should:

1. **Add the trigger phrase to the description** of the relevant sub-agent. Edit the upstream agent file, OR override its description by re-running `07-install-agency-agents.sh` with an updated `manifest.json`.
2. **Add the combo to your tenant's CLAUDE.md.tmpl** under "Tool-leverage heuristics."
3. **Re-render and re-deploy** — `bash vps-setup/scripts/render-tenant.sh tenants/<tenant>.yml`, then copy the rendered CLAUDE.md to the agent's home and restart `claude-agent.service`.

Per the operating-principles, **always commit the change** so it propagates to other tenants and survives re-deploys. The agent's CLAUDE.md should never be edited directly on the VPS without a corresponding commit to the template — that's how drift starts.

---

## Telltales of an under-leveraged agent

If you see the agent doing any of these, the heuristics need tightening:

- Grepping a large codebase instead of running `/graphify`
- Using `fetch` for JS-heavy sites instead of `firecrawl_scrape`
- Drafting copy without first reading the voice playbook (banned phrases sneak through)
- Generating image prompts without first reading DESIGN.md (palette + composition rules ignored)
- Trying to debug a production crash from scratch instead of routing to `incident-response-commander`
- Declaring work "done" without firing `reality-checker`

Every one of these is a missing trigger in the heuristics table above. Add it, render, deploy. Over time the table gets dense enough that the agent feels truly autonomous.
