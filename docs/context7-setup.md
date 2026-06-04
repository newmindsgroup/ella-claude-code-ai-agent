# Context7 setup — already in the template, awaiting nothing (free tier just works)

[Context7](https://github.com/upstash/context7) (Upstash) is an MCP server that
fetches **up-to-date, version-specific library documentation** at query time.
The agent calls it before generating any code that uses a third-party library,
so the output matches today's API surface instead of training-data guesswork.

## What the template already ships (auto-wired on every deploy)

| Piece | Where | Auto-applied? |
|---|---|---|
| **Installer** | `agent-stack/scripts/10-install-context7-mcp.sh` | yes — by `install-capabilities.sh` |
| **`.mcp.json` registration** | `.mcp.json` `mcpServers.context7` block (rendered template) | yes |
| **CLAUDE.md rule** ("always use Context7 before generating library code") | `CLAUDE.md.tmpl` — high in the file, right after Operating Principles | yes |
| **`features.context7: true`** flag in `tenant.yml` | `EXAMPLE_TENANT.yml` | default on |

## What the agent gets

Two MCP tools, called as a pair:

- **`mcp__context7__resolve-library-id(libraryName, query)`** — resolves a name
  like *next.js* or *supabase* to a Context7 ID (e.g. `/vercel/next.js`,
  `/supabase/supabase`).
- **`mcp__context7__get-library-docs(libraryId, query)`** — fetches
  version-scoped docs + code examples for the specific question.

The agent runs them automatically when the request involves a library API. The
user can also append **`use context7`** to any prompt to force the lookup, and
can name a version explicitly (e.g. *"Next.js 15 middleware. use context7"*).

## What YOU provide (optional)

Nothing required. The free anonymous tier works out of the box.

For higher rate limits — useful on a busy production agent — grab a **free**
API key at https://context7.com/dashboard and put it in
`client-credentials.md`:

```yaml
context7_api_key: "ctx7_xxxxxxxxxxxxxxxxxxxxxxxx"
```

The deploy wires it into `CONTEXT7_API_KEY` so the MCP picks it up. To upgrade
an already-running deploy: set the env var in the agent's `.env` and re-run
`install-capabilities.sh`.

## Verify it's live

```bash
sudo -u <linux_user> -H claude mcp list | grep context7
# context7  ✓ connected
```

In a Claude Code session in the agent's project, ask: *"What's the current API
for the Stripe Node SDK? use context7"* — the agent should call
`resolve-library-id` → `get-library-docs` and answer from the returned snippets,
not training data.
