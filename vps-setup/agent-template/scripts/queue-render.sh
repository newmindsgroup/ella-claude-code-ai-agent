#!/usr/bin/env bash
# queue-render.sh — render approval queue (awaiting_review + awaiting_external + blocked) as MarkdownV2.
exec python3 "$(dirname "$0")/_queue_render.py" "$@"
