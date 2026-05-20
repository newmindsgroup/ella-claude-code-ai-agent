"""
conftest.py — pytest fixtures for Ella template pure-logic tests.

This template ships five pure-logic test files that pin the contracts of the
Phase 1-4 Mission Control modules (_spans, _roi, _budget, _deploy_states,
_watcher_base). They run with no VPS, no network, no secrets — making them
safe to run in CI or on a fresh template clone before any tenant is rendered.

Once you stand up a real tenant, you'll typically extend this conftest with
fixtures that talk to your live VPS (auth, base_url, schema validation, etc.)
— the upstream production tenant has a fuller example in its conftest.py
that's worth referencing when you're ready to add integration tests.

Run:
  pytest                          # all pure-logic tests
  pytest -n auto                  # parallel (pytest-xdist)
  pytest --junitxml=results.xml   # CI integration
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Make the agent-template scripts importable. The Phase 1-4 modules
# (_spans, _roi, _budget, _deploy_states, _watcher_base) live there.
REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "vps-setup" / "agent-template" / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
