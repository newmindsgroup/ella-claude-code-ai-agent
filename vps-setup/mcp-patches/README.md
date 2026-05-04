# MCP patches

Local patches we keep applied on top of upstream MCP servers, with re-apply tooling so a fresh `git reset --hard` or hard checkout doesn't silently re-introduce the bugs.

## What's here

| Patch | Affects | Applies to |
|---|---|---|
| `0001-ghl-mcp-results-accounts.patch` | `@mastanley13/ghl-mcp-server` `getSocialAccounts()` reads `response.data?.accounts` (always undefined — GHL nests under `results.accounts`). Patch: defensive `data?.results?.accounts ?? data?.accounts ?? []` | Cowork copy (`~/mcp-servers/GoHighLevel-MCP/`) and Agent copy (`/opt/{{TENANT_LINUX_USER}}/agents/ghl-mcp/`) |

## When the patch needs re-application

`npm install` is safe — patches live in `src/`, not `node_modules/`. The patch will be **wiped** by:

- A `git reset --hard` on the MCP repo
- `git pull` from upstream that touches the same hunks (without proper merge)
- A fresh `git clone` of the MCP repo

## How to re-apply

From the {{TENANT_BRAND_REPO_NAME}} repo root:

```bash
bash vps-setup/mcp-patches/apply.sh
```

The script applies every `.patch` file here to both the Cowork and Agent copies, idempotently (skips if already applied).

## How to add a new patch

```bash
# Make + test the change in the MCP repo
cd ~/mcp-servers/GoHighLevel-MCP
git add src/some/file.ts
git commit -m "[local patch] short description"

# Export the commit as a patch into this dir
git format-patch -1 HEAD --stdout > /path/to/{{TENANT_BRAND_REPO_NAME}}/vps-setup/mcp-patches/000X-short-name.patch

# Mirror the commit on the VPS agent's copy
ssh root@projectizer "sudo -u danielgonell -H bash -c 'cd /opt/{{TENANT_LINUX_USER}}/agents/ghl-mcp && git apply --3way' " < /path/to/the.patch
```
