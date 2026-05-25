# AGENTS.md — rules for any agent that enters this repo

**This repository is the canonical Ella template — the single source of truth.**
It is a GitHub *template* repository: clone it / "Use this template" to start a
new deployment. It is **not** a place any deployed agent writes back to.

## The one rule

> **Do NOT push, commit, or open PRs to this repository from a deployed or
> client agent.** This repo is updated only by deliberate maintainer action.

A deployed Ella instance (yours, a client's, anyone's) is a **consumer** of this
template, never a contributor to it. If you are running *as* a deployed agent and
you find yourself about to `git push` to `newmindsgroup/ella-claude-code-ai-agent`,
stop — that's the bug this file exists to prevent.

## How a deployed agent updates itself from this template

You pull template improvements **into your own deployment**; you do not change the
template. From the deployed agent's own checkout of *its own* repo:

```bash
# 1. Pull the latest template (read-only) into a scratch dir
git clone https://github.com/newmindsgroup/ella-claude-code-ai-agent /tmp/ella-latest

# 2. Re-render YOUR tenant from the latest template
cd /tmp/ella-latest
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<your-tenant>.yml

# 3. Apply to your live deployment (idempotent)
sudo bash vps-setup/scripts/install-capabilities.sh vps-setup/tenants/<your-tenant>.yml
#    and/or the redeploy helper if present in your agent home:
#    bash {AGENT_HOME}/scripts/redeploy.sh
```

Your tenant config and your accumulated state (memory vault, tasks, drafts) live
in **your own** repo/host — never here.

## For the maintainer (the deliberate Daniel-stack → Ella mirror)

Improvements flow **one way**: production stack → this template (sanitized). When
porting a feature in:

1. **`git fetch` first, then find the TRUE latest version** — it is NOT the
   CHANGELOG top. Run `git tag -l | sort -V | tail -5` and `git log --oneline -5`.
   Pick the next version *above the highest existing tag*.
2. **Stage only your own files** (`git add <specific paths>`) — never `git add -A`.
   Multiple sessions share the `newmindsgroup` identity; a broad add can sweep
   another session's staged work and regress the version.
3. **Run the leak scan before pushing** (no real client/personal data):
   `grep -rEn 'danielgonell|Santo Domingo|<real client names>' --exclude-dir=.git .`
   (the only allowed personal references are the author credit in
   `LICENSE`/`NOTICE`/`README`/`CITATION.cff` and CHANGELOG history).
4. **One session at a time.** Concurrent porting sessions caused a versioning
   collision (two different `v0.9.4`s). Coordinate; don't run two mirrors at once.

## Sanitization invariant

Everything here is a multi-tenant template. Tenant-specific values are
`{{TENANT_*}}` placeholders resolved by `vps-setup/scripts/render-tenant.sh`.
Never hardcode a person, client, location, price, or path. See `CONTRIBUTING.md`.
