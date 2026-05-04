#!/usr/bin/env bash
# graph-query.sh — knowledge-graph queries over the memory vault.
#
# Subcommands:
#   who <name-or-topic>    Renders MarkdownV2 with everything we know
#                          related to a person, company, or topic
set -euo pipefail
exec python3 "$(dirname "$0")/_graph_helpers.py" "$@"
