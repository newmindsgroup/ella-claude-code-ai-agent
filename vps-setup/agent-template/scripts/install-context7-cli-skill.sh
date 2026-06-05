#!/usr/bin/env bash
# install-context7-cli-skill.sh — installs the context7-cli skill into the
# agent's VPS skill library so skill-runner.sh and dispatched sub-agents
# can invoke the `ctx7` CLI (Context7's documentation CLI — parallel surface
# to the MCP path; same Upstash-hosted docs, different invocation model).
#
# Usage: sudo bash {{TENANT_AGENT_HOME}}/scripts/install-context7-cli-skill.sh
#
# Idempotent: skips skill copy if SKILL.md already present; skips npm install
# if `ctx7` is already on PATH.

set -euo pipefail

TARGET_DIR="{{TENANT_AGENT_HOME}}/{{TENANT_AGENT_SKILLS_DIR}}/context7-cli"
SOURCE_DIR="{{TENANT_AGENT_HOME}}/{{TENANT_BRAND_REPO_NAME}}/vps-setup/agents-config/{{TENANT_LINUX_USER}}/skills-bundle/context7-cli"
LINUX_USER="{{TENANT_LINUX_USER}}"
LINUX_GROUP="{{TENANT_LINUX_GROUP}}"

# 1) ctx7 CLI — install globally if missing. Warn-only on failure since the
#    MCP path (10-install-context7-mcp.sh) still works without the CLI.
if ! command -v ctx7 >/dev/null 2>&1; then
  echo "[install-context7-cli-skill] ctx7 not on PATH — attempting global npm install"
  if npm install -g ctx7@latest >/dev/null 2>&1; then
    echo "[install-context7-cli-skill]   ✓ ctx7 $(ctx7 --version 2>/dev/null || echo "installed")"
  else
    echo "[install-context7-cli-skill]   ⚠ npm install failed — MCP path still works without CLI" >&2
  fi
else
  echo "[install-context7-cli-skill] ctx7 already present: $(ctx7 --version 2>/dev/null || echo unknown)"
fi

# 2) Skill files — mirror from the rendered tenant skills-bundle into the
#    agent's runtime skill library
if [[ -f "${TARGET_DIR}/SKILL.md" ]]; then
  echo "[install-context7-cli-skill] ${TARGET_DIR}/SKILL.md already present — skipping copy"
else
  if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "[install-context7-cli-skill] ERROR: source ${SOURCE_DIR} missing — render-tenant.sh did not produce skills-bundle" >&2
    exit 1
  fi
  mkdir -p "${TARGET_DIR}"
  cp -R "${SOURCE_DIR}/." "${TARGET_DIR}/"
  chown -R "${LINUX_USER}:${LINUX_GROUP}" "${TARGET_DIR}"
  echo "[install-context7-cli-skill]   ✓ skill installed to ${TARGET_DIR}"
fi

echo "[install-context7-cli-skill] done"
