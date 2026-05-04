# Contributing

Thanks for considering a contribution. This repo extracts a production-tested single-tenant agent stack into a portable template — improvements that come from real-world deployments are especially valuable.

## What we welcome

- **Deployment reports** — "I deployed this for a [SaaS founder / agency / law firm / etc.] and here's what worked / broke" — open an issue
- **Bug fixes** — anything in the install scripts, the agent-template, or the docs
- **New install scripts** — additional MCP servers (Notion, GitHub, Slack, etc.), additional sub-agent cherry-picks
- **Tenant.yml schema improvements** — fields that are useful across deployments
- **Tool-leverage heuristics** — new combo patterns that should be in the chief-of-staff template
- **CRM integrations** — HubSpot, Salesforce, Pipedrive equivalents to the GoHighLevel example

## Conventions

- **Idempotent everything.** Every install script must be safe to re-run. No "delete this first then run."
- **Strict mode.** Every shell script starts with `set -euo pipefail` (handled by `lib/common.sh`).
- **Match existing patterns.** New install scripts follow the 00-09 numbered pattern, source `lib/common.sh`, use `log_step / log_info / log_warn / log_error / log_implementation`.
- **Document upstream deps.** Any new git repo / npm package / pypi package gets an entry in `docs/upstream-dependencies.md` with a "why."
- **Markdown over schemas.** Behavioral spec, voice playbook, DESIGN.md, brand canon — all markdown. The agent reads markdown most reliably.
- **No tenant-specific values in committed files.** Anything that differs across tenants belongs in `tenant.yml`.

## PR checklist

- [ ] Idempotent (safe to re-run)
- [ ] Matches existing script style (`source lib/common.sh`, `set -euo pipefail`, logging helpers)
- [ ] Documented in the relevant `docs/` file (or new doc added)
- [ ] If adding upstream deps, added to `docs/upstream-dependencies.md`
- [ ] If touching `vps-setup/agent-template/CLAUDE.md.tmpl`, re-rendered for at least one example tenant to verify substitutions
- [ ] No tenant-specific paths or values committed (no `/opt/danielgonell/...`, no real API keys)
- [ ] No secrets in test fixtures or example configs

## Setting up a dev environment

The simplest path is to fork this repo and run `agent-stack/scripts/install-all.sh` against a throwaway test directory:

```bash
git clone <your-fork>.git ~/ella-dev
cd ~/ella-dev
cp agent-stack/config/client.example.env agent-stack/config/client.env
# point CLAUDE_PROJECT_ROOT and KNOWLEDGE_LIBRARY_ROOTS at a test directory
$EDITOR agent-stack/config/client.env
bash agent-stack/scripts/install-all.sh
```

For VPS-side changes, a cheap Vultr or Hetzner instance ($5–10/mo) is enough to test end-to-end.

## Reporting issues

Include:
- Which install mode (local / VPS)
- OS + Node + Python versions
- Output of the failing script (run with `bash -x` for verbose mode)
- The relevant section of `agent-stack/implementation-log.md` if it exists

## Code of conduct

Be kind. The maintainers run businesses on this — we appreciate patience and clarity.
