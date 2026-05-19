#!/usr/bin/env bash
# install-openswarm.sh — install VRSEN OpenSwarm framework + wire to the agent.
#
# OpenSwarm (https://github.com/VRSEN/OpenSwarm) is an 8-specialist multi-agent
# system for generating slides, reports, visualizations, documents, images,
# videos from a single prompt. This installer:
#
#   1. Installs Node 20+ + Python 3.10+ if missing
#   2. Clones the VRSEN OpenSwarm repo to {agent_home}/openswarm-repo
#   3. Runs `npm install -g @vrsen/openswarm` for the global CLI
#   4. Verifies the openswarm CLI is callable
#   5. Documents how the agent's swarm-router.sh dispatches to it
#
# OpenSwarm is OPTIONAL. The agent's built-in swarms (bizdev, content, delivery,
# onboarding) work without OpenSwarm — they use `claude --print` for the LLM
# step. OpenSwarm adds heavy-lift capabilities (Sora/Veo video, Gemini image gen,
# Composio 10K+ integrations) that the lightweight swarms can't replicate.
#
# Set features.multi_agent_swarms = true in tenant.yml to enable.
set -euo pipefail

TENANT_AGENT_HOME="${TENANT_AGENT_HOME:-/opt/{{TENANT_LINUX_USER}}/agents}"
TENANT_USER_HOME="${TENANT_USER_HOME:-/opt/{{TENANT_LINUX_USER}}}"
OPENSWARM_DIR="$TENANT_AGENT_HOME/openswarm-repo"
LINUX_USER="${1:-{{TENANT_LINUX_USER}}}"

log() { echo "[$(date -u +%FT%TZ)] [install-openswarm] $*"; }

log "=== STARTED ==="

# 1. Prereqs
log "checking node + python prereqs"
if ! command -v node >/dev/null 2>&1; then
  log "installing Node.js 20.x"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
  sudo apt-get install -y nodejs
fi
if ! command -v python3 >/dev/null 2>&1; then
  log "installing Python 3"
  sudo apt-get install -y python3 python3-pip
fi
log "node $(node --version), python $(python3 --version)"

# 2. Clone VRSEN/OpenSwarm
if [[ ! -d "$OPENSWARM_DIR/.git" ]]; then
  log "cloning VRSEN/OpenSwarm to $OPENSWARM_DIR"
  sudo -u "$LINUX_USER" git clone https://github.com/VRSEN/OpenSwarm.git "$OPENSWARM_DIR"
else
  log "$OPENSWARM_DIR already a git repo — pulling latest"
  sudo -u "$LINUX_USER" git -C "$OPENSWARM_DIR" pull --ff-only 2>&1 | tail -2
fi

# 3. Install global openswarm CLI
if ! command -v openswarm >/dev/null 2>&1; then
  log "installing @vrsen/openswarm globally"
  sudo npm install -g @vrsen/openswarm
else
  log "openswarm CLI already installed ($(openswarm --version 2>&1 | head -1))"
fi

# 4. Verify
if ! sudo -u "$LINUX_USER" -H bash -c 'openswarm --help' >/dev/null 2>&1; then
  log "ERROR: openswarm CLI not callable as $LINUX_USER"
  exit 1
fi
log "openswarm CLI verified callable"

# 5. Ensure the agent's swarms/ dir has read access to openswarm-repo
log "wiring swarms/openswarm_runner.py to find openswarm-repo via OPENSWARM_DIR env"
echo "OPENSWARM_DIR=$OPENSWARM_DIR" | sudo tee -a "$TENANT_AGENT_HOME/.env" > /dev/null

log "=== DONE ==="
log "Next: agent's CLAUDE.md instructs to use 'swarm-router.sh openswarm --task ...' for "
log "      heavy-lift jobs (slide decks, video gen, data analysis, deep research)."
log "      The lightweight built-in swarms (bizdev/content/delivery/onboarding) work "
log "      without OpenSwarm and run faster for those specific domains."
