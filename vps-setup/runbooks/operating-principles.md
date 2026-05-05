# Operating principles for the autonomous agent stack

> Lessons captured from the v2.20.0 → v2.22.5 deploy chain (one night, ten releases). These are commitments — both for human operators (Daniel) and for any future Claude Code session running in autonomous mode against this stack.

## The core lesson

**Every bug in a multi-hotfix chain like v2.22.x is discoverable by running the new code in the production runtime context BEFORE pushing.** Hotfix chains happen because each fix is committed and shipped without a check that it actually worked under the conditions the production code path runs in: as the agent's Linux user (`${TENANT_LINUX_USER}`), with cwd starting at `/root` (when SSH'd in), with no key for SSH-self, with no traversal access to `/etc/ssl/private/`.

The fix is structural (`deploy.sh dry-run` mode + `health.sh` + CI in v2.23.0), not heroic ("be more careful"). But the discipline still matters between commits.

---

## Discipline commitments

These apply to **every** future change to deploy infrastructure (deploy.sh, preflight.sh, smoke.sh, the channels-plugin patch, claude-agent.service, watchdog).

### 1. Run the change in the production runtime context before commit

For any change to a script that runs as the agent user on the VPS:

```bash
# After editing the script + rendering, but BEFORE git add:
ssh root@$VPS "sudo -u $TENANT_LINUX_USER -H bash <THE_SCRIPT> <args>"
# OR (for deploy.sh specifically):
ssh root@$VPS "sudo -u $TENANT_LINUX_USER -H bash /opt/$TENANT/agents/scripts/deploy.sh dry-run <version>"
```

The `-H` flag matters — it sets `$HOME` to the user's home, which mirrors how systemd invokes scripts.

If the change involves `claude-agent.service`, the equivalent is `systemctl daemon-reload && systemd-analyze verify <unit>` followed by a controlled restart with `journalctl -fu` watching live.

**Why**: tonight's `pushd: /root: Permission denied`, `preflight SSH-to-self`, and `/etc/ssl/private/ traversal` bugs all worked under the developer's context (Mac, root SSH session, full sudo). They failed under the production context (agent user, restricted environment).

### 2. Use `deploy.sh dry-run` before every real `start` (v2.23.0+)

```bash
bash /opt/$TENANT/agents/scripts/deploy.sh dry-run vX.Y.Z
# If green → ship for real:
bash /opt/$TENANT/agents/scripts/deploy.sh start vX.Y.Z
```

`dry-run` exercises the FULL validation pipeline (git pull + preflight + smoke) without writing state files, posting approvals, or pushing anything. It's the mechanical version of commitment #1.

If `dry-run` fails for a reason that's clearly fixable from the developer side (e.g., a missing file in the working tree), fix and re-run `dry-run`. Only after `dry-run` passes does `start` get authorized.

### 3. No force-push, ever

If a test commit needs reverting, use `git revert <sha>` (which creates a NEW commit that undoes the test). Force-push (`--force`, `--force-with-lease`) is reserved for catastrophic recovery scenarios where the user has explicitly authorized it in the chat.

This is not an arbitrary rule — force-push to `main` overwrites history. If anyone (the dashboard agent, another collaborator, a CI bot) has based work on the overwritten commits, that work silently disappears. `git revert` makes the operation auditable.

### 4. Plugin patches are version-controlled OR auto-applied — never live-edits-only

