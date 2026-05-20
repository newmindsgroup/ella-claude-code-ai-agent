# Security Policy

## Supported versions

Ella is a multi-tenant agent template. Security fixes are applied to the
latest minor release on the `main` branch. Earlier releases are not patched —
clone the latest tag for a new deployment.

## Reporting a vulnerability

If you find a security issue — credential leakage in the template, a
privilege-escalation path through the ops wrappers, a deploy-orchestrator bug
that could expose a tenant's secrets — please report it privately rather
than opening a public issue.

**Preferred:** GitHub Security Advisories
([draft a new advisory](https://github.com/newmindsgroup/ella-claude-code-ai-agent/security/advisories/new)).

**Alternative:** reach out via [danielgonell.com](https://danielgonell.com) with
subject `[SECURITY] ella-claude-code-ai-agent`. Please include:

- A clear description of the issue
- Steps to reproduce (or the offending file path + line numbers)
- The version / commit SHA you tested against
- Whether you've shared it elsewhere

We aim to acknowledge reports within 72 hours and ship a patch within
14 days for high-severity findings.

## What's in scope

- The template under `vps-setup/agent-template/`
- The deploy orchestrator (`NEW-CLIENT-CLAUDE.md`, `DEPLOY-NEW-CLIENT.md`,
  `preflight-new-client.sh`)
- The agent-stack installer scripts (`agent-stack/scripts/`)
- The sudoers wrappers under `scripts/ops/` and the `agent-ops.sudoers`
  allowlist pattern
- The channels-plugin patch passes (`patch-channels-plugin.sh`)

## What's out of scope

- Upstream dependencies (Claude Code, Anthropic API, MCP servers, agency-agents,
  Superpowers, Graphify, Firecrawl, Playwright, OpenSwarm, etc.) — please
  report those to the upstream maintainers
- Issues in a **deployed** agent caused by tenant-specific configuration
  (your `.env`, your `tenant.yml`, your secret management) — these are your
  responsibility to harden after deploy
- LLM prompt-injection on a running tenant agent — interesting, but not a
  template flaw. See the deny-list in `settings.json` and the sudoers wrapper
  pattern for the defense-in-depth approach the template uses

## Operational hardening tips for tenants

The template ships hardened defaults, but a deployment is only as secure as
the operator. A short checklist after every fresh-client deploy:

- [ ] `client-credentials.md` is OUTSIDE the cloned repo, in your password
      manager
- [ ] `.env` files on the VPS are mode `0600` and owned by the tenant user
- [ ] TLS key file (`/etc/ssl/private/...-origin.key`) is mode `0600`
- [ ] `sudo -l -U <tenant_user>` shows ONLY the wrapper allowlist, never
      `NOPASSWD: ALL`
- [ ] Cloudflare API tokens are scoped to a single zone, not "all zones"
- [ ] GitHub PAT is fine-grained, bound to one org, with minimum scopes
- [ ] Smoke test passes 0 FAIL before considering the deploy done
- [ ] `journalctl -u claude-agent.service -n 50` after a restart shows no
      credential or token strings being printed
