# Context7 — Fullest Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Context7 from "wired in Ella reference template only" to "fully integrated across Daniel's live CoS on projectizer, the Ella reference template, and the skills-library codification layer" — covering install, smoke verification, skill access, an explicit `/docs` slash command, sub-agent awareness, dashboard observability, and a reusable runbook.

**Architecture:** Seven independently shippable tasks. Tasks 1-6 edit `.tmpl` SSOT files in two repos (`daniel-personal-brand` and `ella-claude-code-ai-agent`); each is committed atomically, pushed, then deployed via `render-and-deploy.sh` on projectizer. Task 5 (sub-agent awareness) edits the local `~/src/agency-agents` cherry-pick installer. Task 7 codifies the pattern in `ai-agent-skills-library`. Concurrent-committer hazard is mitigated by pulling + verifying HEAD before staging in each repo.

**Tech Stack:** bash, jq, npx, Claude Code MCP, Python 3 (dashboard sync), HTML/CSS/JS (dashboard), markdown (slash command + runbook).

**Spec:** `docs/superpowers/specs/2026-06-04-context7-fullest-integration-design.md`

---

## Pre-flight: shared setup

Run these once at the start of the implementation session, not per task.

- [ ] **Pre-1: Confirm local clones are present and current**

```bash
for r in ella-claude-code-ai-agent daniel-personal-brand ai-agent-skills-library; do
  cd "$HOME/code/$r" || exit 1
  echo "=== $r ==="
  git fetch --quiet
  git status --short
  git rev-parse HEAD
done
```

Expected: each repo present, working tree clean (apart from the Ella spec commit `de3aad7` already pushed), HEAD = origin/HEAD.

- [ ] **Pre-2: Confirm projectizer SSH access**

```bash
ssh projectizer 'whoami && uname -a' || ssh root@projectizer 'whoami && uname -a'
```

Expected: ssh resolves (either via `~/.ssh/config` alias or direct hostname). If neither works, set up the SSH alias before continuing — every deploy step below assumes `ssh projectizer` works.

- [ ] **Pre-3: Pin the Context7 reference source**

```bash
cat /Users/newmindsgroup/code/ella-claude-code-ai-agent/agent-stack/scripts/10-install-context7-mcp.sh | wc -l
```

Expected: 98 lines (the v0.22.0 Ella installer — the canonical source for Task 1.1).

---

## Task 1: Daniel repo parity backport (live install)

**Goal:** Daniel's live CoS on projectizer actually has Context7 registered with Claude Code.

**Files:**
- Create: `~/code/daniel-personal-brand/agent-stack/scripts/10-install-context7-mcp.sh` (copy from Ella)
- Create: `~/code/daniel-personal-brand/docs/context7-setup.md` (copy from Ella)
- Modify: `~/code/daniel-personal-brand/vps-setup/agent-template/.mcp.json.example.tmpl` (add `context7` block)
- Modify: `~/code/daniel-personal-brand/vps-setup/agent-template/CLAUDE.md.tmpl` (insert new §"Library / API docs" before §"Telegram formatting")
- Modify: `~/code/daniel-personal-brand/vps-setup/tenants/danielgonell.yml` (add `features.context7: true`)
- Modify: `~/code/daniel-personal-brand/agent-stack/scripts/install-all.sh` (append line 20)

- [ ] **Step 1.1: Pull + verify Daniel HEAD**

```bash
cd ~/code/daniel-personal-brand
git fetch --quiet && git pull --ff-only
git rev-parse HEAD
git log --oneline -3
```

Record the HEAD value. If `git pull` reports merge conflicts, STOP — someone is mid-edit. Resolve before continuing.

- [ ] **Step 1.2: Copy the installer script verbatim**

```bash
cp ~/code/ella-claude-code-ai-agent/agent-stack/scripts/10-install-context7-mcp.sh \
   ~/code/daniel-personal-brand/agent-stack/scripts/10-install-context7-mcp.sh
chmod +x ~/code/daniel-personal-brand/agent-stack/scripts/10-install-context7-mcp.sh
diff ~/code/ella-claude-code-ai-agent/agent-stack/scripts/10-install-context7-mcp.sh \
     ~/code/daniel-personal-brand/agent-stack/scripts/10-install-context7-mcp.sh
```

Expected: empty diff. The script is verbatim because it has no tenant-specific tokens.

- [ ] **Step 1.3: Copy the setup doc verbatim**

```bash
cp ~/code/ella-claude-code-ai-agent/docs/context7-setup.md \
   ~/code/daniel-personal-brand/docs/context7-setup.md
diff ~/code/ella-claude-code-ai-agent/docs/context7-setup.md \
     ~/code/daniel-personal-brand/docs/context7-setup.md
```

Expected: empty diff. (The doc references "the agent" generically — no rewrite needed.)

- [ ] **Step 1.4: Add the `context7` block to `.mcp.json.example.tmpl`**

Open `~/code/daniel-personal-brand/vps-setup/agent-template/.mcp.json.example.tmpl`. After the existing last `mcpServers` entry, insert:

```json
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"],
      "env": {
        "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"
      }
    }
```

(Mind the trailing-comma rules — JSON. If the existing block ended with `}` and no comma, add a comma after it before inserting the new block.)

Validate:

```bash
jq . ~/code/daniel-personal-brand/vps-setup/agent-template/.mcp.json.example.tmpl
```

