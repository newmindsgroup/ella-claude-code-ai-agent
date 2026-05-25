# scripts/local/ — local overrides (never overwritten by updates)

Put tenant-specific or self-grown helper scripts here. `redeploy.sh` **never
syncs this directory**, so anything here survives every template update.

Use this for:
- One-off scripts this deployment needs that aren't worth upstreaming.
- Experiments the agent's self-growth loop creates.
- Local wrappers around template scripts.

If a local script should eventually become part of the template for *all*
tenants, contribute it upstream to the template repo — don't just leave it here.

The companion overlay for instructions (not scripts) is `CLAUDE.local.md` in the
agent home: standing instructions that load on top of `CLAUDE.md` and are never
overwritten. See `docs/updating-deployments.md`.
