#!/usr/bin/env bash
# Installs the Context7 MCP server (Upstash) — up-to-date, version-aware
# library documentation fetched at query time, so the agent codes against the
# current API instead of stale training data.
#
# What it does:
#   - Pre-pulls @upstash/context7-mcp via npx so the first invocation is fast
#   - Registers it with Claude Code as the 'context7' MCP server
#   - Adds the optional CONTEXT7_API_KEY (higher rate limits) from client.env
#   - Idempotent: skips registration if 'context7' is already in claude mcp list
#
# What it provides:
#   2 MCP tools:
#     - resolve-library-id(libraryName, query)  → returns Context7 IDs
#       like /upstash/context7 or /vercel/next.js
#     - get-library-docs(libraryId, query)      → version-scoped, current docs
#   Trigger phrase: append "use context7" to any prompt to force a docs lookup
#   before code generation. The CLAUDE.md rule installed by the template tells
#   the agent to do it automatically for any library/SDK/framework task.
#
# Free tier works without an API key. CONTEXT7_API_KEY (free, from
# https://context7.com/dashboard) just raises rate limits.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log_step "10 — Install Context7 MCP"

load_client_config

require_command npx
require_command claude

# Pre-pull the package so the first MCP invocation isn't a cold npx fetch
log_info "Pre-pulling @upstash/context7-mcp via npx..."
npx -y @upstash/context7-mcp@latest --help >/dev/null 2>&1 || true

# Determine where to register. Prefer the agent-project .mcp.json so the
# agent sees Context7 regardless of cwd (matches the GHL/Firecrawl pattern).
AGENT_MCP_JSON="${AGENT_MCP_JSON_PATH:-}"
API_KEY="${CONTEXT7_API_KEY:-}"

if [[ -n "${AGENT_MCP_JSON}" ]]; then
  if [[ ! -f "${AGENT_MCP_JSON}" ]]; then
    log_error "AGENT_MCP_JSON_PATH set to ${AGENT_MCP_JSON} but the file does not exist"
    log_error "Initialize it as {\"mcpServers\":{}} or unset AGENT_MCP_JSON_PATH"
    exit 1
  fi

  # Idempotent edit: if context7 already in mcpServers, leave it alone.
  if jq -e '.mcpServers.context7' "${AGENT_MCP_JSON}" >/dev/null 2>&1; then
    log_info "context7 already in ${AGENT_MCP_JSON} — leaving as-is"
  else
    log_info "Adding context7 to ${AGENT_MCP_JSON}"
    tmp="$(mktemp)"
    if [[ -n "${API_KEY}" ]]; then
      jq '.mcpServers.context7 = {
        "command": "npx",
        "args": ["-y", "@upstash/context7-mcp@latest", "--api-key", "${CONTEXT7_API_KEY}"],
        "env": { "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}" }
      }' "${AGENT_MCP_JSON}" > "${tmp}" && mv "${tmp}" "${AGENT_MCP_JSON}"
    else
      jq '.mcpServers.context7 = {
        "command": "npx",
        "args": ["-y", "@upstash/context7-mcp@latest"]
      }' "${AGENT_MCP_JSON}" > "${tmp}" && mv "${tmp}" "${AGENT_MCP_JSON}"
    fi
    log_info "  ✓ context7 written to ${AGENT_MCP_JSON}"
  fi
else
  # Fallback: register via `claude mcp add` (project / user scope)
  if claude mcp list 2>/dev/null | grep -qE '^context7\b'; then
    log_info "context7 already registered with Claude Code — skipping"
  else
    log_info "Registering context7 via 'claude mcp add'..."
    if [[ -n "${API_KEY}" ]]; then
      claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp@latest --api-key "${API_KEY}"
    else
      claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp@latest
    fi
    log_info "  ✓ registered (user scope)"
  fi
fi

if [[ -z "${API_KEY}" ]]; then
  log_warn "CONTEXT7_API_KEY not set — using the free anonymous tier (lower rate limits)."
  log_warn "Get a free key at https://context7.com/dashboard and re-run to upgrade."
fi

# ---------- enable in project trust list ----------
# Project-scoped MCPs from .mcp.json require approval before Claude Code will
# load them in dontAsk mode. Idempotently add 'context7' (and 'ghl' +
# 'firecrawl' for parity with the other installers) to
# projects[<CLAUDE_PROJECT_ROOT>].enabledMcpjsonServers in the user's
# ~/.claude.json. Without this, the server is registered in .mcp.json but
# never actually loaded by the agent.
#
# Caller env (with sensible defaults):
#   USER_CLAUDE_JSON_PATH  — override path to .claude.json
#   CLAUDE_PROJECT_ROOT    — the project key inside .claude.json
USER_CLAUDE_JSON="${USER_CLAUDE_JSON_PATH:-}"
if [[ -z "${USER_CLAUDE_JSON}" && -n "${CLAUDE_PROJECT_ROOT:-}" ]]; then
  # Convention: .claude.json sits in the linux user's HOME, one level above CLAUDE_PROJECT_ROOT
  USER_CLAUDE_JSON="$(dirname "${CLAUDE_PROJECT_ROOT}")/.claude.json"
fi

if [[ -n "${USER_CLAUDE_JSON}" && -f "${USER_CLAUDE_JSON}" && -n "${CLAUDE_PROJECT_ROOT:-}" ]]; then
  log_info "Enabling project MCPs (context7, ghl, firecrawl) in ${USER_CLAUDE_JSON}"
  tmp="$(mktemp)"
  jq --arg proj "${CLAUDE_PROJECT_ROOT}" '
    .projects[$proj].enabledMcpjsonServers =
      ((.projects[$proj].enabledMcpjsonServers // []) + ["context7", "ghl", "firecrawl"] | unique)
  ' "${USER_CLAUDE_JSON}" > "${tmp}" && mv "${tmp}" "${USER_CLAUDE_JSON}"
  log_info "  ✓ enabledMcpjsonServers updated"
else
  log_warn "USER_CLAUDE_JSON_PATH / CLAUDE_PROJECT_ROOT not set or .claude.json missing — skipping trust-list update."
  log_warn "If 'claude --print' refuses to call mcp__context7__*, manually add 'context7' to"
  log_warn "  projects[<your-project-root>].enabledMcpjsonServers in ~/.claude.json"
fi

log_info ""
log_info "Context7 installed."
log_info "  Tools:        resolve-library-id, get-library-docs"
log_info "  Trigger:      append 'use context7' to any prompt"
log_info "  Auto-use:     the agent's CLAUDE.md tells it to call Context7 for any library task"
log_info "  Verify:       jq '.mcpServers.context7' .mcp.json   (project MCPs do not show in 'claude mcp list')"

log_step "Context7 install complete"
log_implementation "10-install-context7-mcp.sh" "Registered Context7 MCP$([ -n "${API_KEY}" ] && echo ' (with API key)' || echo ' (anonymous tier)')"
