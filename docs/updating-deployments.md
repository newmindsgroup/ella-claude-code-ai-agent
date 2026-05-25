# Updating deployed agents without breaking them

The core problem: you keep improving the template, but each deployed agent has
its **own config, its own accumulated state, and possibly its own local
changes**. A naive "copy the new files over" clobbers all of that. This page is
the model + the mechanism that lets template updates flow to live agents safely.

## The three layers (the whole idea)

Every file in a deployed agent home falls into exactly one layer. Updates only
ever touch Layer 1.

| Layer | Examples | Update policy |
|---|---|---|
| **1. Template-managed code** | `scripts/` (except `ops/` + `local/`), `dashboard/`, `dashboard-chat/`, `swarms/`, `rules/`, `crontab/`, `CLAUDE.md`, `systemd/`, `.claude/agents/` | **Refreshed from the template.** Regenerated per-tenant by `render-tenant.sh`, so tenant values are re-substituted, not lost. |
| **2. Tenant config (source of truth = `tenant.yml`)** | the `{{TENANT_*}}` values baked into Layer-1 files at render time | **Never hand-edit live files.** Change `tenant.yml`, re-render, redeploy. Config survives every update because it's regenerated, not patched. |
| **3. Runtime state + secrets + local overrides** | `memory/`, `tasks/`, `drafts/`, `goals/`, `state/`, `context/`, `notifications/`, `logs/`, `deploys/`, `obsidian-vault/`, `conversation.db`, `.env*`, `.mcp.json`, `.claude/settings.json`, `.claude/channels/`, `preferences.json`, **`scripts/local/`**, **`CLAUDE.local.md`** | **Never touched by an update.** This is the client's brain + identity + customizations. |

If a file is in Layer 3, the updater leaves it alone — period. If it's in Layer
1, the updater refreshes it **but only if the agent hasn't locally modified it**
(see "local-modification guard" below).

## Why config is never lost

`tenant.yml` is the single source of truth for everything tenant-specific. The
deploy flow is always: **edit `tenant.yml` → `render-tenant.sh` → push → pull +
sync on the VPS.** Because Layer-1 files are *regenerated* from `tenant.yml` on
every render, a template update can change the *structure* of a file while the
tenant's *values* are re-injected fresh. You never hand-edit a live config file,
so there's nothing to overwrite.

Secrets (`.env`, `.mcp.json`, Telegram `access.json`) are created once at
bootstrap with real tokens and live in Layer 3 — the renderer never emits them
and the updater never touches them.

## The local-modification guard (how we avoid clobbering self-changes)

`redeploy.sh` keeps a **baseline manifest** at `state/.deploy-manifest` — the
hash of every Layer-1 file *as last deployed*. On each update, for every
template file it compares three versions:

- **base** = what we last deployed (manifest)
- **live** = what's on disk now
- **new** = the freshly rendered template file

| Situation | Action |
|---|---|
| live == new | already current → skip |
| file doesn't exist live | new capability → install it |
| live == base (agent didn't touch it) | safe → overwrite with new, update manifest |
| live ≠ base (agent/human modified it) | **conflict** → back up live to `backups/`, **skip by default**, warn. `--force` overwrites (after backup) |

So a self-grown or hand-edited file is **never silently overwritten** — it's
backed up and reported, and you decide. Everything the agent *added* (net-new
files not in the template) is left untouched automatically.

## Where local customizations belong (so they're update-proof)

Put anything you want to survive every update into a Layer-3 overlay:

- **`scripts/local/`** — local helper scripts. The updater never syncs this dir.
- **`CLAUDE.local.md`** — local agent instructions. The rendered `CLAUDE.md`
  references it if present, so your additions load without editing `CLAUDE.md`
  itself. Never overwritten.

The self-growth loop is already additive-only (it writes *new* helpers + memory,
never edits existing scripts/CLAUDE.md), so its output lands safely in Layer 3 by
design.

## The safe update flow

**On your Mac (author the change):**
```bash
# 1. Make the template change, re-render the affected tenant
bash vps-setup/scripts/render-tenant.sh vps-setup/tenants/<tenant>.yml
# 2. Commit + push to the tenant's OWN repo (not the Ella template)
git add -A && git commit -m "update <tenant> to template vX.Y.Z" && git push
```

**On the VPS (apply safely):**
```bash
# 3. Dry-run FIRST — see exactly what would change, touch nothing
bash {AGENT_HOME}/scripts/redeploy.sh --dry-run

# 4. Apply. Locally-modified files are backed up + skipped, not clobbered.
bash {AGENT_HOME}/scripts/redeploy.sh

# 5. If CLAUDE.md / channel plugin changed, restart the agent (one extra flag):
bash {AGENT_HOME}/scripts/redeploy.sh --with-agent

# 6. If a backed-up conflict was actually a stale local edit you want to drop:
bash {AGENT_HOME}/scripts/redeploy.sh --force   # overwrites (after backing up)
```

For brand-new capabilities (a new MCP, Graphify, new timers), run the idempotent
`install-capabilities.sh` — it only *adds* what's missing and never removes state.

## Rollback

Every conflicting file is backed up to `backups/redeploy-<timestamp>/` before any
change. To revert a file: copy it back from there. The brand-repo clone is
`git stash`-protected during pull, so a bad pull never strands local repo edits.

## What an update will never do

- Delete or rewrite `memory/`, `tasks/`, `drafts/`, `goals/`, `conversation.db`,
  or the Obsidian vault.
- Touch `.env`, `.mcp.json`, or Telegram/Discord credentials.
- Overwrite a locally-modified file without backing it up first.
- Touch `scripts/local/` or `CLAUDE.local.md`.
- Restart `claude-agent` unless you pass `--with-agent` (respects the
  bun-death/circuit-breaker rule).