Expected: valid JSON, `.mcpServers.context7` present with the three fields above.

- [ ] **Step 1.5: Insert §"Library / API docs" into `CLAUDE.md.tmpl`**

Open `~/code/daniel-personal-brand/vps-setup/agent-template/CLAUDE.md.tmpl`. Find line 62 (start of `## Telegram formatting — DEFAULT TO MarkdownV2`). Insert the following BEFORE that line, leaving a blank line on both sides:

```markdown
## Library / API docs — ALWAYS use Context7 before generating code

When you write code that uses any library, SDK, framework, CLI, or external API — anything where the right answer depends on a *current* API surface — call **Context7 MCP first**, before generating. Your training data may be months stale; Context7 fetches version-specific docs from the source at query time, so the code you produce matches today's reality instead of a hallucinated endpoint.

**The two-step pattern:**
1. `mcp__context7__resolve-library-id` with the library/framework name → returns a Context7 ID like `/upstash/context7` or `/vercel/next.js`.
2. `mcp__context7__get-library-docs` with that ID + your specific question → returns current, version-scoped documentation snippets.

**Do this automatically — {{TENANT_PERSON_FIRST_NAME}} should not have to ask.** Triggers: "set up X", "configure Y", "implement auth with Z", "what's the API for…", or any request that produces code touching a third-party library. If {{TENANT_PERSON_FIRST_NAME}} appends `use context7` to a prompt, treat that as an explicit instruction to ground the next step in fresh docs, including the version if mentioned (e.g. *Next.js 15 middleware*).

**When to skip:** pure logic with no external dependency, your own brand canon, anything already covered by the project's own `{{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/` docs. Don't lookup-storm for trivia.

Verify it's wired: `claude mcp list | grep context7`. If it's missing, surface that — don't fall back to training data silently.
```

Validate:

```bash
grep -c "ALWAYS use Context7" ~/code/daniel-personal-brand/vps-setup/agent-template/CLAUDE.md.tmpl
```

Expected: `1` (exactly one occurrence — not duplicated).

- [ ] **Step 1.6: Enable the feature flag in the tenant config**

Open `~/code/daniel-personal-brand/vps-setup/tenants/danielgonell.yml`. Under the `features:` block, add:

```yaml
  context7: true
```

(Indentation: two spaces, matching the existing keys under `features:`.)

Validate:

```bash
python3 -c "import yaml; print(yaml.safe_load(open('$HOME/code/daniel-personal-brand/vps-setup/tenants/danielgonell.yml'))['features']['context7'])"
```

Expected output: `True`.

- [ ] **Step 1.7: Wire the installer into `install-all.sh`**

Open `~/code/daniel-personal-brand/agent-stack/scripts/install-all.sh`. After line 19 (`bash "${SCRIPT_DIR}/09-install-graphify.sh"`), insert:

```bash
bash "${SCRIPT_DIR}/10-install-context7-mcp.sh"
```

Validate:

```bash
grep -n "10-install-context7" ~/code/daniel-personal-brand/agent-stack/scripts/install-all.sh
```

Expected: a single line, around line 20.

- [ ] **Step 1.8: Local diff review**

```bash
cd ~/code/daniel-personal-brand
git status --short
git diff --stat
```

Expected: 6 files changed (2 created, 4 modified). No other files should appear. If something unrelated shows up, STOP — concurrent committer landed something.

- [ ] **Step 1.9: Commit + push (per concurrent-committer guard)**

```bash
cd ~/code/daniel-personal-brand
git add \
  agent-stack/scripts/10-install-context7-mcp.sh \
  agent-stack/scripts/install-all.sh \
  docs/context7-setup.md \
  vps-setup/agent-template/.mcp.json.example.tmpl \
  vps-setup/agent-template/CLAUDE.md.tmpl \
  vps-setup/tenants/danielgonell.yml
git status --short
git commit -m "$(cat <<'EOF'
daniel-stack — Context7 MCP parity backport from Ella v0.22.0

Backports the Context7 wiring already shipped in Ella v0.22.0 so Daniel's
live Chief-of-Staff agent on projectizer finally has access to
version-aware library docs at code-generation time.

  - agent-stack/scripts/10-install-context7-mcp.sh   (verbatim from Ella)
  - agent-stack/scripts/install-all.sh               (+1 line to call it)
  - docs/context7-setup.md                           (verbatim from Ella)
  - vps-setup/agent-template/.mcp.json.example.tmpl  (+ context7 block)
  - vps-setup/agent-template/CLAUDE.md.tmpl          (+ §Library/API docs)
  - vps-setup/tenants/danielgonell.yml               (features.context7: true)

Closes the gap where the live CoS agent had zero Context7 wiring and was
generating code from training-data guesses. Free tier — no API key
required; CONTEXT7_API_KEY remains optional for higher rate limits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

Record the new HEAD: `git rev-parse HEAD`.

- [ ] **Step 1.10: Deploy + verify on projectizer**

```bash
ssh projectizer 'bash -lc "
  set -e
  cd /opt/danielgonell/source
  git fetch --quiet && git pull --ff-only
  sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
  sudo bash agent-stack/scripts/10-install-context7-mcp.sh
"'
```

Expected: render-and-deploy completes; installer prints `Context7 installed.`

Then verify:

```bash
ssh projectizer 'sudo -u danielgonell -H claude mcp list 2>&1 | grep -i context7'
```

Expected: `context7  ✓ connected` (or equivalent connected indicator).

- [ ] **Step 1.11: Live smoke check — agent actually uses it**

In a CoS session (Telegram or local Claude Code on projectizer), send:

> What's the current Stripe Node SDK API for creating a subscription? use context7

Expected: the agent's response includes a Context7 doc snippet and cites it; the session log (`~/.claude/projects/*/*.jsonl`) shows `mcp__context7__resolve-library-id` and `mcp__context7__get-library-docs` calls.

If the agent answered without calling Context7 → the CLAUDE.md rule isn't being followed. Re-read §"Library / API docs" was actually inserted (Step 1.5) and that `render-and-deploy` propagated it.

---

## Task 2: Smoke-test coverage (both repos)

**Goal:** silent Context7 regression becomes a smoke red.

**Files:**
- Modify: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/smoke-test.sh.tmpl`
- Modify: `~/code/daniel-personal-brand/vps-setup/agent-template/scripts/smoke-test.sh.tmpl` (or equivalent — verify path first)

- [ ] **Step 2.1: Inspect the existing smoke-test structure in Ella**

```bash
grep -n "^check \|^# Section\|^# MCP\|^section " ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/smoke-test.sh.tmpl | head -40
```

Locate the section that checks MCP / plugin health. Record the line number you'll insert the two new checks after.

- [ ] **Step 2.2: Add the two Context7 checks in Ella**

After the line you recorded in Step 2.1 (use the same `check "label" "command"` shape the file already uses), insert:

```bash
check "Context7 MCP registered with Claude Code" \
  "sudo -u {{TENANT_LINUX_USER}} -H claude mcp list 2>/dev/null | grep -qE '^context7\b'"

check "Context7 MCP package fetchable via npx" \
  "npx -y @upstash/context7-mcp@latest --help >/dev/null 2>&1"
```

- [ ] **Step 2.3: Verify the smoke count incremented by 2 in Ella**

```bash
grep -c "^check " ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/smoke-test.sh.tmpl
```

Record the new count. If it didn't increase by exactly 2, something duplicated.

- [ ] **Step 2.4: Find Daniel's smoke-test path + structure**

```bash
find ~/code/daniel-personal-brand -name 'smoke-test.sh*' -o -name 'smoke.sh' 2>/dev/null
```

Likely path: `~/code/daniel-personal-brand/vps-setup/agent-template/scripts/smoke-test.sh.tmpl` (matches Ella). Confirm by inspecting the file:

```bash
grep -n "^check \|^# Section" <path-from-above> | head -40
```

- [ ] **Step 2.5: Add the same two checks in Daniel**

Insert the same block from Step 2.2 in the analogous section.

- [ ] **Step 2.6: Local validation**

```bash
bash -n ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/smoke-test.sh.tmpl
bash -n ~/code/daniel-personal-brand/vps-setup/agent-template/scripts/smoke-test.sh.tmpl
```

Expected: no syntax errors. (Note: the script has `{{TENANT_*}}` tokens which `bash -n` will accept since they read as opaque strings.)

- [ ] **Step 2.7: Commit Ella**

```bash
cd ~/code/ella-claude-code-ai-agent
git fetch --quiet && git pull --ff-only
git add vps-setup/agent-template/scripts/smoke-test.sh.tmpl
git commit -m "$(cat <<'EOF'
smoke-test: add 2 Context7 health checks (registered + reachable)

Two new checks: claude mcp list contains 'context7', and the npx package
'@upstash/context7-mcp@latest' fetches with --help. Closes the gap where
a silent Context7 regression was invisible to the smoke suite.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 2.8: Commit Daniel**

```bash
cd ~/code/daniel-personal-brand
git fetch --quiet && git pull --ff-only
git add vps-setup/agent-template/scripts/smoke-test.sh.tmpl
git commit -m "$(cat <<'EOF'
smoke-test: add 2 Context7 health checks (registered + reachable)

Mirrors Ella's smoke addition so a Context7 regression on projectizer is
caught immediately.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 2.9: Re-deploy + run smoke on projectizer**

```bash
ssh projectizer 'bash -lc "
  set -e
  cd /opt/danielgonell/source
  git pull --ff-only
  sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
  sudo -u danielgonell -H bash /opt/danielgonell/.agents/scripts/smoke-test.sh 2>&1 | tail -30
"'
```

Expected: the two new "Context7" checks pass. Overall smoke result is green.

---

## Task 3: VPS skill library install (`context7-cli`)

**Goal:** `skill-runner.sh` and any swarm/agent that reads from the VPS skill library can invoke the `ctx7` CLI.

**Files:**
- Create: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli/SKILL.md`
- Create: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli/references/*` (whatever the local skill ships — copy verbatim)
- Create: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl`
- Mirror all of the above in `~/code/daniel-personal-brand/...`
- Modify: `install-all.sh` in both repos to call the new installer

- [ ] **Step 3.1: Copy the local skill into Ella's bundle**

```bash
mkdir -p ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli
cp -R ~/.claude/skills/context7-cli/. \
      ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli/
ls -R ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli/
```

Expected: `SKILL.md` + a `references/` directory with `docs.md` and any others.

- [ ] **Step 3.2: Write the installer script in Ella**

Create `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl`:

```bash
#!/usr/bin/env bash
# Installs the context7-cli skill into the agent's VPS skill library so
# skill-runner.sh + sub-agents can invoke the ctx7 CLI (Context7's
# documentation CLI, parallel to the MCP path).
#
# Idempotent: skips if SKILL.md already present.

set -euo pipefail

TARGET_DIR="{{TENANT_AGENT_HOME}}/.agents/skills/context7-cli"
SOURCE_DIR="$(dirname "${BASH_SOURCE[0]}")/../skills-bundle/context7-cli"

# 1) Ensure ctx7 CLI is globally available — install if missing
if ! command -v ctx7 >/dev/null 2>&1; then
  echo "[install-context7-cli-skill] ctx7 not found — installing via npm…"
  npm install -g ctx7@latest || {
    echo "[install-context7-cli-skill] WARN: npm install failed; MCP path still works without the CLI" >&2
  }
fi

# 2) Mirror the skill into the agent skill library
if [[ -f "${TARGET_DIR}/SKILL.md" ]]; then
  echo "[install-context7-cli-skill] ${TARGET_DIR} already present — skipping"
else
  mkdir -p "${TARGET_DIR}"
  cp -R "${SOURCE_DIR}/." "${TARGET_DIR}/"
  chown -R {{TENANT_LINUX_USER}}:{{TENANT_LINUX_USER}} "${TARGET_DIR}"
  echo "[install-context7-cli-skill] installed skill to ${TARGET_DIR}"
fi
```

Make it executable:

```bash
chmod +x ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl
```

- [ ] **Step 3.3: Wire into Ella's `install-all.sh`**

Open `~/code/ella-claude-code-ai-agent/agent-stack/scripts/install-all.sh`. After the `10-install-context7-mcp.sh` line (line 20), insert:

```bash
bash "${SCRIPT_DIR}/11-install-context7-cli-skill.sh"
```

Wait — that path is wrong. The `install-context7-cli-skill.sh.tmpl` lives in `vps-setup/agent-template/scripts/` (rendered per-tenant), not in `agent-stack/scripts/` (operator-side). Decide:

- If the installer needs `{{TENANT_*}}` tokens (it does — for `TARGET_DIR` and `chown`), it MUST be in `vps-setup/agent-template/scripts/` and run by `render-and-deploy` per-tenant, not by `install-all.sh`.
- `install-all.sh` runs operator-side, before tenant render.

Correct wiring: the rendered version (in `agents-config/<tenant>/scripts/install-context7-cli-skill.sh`) gets called by `render-and-deploy.sh` after render. Inspect:

```bash
grep -n "install-context7\|skills-bundle" ~/code/ella-claude-code-ai-agent/vps-setup/scripts/render-and-deploy.sh
```

If the deploy script already has a "run all tenant install scripts" loop, this will be picked up automatically. If not, add an explicit call after render:

```bash
sudo -u "${TENANT_LINUX_USER}" -H bash "${AGENT_HOME}/scripts/install-context7-cli-skill.sh"
```

Document which decision you made.

- [ ] **Step 3.4: Smoke check for the new skill**

Add to `smoke-test.sh.tmpl` (Ella + Daniel):

```bash
check "context7-cli skill installed in skill library" \
  "test -f {{TENANT_AGENT_HOME}}/.agents/skills/context7-cli/SKILL.md"
```

- [ ] **Step 3.5: Mirror to Daniel**

```bash
mkdir -p ~/code/daniel-personal-brand/vps-setup/agent-template/skills-bundle/context7-cli
cp -R ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/skills-bundle/context7-cli/. \
      ~/code/daniel-personal-brand/vps-setup/agent-template/skills-bundle/context7-cli/
cp ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl \
   ~/code/daniel-personal-brand/vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl
```

Repeat the `render-and-deploy.sh` decision from Step 3.3 in the Daniel repo.

- [ ] **Step 3.6: Commit Ella**

```bash
cd ~/code/ella-claude-code-ai-agent
git fetch --quiet && git pull --ff-only
git add \
  vps-setup/agent-template/skills-bundle/context7-cli/ \
  vps-setup/agent-template/scripts/install-context7-cli-skill.sh.tmpl \
  vps-setup/agent-template/scripts/smoke-test.sh.tmpl \
  vps-setup/scripts/render-and-deploy.sh
git status --short
git commit -m "$(cat <<'EOF'
agent-stack: install context7-cli skill into VPS skill library

Adds the ctx7 CLI + the context7-cli skill (imported from
~/.claude/skills/) so skill-runner.sh and dispatched sub-agents can use
Context7 outside the main agent turn. Free tier; ctx7 install is
warn-only — MCP path still works if npm install fails.

  - skills-bundle/context7-cli/  (verbatim copy of local skill)
  - install-context7-cli-skill.sh.tmpl  (idempotent installer)
  - smoke-test.sh.tmpl  (+ 1 check)
  - render-and-deploy.sh  (call installer post-render)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 3.7: Commit Daniel**

Same shape as Step 3.6 in the Daniel repo. Push.

- [ ] **Step 3.8: Deploy + verify**

```bash
ssh projectizer 'bash -lc "
  set -e
  cd /opt/danielgonell/source
  git pull --ff-only
  sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
  ls -la /opt/danielgonell/.agents/skills/context7-cli/
  which ctx7 && ctx7 --version
"'
```

Expected: the directory exists with `SKILL.md`; `ctx7 --version` prints a version number.

---

## Task 4: `/docs` slash command

**Goal:** explicit user surface — `/docs <library> <question>` triggers Context7 calls deterministically.

**Files:**
- Create: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/.claude/commands/docs.md.tmpl`
- Create: `~/code/daniel-personal-brand/vps-setup/agent-template/.claude/commands/docs.md.tmpl`

- [ ] **Step 4.1: Create the commands directory in Ella**

```bash
mkdir -p ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/.claude/commands
```

- [ ] **Step 4.2: Write the `/docs` command in Ella**

Create `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/.claude/commands/docs.md.tmpl`:

```markdown
---
name: docs
description: Fetch current library/framework docs via Context7 before answering. Use when {{TENANT_PERSON_FIRST_NAME}} asks about a library's current API surface, a version-specific feature, or asks "how do I do X with Y framework".
---

The user invoked `/docs $ARGUMENTS`.

Your job in this turn:

1. Call `mcp__context7__resolve-library-id` with the library name parsed from `$ARGUMENTS`. If `$ARGUMENTS` includes a version (e.g. "next.js 15"), include that version in the resolve query.
2. Call `mcp__context7__get-library-docs` with the resolved ID and the rest of `$ARGUMENTS` as the question.
3. Answer **only** from the returned snippets. Quote the most relevant snippet and cite the section. If Context7 returned nothing useful for the question, say so explicitly — never fall back to training-data guesses.
4. If `$ARGUMENTS` is empty, ask {{TENANT_PERSON_FIRST_NAME}} which library + question to look up.

Never skip step 1 or 2. If the Context7 MCP is unavailable (resolve-library-id errors), surface that as an error rather than improvising. Tell {{TENANT_PERSON_FIRST_NAME}} `Context7 MCP unavailable` and stop.
```

- [ ] **Step 4.3: Mirror to Daniel**

```bash
mkdir -p ~/code/daniel-personal-brand/vps-setup/agent-template/.claude/commands
cp ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/.claude/commands/docs.md.tmpl \
   ~/code/daniel-personal-brand/vps-setup/agent-template/.claude/commands/docs.md.tmpl
```

- [ ] **Step 4.4: Confirm render-and-deploy picks up `.claude/commands/`**

```bash
grep -n "\.claude/commands\|commands/" ~/code/daniel-personal-brand/vps-setup/scripts/render-and-deploy.sh \
                                       ~/code/daniel-personal-brand/vps-setup/scripts/render-tenant.sh
```

If the deploy already renders `.claude/` wholesale, the new `commands/docs.md.tmpl` will be picked up automatically. If `.claude/commands/` is excluded, add it to the include list. Document which case applied.

- [ ] **Step 4.5: Smoke check**

Add to both repos' `smoke-test.sh.tmpl`:

```bash
check "/docs slash command rendered" \
  "test -f {{TENANT_AGENT_HOME}}/.claude/commands/docs.md"
```

- [ ] **Step 4.6: Commit both repos**

Same atomic-commit pattern: pull --ff-only, add only the new files, commit with a descriptive message ("first slash command in the template — /docs forces Context7 lookup"), push.

- [ ] **Step 4.7: Deploy + verify**

```bash
ssh projectizer 'bash -lc "
  set -e
  cd /opt/danielgonell/source
  git pull --ff-only
  sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
  test -f /opt/danielgonell/.claude/commands/docs.md && cat /opt/danielgonell/.claude/commands/docs.md | head -5
"'
```

Then in a CoS Claude Code session, invoke `/docs supabase row level security`. Expected: agent calls Context7 and answers from snippets.

---

## Task 5: Sub-agent awareness (4 code-producing agency-agents)

**Goal:** `frontend-developer`, `backend-architect`, `ai-engineer`, `security-auditor` automatically call Context7 before generating library-touching code.

**Files:**
- Modify: `~/src/agency-agents/.local-install/manifest.json` (or the install template that adds the Daniel-stack header — locate first)
- Modify: the four named agents' system prompts to include the new "Library docs — Context7 first" line

- [ ] **Step 5.1: Locate the agency-agents install structure**

```bash
ls ~/src/agency-agents/.local-install/
cat ~/src/agency-agents/.local-install/manifest.json | jq .
```

Find the mechanism that adds the Daniel-stack header (per memory `project_agency_agents_install.md`, it's done at install time — `python3 install.py` reads the manifest and writes the per-agent file to `~/.claude/agents/`). Confirm where the header text lives.

- [ ] **Step 5.2: Add Context7 awareness to the four target agents**

In whichever template/config file defines the header injected for these four agents, add this line at the end of the Daniel-stack header (after the brand-voice lock):

```markdown
**Library docs — Context7 first.** Before generating any code that uses a third-party library, SDK, framework, or external API, call `mcp__context7__resolve-library-id` then `mcp__context7__get-library-docs` to ground the code in the current API surface. Do not fall back to training-data guesses.
```

The four target agents (from the manifest):
- `frontend-developer`
- `backend-architect`
- `ai-engineer`
- `security-auditor`

If the header is shared across ALL 16 cherry-picked agents, decide: scope the new line to only the four code-producing agents (preferred — non-code agents don't need it), or accept that all 16 get it (simpler but slightly noisy for e.g. `image-prompt-engineer`).

- [ ] **Step 5.3: Reinstall the cherry-pick**

```bash
python3 ~/src/agency-agents/.local-install/install.py
```

Expected: 16 agents written to `~/.claude/agents/`. No errors.

- [ ] **Step 5.4: Verify the line landed**

```bash
for a in frontend-developer backend-architect ai-engineer security-auditor; do
  echo "=== $a ==="
  grep "Context7 first" ~/.claude/agents/$a.md || echo "MISSING"
done
```

Expected: each grep finds the line. If `MISSING`, the manifest didn't write what you expected — revisit Step 5.2.

- [ ] **Step 5.5: Commit `~/src/agency-agents` if it's a git repo**

```bash
cd ~/src/agency-agents
git status --short
git diff --stat
```

If clean: nothing to commit (changes were inside `.local-install/` and may already be gitignored). If dirty:

```bash
git add .local-install/
git commit -m "context7: code-producing sub-agents call Context7 before generating

Adds a one-line Context7 directive to the Daniel-stack header on
frontend-developer, backend-architect, ai-engineer, and security-auditor
so dispatched sub-agents ground library code in current docs.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

(Optional push depends on whether you maintain a fork.)

- [ ] **Step 5.6: Live smoke — dispatch a sub-agent and watch for Context7 calls**

In a CoS session: ask "use the frontend-developer agent to write a React Server Component that fetches a list from Supabase". Expected: the dispatched agent issues `mcp__context7__resolve-library-id` for both Next.js and Supabase, then `mcp__context7__get-library-docs`, before writing JSX.

---

## Task 6: Mission Control "Library Docs" tile + endpoint

**Goal:** observability — see Context7 call counts, top libraries, last queries in the dashboard.

**Files:**
- Modify: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/dashboard-sync-autonomy.py.tmpl` (write `state/context7.json`)
- Modify: `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/dashboard/index.html` (new "Library Docs" tab/section + JS fetch)
- Mirror to Daniel
- Modify: nginx config if it serves `state/` as `/api/` (verify before assuming)

- [ ] **Step 6.1: Inspect the existing dashboard-sync writes**

```bash
grep -n "open(\|with open\|json.dump\|state/" ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts/dashboard-sync-autonomy.py.tmpl | head -40
```

Record the pattern used for existing endpoints (`jobs.json`, `growth.json`, etc.). Use the same pattern for `context7.json`.

- [ ] **Step 6.2: Add a `write_context7_state()` function in Ella**

Append to `dashboard-sync-autonomy.py.tmpl` (use the existing project-style helpers — `STATE_DIR`, `write_json()`, etc., as the other endpoints do):

```python
import json
import os
import glob
from collections import Counter
from datetime import datetime, timedelta, timezone

CLAUDE_PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
CONTEXT7_TOOL_PREFIX = "mcp__context7__"


def _parse_context7_calls(since):
    """Walk Claude Code session JSONLs, return list of {ts, tool, args} since `since`."""
    calls = []
    pattern = os.path.join(CLAUDE_PROJECTS_DIR, "*", "*.jsonl")
    for path in glob.glob(pattern):
        try:
            with open(path) as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    tool = (
                        rec.get("message", {})
                           .get("content", [{}])[0]
                           .get("name")
                        if rec.get("type") == "assistant"
                        else None
                    )
                    if not tool or not tool.startswith(CONTEXT7_TOOL_PREFIX):
                        continue
                    ts = rec.get("timestamp")
                    if not ts:
                        continue
                    try:
                        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    if when < since:
                        continue
                    calls.append({
                        "ts": ts,
                        "tool": tool,
                        "input": rec.get("message", {})
                                    .get("content", [{}])[0]
                                    .get("input", {}),
                    })
        except (OSError, IndexError):
            continue
    return calls


def write_context7_state():
    now = datetime.now(timezone.utc)
    since_7d = now - timedelta(days=7)
    since_24h = now - timedelta(hours=24)
    calls_7d = _parse_context7_calls(since_7d)
    calls_24h = [c for c in calls_7d if datetime.fromisoformat(c["ts"].replace("Z", "+00:00")) >= since_24h]

    libs = Counter()
    for c in calls_7d:
        lib = c["input"].get("libraryName") or c["input"].get("context7CompatibleLibraryID") or ""
        if lib:
            libs[lib] += 1

    last_queries = []
    for c in sorted(calls_7d, key=lambda x: x["ts"], reverse=True)[:5]:
        last_queries.append({
            "ts": c["ts"],
            "library": c["input"].get("libraryName") or c["input"].get("context7CompatibleLibraryID") or "?",
            "query": (c["input"].get("query") or c["input"].get("topic") or "")[:120],
        })

    state = {
        "calls_24h": len(calls_24h),
        "calls_7d": len(calls_7d),
        "top_libraries": [{"id": lib, "calls": n} for lib, n in libs.most_common(5)],
        "last_queries": last_queries,
        "free_tier": True,
        "generated_at": now.isoformat(),
    }
    write_json(STATE_DIR / "context7.json", state)
```

Then call `write_context7_state()` in the main dispatch alongside the existing endpoint writers.

- [ ] **Step 6.3: Test the script locally against a fake project tree**

```bash
mkdir -p /tmp/context7-test/projects/test
cat > /tmp/context7-test/projects/test/sample.jsonl <<'EOF'
{"type":"assistant","timestamp":"2026-06-04T15:00:00Z","message":{"content":[{"name":"mcp__context7__resolve-library-id","input":{"libraryName":"next.js","query":"middleware"}}]}}
{"type":"assistant","timestamp":"2026-06-04T15:00:01Z","message":{"content":[{"name":"mcp__context7__get-library-docs","input":{"context7CompatibleLibraryID":"/vercel/next.js","query":"middleware in v15"}}]}}
EOF
CLAUDE_PROJECTS_DIR=/tmp/context7-test/projects python3 -c "
from datetime import datetime, timedelta, timezone
import sys
sys.path.insert(0, '$HOME/code/ella-claude-code-ai-agent/vps-setup/agent-template/scripts')
# Stub the template tokens by exporting before invocation:
# (run the rendered .py on a real tenant instead — easier than tokenizing here)
print('parsed:', _parse_context7_calls(datetime.now(timezone.utc) - timedelta(days=30)))
"
```

If running the raw template fails on tokens, render it to a scratch tenant first:

```bash
TENANT=test-tenant bash ~/code/ella-claude-code-ai-agent/vps-setup/scripts/render-tenant.sh --dry-run | grep context7
```

(Validate just that the rendered file is syntactically valid Python: `python3 -c "import ast; ast.parse(open('rendered.py').read())"`)

- [ ] **Step 6.4: Add the "Library Docs" tab to `index.html`**

Open `~/code/ella-claude-code-ai-agent/vps-setup/agent-template/dashboard/index.html`. Find the existing tab nav (`<nav>` or list of `<a class="tab">` or whatever pattern is in use — grep for an existing tab like "Self-Growth"):

```bash
grep -n "Self-Growth\|tab-\|data-tab" ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/dashboard/index.html | head -10
```

Use the same pattern to add a `Library Docs` tab. The tab content area renders three cards:
1. **Counts**: `calls_24h` / `calls_7d` as big numbers.
2. **Top libraries**: a horizontal bar chart of `top_libraries[*].calls` (5 bars max). Use the same chart pattern as the existing self-growth trend if there is one; if not, plain `<div style="width:{n*4}%">` bars are fine — no chart library.
3. **Last queries**: a table of `last_queries[*]` with ts, library, query.

Fetch from `/api/context7.json` (or whatever the existing tabs use — check `fetch(` calls in the HTML).

- [ ] **Step 6.5: Mirror to Daniel**

```bash
diff ~/code/ella-claude-code-ai-agent/vps-setup/agent-template/dashboard/index.html \
     ~/code/daniel-personal-brand/vps-setup/agent-template/dashboard/index.html | head -50
```

If they're already in sync apart from drift, apply the same edits to the Daniel HTML. Same for the Python sync script.

- [ ] **Step 6.6: Smoke check**

Add to both repos' `smoke-test.sh.tmpl`:

```bash
check "context7.json dashboard endpoint exists" \
  "test -s {{TENANT_AGENT_HOME}}/.agents/state/context7.json && jq -e '.calls_7d' {{TENANT_AGENT_HOME}}/.agents/state/context7.json >/dev/null"
```

- [ ] **Step 6.7: Commit Ella**

```bash
cd ~/code/ella-claude-code-ai-agent
git fetch --quiet && git pull --ff-only
git add \
  vps-setup/agent-template/scripts/dashboard-sync-autonomy.py.tmpl \
  vps-setup/agent-template/dashboard/index.html \
  vps-setup/agent-template/scripts/smoke-test.sh.tmpl
git commit -m "$(cat <<'EOF'
mission-control: Library Docs tab + state/context7.json endpoint

dashboard-sync-autonomy.py parses ~/.claude/projects/**/*.jsonl for
mcp__context7__* calls, writes calls_24h / calls_7d / top_libraries /
last_queries to state/context7.json. New Library Docs tab in
index.html surfaces the values. Zero cost — pure log parsing on the
free Context7 tier.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
```

- [ ] **Step 6.8: Commit Daniel** — same shape; push.

- [ ] **Step 6.9: Deploy + verify**

```bash
ssh projectizer 'bash -lc "
  set -e
  cd /opt/danielgonell/source
  git pull --ff-only
  sudo bash vps-setup/scripts/render-and-deploy.sh danielgonell
  sudo systemctl restart dashboard-sync.service || true
  sleep 5
  jq . /opt/danielgonell/.agents/state/context7.json
"'
```

Expected: JSON with `calls_24h`, `calls_7d`, `top_libraries`, `last_queries`. Then open the dashboard URL in a browser, click `Library Docs` tab, see the numbers.

---

## Task 7: Codify in `ai-agent-skills-library` v1.5.0

**Goal:** future client deploys get this whole integration for free.

**Files:**
- Create: `~/code/ai-agent-skills-library/runbooks/context7-integration-pattern.md`
- Modify: `~/code/ai-agent-skills-library/SKILLS-CATALOG.md` (add entry)
- Modify: `~/code/ai-agent-skills-library/CHANGELOG.md` (v1.5.0 entry)
- Modify: `~/code/ai-agent-skills-library/VERSION` (or wherever version lives)

- [ ] **Step 7.1: Inspect skills-library structure**

```bash
ls ~/code/ai-agent-skills-library/
cat ~/code/ai-agent-skills-library/CHANGELOG.md | head -30
```

Locate the version file + the catalog file.

- [ ] **Step 7.2: Write the runbook**

Create `~/code/ai-agent-skills-library/runbooks/context7-integration-pattern.md`:

```markdown
# Context7 Integration Pattern (v1.5.0)

**When to apply:** any client deploy where the agent will produce code that uses third-party libraries, SDKs, frameworks, CLIs, or external APIs. (Skip for sales-only / non-coding tenants.)

**What it gets you:**
- Library code grounded in current docs at generation time, not training-data guesses
- Explicit `/docs` user surface
- Sub-agents (when used) call Context7 first
- Dashboard observability for call counts + top libraries
- Free tier — no API key required

## The seven pieces

1. **Installer** — `agent-stack/scripts/10-install-context7-mcp.sh` (registers the MCP via `claude mcp add` or `.mcp.json`, idempotent, free tier by default).
2. **`.mcp.json` block** — `mcpServers.context7` referencing `@upstash/context7-mcp@latest` with optional `CONTEXT7_API_KEY`.
3. **CLAUDE.md rule** — §"Library / API docs — ALWAYS use Context7 before generating code" with the two-step pattern + skip conditions + verify command.
4. **`/docs` slash command** — `.claude/commands/docs.md` that forces a `resolve-library-id` + `get-library-docs` pair, answer-only-from-snippets.
5. **Skill library install** — `context7-cli` skill mirrored from `~/.claude/skills/context7-cli/` into `{{TENANT_AGENT_HOME}}/.agents/skills/`, so swarms/skills can use the `ctx7` CLI.
6. **Sub-agent awareness** — for cherry-picked code-producing agents (frontend-developer, backend-architect, ai-engineer, security-auditor), a one-line Context7 directive appended to their system prompt.
7. **Mission Control tile** — `state/context7.json` (parsed from session JSONLs) + dashboard `Library Docs` tab with counts + top libraries + last queries.

## Smoke verification (always add these)

- `claude mcp list | grep context7` succeeds
- `npx -y @upstash/context7-mcp@latest --help` returns 0
- `state/context7.json` exists + validates as JSON (Piece 7)
- `.claude/commands/docs.md` exists (Piece 4)
- `.agents/skills/context7-cli/SKILL.md` exists (Piece 5)

## Reference implementation

See commits in `ella-claude-code-ai-agent` and `daniel-personal-brand` from 2026-06-04 (Context7 fullest integration). Plan: `docs/superpowers/plans/2026-06-04-context7-fullest-integration.md` in the Ella repo.

## Anti-patterns to avoid

- Don't add a doc-staleness watcher. Context7 IS the staleness fix.
- Don't add a second .mcp.json registration mechanism. Piece 1 already handles it.
- Don't add more CLAUDE.md rules. The §"Library / API docs" rule is comprehensive.
- Don't wire the paid API key unless the free tier is actually rate-limiting.
```

- [ ] **Step 7.3: Update SKILLS-CATALOG.md**

Add a new entry under the runbooks section (use the existing entry format — open the file and match the shape exactly):

```markdown
### context7-integration-pattern

Seven-piece integration that gives an agent first-class Context7 access: MCP install, .mcp.json block, CLAUDE.md rule, /docs slash command, VPS skill library, sub-agent awareness, Mission Control tile. Added v1.5.0.
```

- [ ] **Step 7.4: Update CHANGELOG.md**

Add at the top:

```markdown
## v1.5.0 — 2026-06-04

- **New runbook:** `context7-integration-pattern.md` — seven-piece pattern for first-class Context7 access (live MCP, `/docs` command, sub-agent awareness, MC observability). Pulls together changes shipped to ella-claude-code-ai-agent and daniel-personal-brand on 2026-06-04.
```

- [ ] **Step 7.5: Bump VERSION**

```bash
cd ~/code/ai-agent-skills-library
cat VERSION
echo "1.5.0" > VERSION
```

- [ ] **Step 7.6: Commit + push**

```bash
cd ~/code/ai-agent-skills-library
git fetch --quiet && git pull --ff-only
git add VERSION CHANGELOG.md SKILLS-CATALOG.md runbooks/context7-integration-pattern.md
git status --short
git commit -m "$(cat <<'EOF'
v1.5.0 — context7-integration-pattern runbook

Codifies the seven-piece Context7 integration pattern (live MCP, .mcp.json
block, CLAUDE.md rule, /docs slash command, VPS skill library install,
sub-agent awareness, Mission Control tile) so future client deploys carry
it forward. Reference implementation: ella + daniel repos, 2026-06-04.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
git push origin main
git tag v1.5.0 && git push origin v1.5.0
```

---

## Self-review (run after writing the above)

**1. Spec coverage:** Each of the seven gaps in the spec maps to a task — Phases 1-6 → Tasks 1-6, Phase 7 codification → Task 7. ✓

**2. Placeholder scan:** No TBD / TODO / "fill in" left. Each step has a concrete command or exact content. ✓

**3. Type consistency:** `state/context7.json` schema in Task 6 matches the spec's example. `mcp__context7__resolve-library-id` and `mcp__context7__get-library-docs` are spelled identically everywhere. The `context7` server name in `.mcp.json` is consistent across Tasks 1, 4, 5, 6. ✓

**4. Open ambiguity to call out at execution:**
- Task 3 Step 3.3: where exactly the per-tenant installer is invoked from depends on what `render-and-deploy.sh` already does. Plan tells the engineer to inspect and decide, which is correct — there's no single right answer without reading the file.
- Task 5 Step 5.2: scope of the new header line (4 agents vs all 16) is a small judgment call left to execution; the plan flags it as such.

These are real decisions the engineer must make at runtime — not placeholder rot.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-04-context7-fullest-integration.md` (in `ella-claude-code-ai-agent` repo). Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