If you must hot-patch a vendored plugin (like the channels-plugin's `server.ts`):

1. **Commit the patch script** to `vps-setup/agent-template/scripts/patch-*.sh` — idempotent, with a sentinel string check.
2. **Wire it into systemd** via `ExecStartPre=` on the consuming service so the patch self-heals on every restart (the v2.23.0 wiring on `claude-agent.service`).
3. **Document the upstream version** in `vps-setup/versions.json` so version drift triggers a warning in `health.sh`.

Live-editing `/opt/.../cache/...` without the above three is a timebomb — the next plugin update wipes the change silently. Tonight's v2.22.2 was acceptable as an emergency hotfix only because v2.23.0 followed up immediately with the auto-apply path.

### 5. Run `health.sh` before any deploy and after any change to live infra

```bash
BASIC_AUTH_PW=... bash vps-setup/scripts/health.sh vps-setup/tenants/$TENANT.yml
```

Single command, ~30 seconds, covers: preflight + service status + bun cgroup membership + watchdog restart history (circuit-breaker proximity) + cert expiry + version pin drift + smoke.

**Before deploy**: catches "the stack is unhealthy in some way you don't know about; don't pile a deploy on top of it."
**After change**: catches regressions you may have introduced.

### 6. Never commit credentials, even temporarily

`.gitignore` should already cover `server-credentials/`, `*-credentials.rtf`, `*-credentials.md`, `*.htpasswd*`. If you ever find yourself wanting to commit a token "just to test" — write it to a gitignored file and reference it via env var or path. The CI secret-scan in `.github/workflows/validate.yml` is the safety net, but it's a SAFETY NET, not the primary control.

If a credential leaks anyway (already-pushed commit), the response is:

1. Rotate the credential immediately at the source (GitHub → revoke token, regenerate; Cloudflare → rotate API key; etc.)
2. Update the live VPS to use the new credential (`server-credentials/...md` + the consuming script/env)
3. Open an issue to scrub the git history (BFG or git-filter-repo) — separate from the rotation

Rotation first. History scrub second. Don't reverse.

### 7. Watchdog deaths are observed, not just fixed

The bun-death recurrence is a real bug. The watchdog masks it with auto-restart, but every restart costs ~$0.07 (CLAUDE.md cache rewrite) and a 30-second window where Telegram inbound is dead. v2.23.0 wired diagnostic capture (`/var/log/{tenant}-bun-death-diagnostics.log`) — read that log periodically.

If the file shows organic deaths (not your testing) at a rate of >1/24h, escalate to a real fix (probably grammy library upgrade, node version, or memory pressure). Don't accept watchdog-as-permanent-fix.

---

## What "production-ready" actually means here

This stack is **production-ready for one user, one tenant, weekly-ish deploy cadence**. It is not production-ready for:

- Daily deploy cadence — the cost ($0.07-$1 per deploy in cache rewrites + Claude API calls during smoke) adds up. Add a cost ledger first.
- Multi-tenant — most templates work but the docs assume one. The render path supports multiple tenants but no one's actually validated it end-to-end.
- Five-nines uptime — the watchdog gives ~5min recovery on bun-death; nginx + dashboard-chat have no auto-recovery beyond systemd Restart=.
- Hostile users — the gate model is "Daniel is on the allow-list, everyone else is dropped." If the threat model expands, the channels plugin's auth needs review.

That's fine. Don't over-engineer.

The honest scope:

> A side project that ships fearless deploys for one person, recovers gracefully from the most common failure modes, and surfaces real signal when it can't recover.

---

## Quick reference

| Need to... | Run |
|---|---|
| Validate before commit | `bash vps-setup/scripts/health.sh vps-setup/tenants/$T.yml` |
| Check if deploy is safe right now | `bash deploy.sh dry-run vX.Y.Z` (on VPS) |
| Ship a release | Telegram: `/deploy vX.Y.Z` → tap ✅ Ship → done |
| Recover from bun wedge | Watchdog auto-handles within 5 min; manual: `systemctl restart claude-agent.service` |
| Re-apply plugin patch | Auto on every claude-agent restart; manual: `bash patch-channels-plugin.sh` |
| Check stack health | `bash vps-setup/scripts/health.sh` |
| See what bun deaths look like | `tail -200 /var/log/$T-bun-death-diagnostics.log` |

---

## Backlog the operator should never let drop

These are in `vps-setup/queue/v2.23.0.yml` and `v2.24.0.yml`. If the chain of v2.22.x hotfixes taught us anything, it's that **deferring backlog items doesn't make them go away — it just makes the recovery happen at 1am one night.**

- bun-death root cause fix (after 7 days of diagnostic data)
- `/api/queue.json` + `/api/health` endpoint implementation
- Drive↔clone drift detection
- Schema validation flipped on at the server (DASHBOARD_DEBUG_VALIDATE=1 by default)
- `tg-send.sh --callback-buttons` migration for the existing CLAUDE.md "Approval flow" pattern (Ship/Hold/Revise on every draft — same broken-URL-button issue, untested fix needed)

Put a recurring calendar event for backlog review. Once a month. Forty minutes.
