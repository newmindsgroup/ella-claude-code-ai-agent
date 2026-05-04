#!/usr/bin/env bash
# pref.sh — read/write agent preferences as a single JSON file.
#
# Used by /voice to persist mode (off|reply|always) across restarts,
# and by anything else that needs sticky user-level preferences.
#
# Usage:
#   pref.sh get <key>                        → prints value (empty if unset)
#   pref.sh get <key> <default>              → prints value or default if unset
#   pref.sh set <key> <value>                → writes (atomic, idempotent)
#   pref.sh dump                             → prints full prefs JSON
#   pref.sh delete <key>                     → unsets a key
#
# Storage: {{TENANT_AGENT_HOME}}/preferences.json. Atomic write via tempfile + mv.
# JSON is created on first write — no init step needed.
#
# Keys currently in use:
#   voice_mode          off | reply | always   (default: reply)
#   voice_lang_override null | en | es         (forces reply language; null = auto)
#   voice_speaker_en    e.g. en-US-AndrewNeural
#   voice_speaker_es    e.g. es-DO-EmilioNeural
set -euo pipefail

PREFS="{{TENANT_AGENT_HOME}}/preferences.json"

cmd="${1:-help}"; shift || true

ensure_file() {
  if [[ ! -f "$PREFS" ]]; then
    mkdir -p "$(dirname "$PREFS")"
    echo '{}' > "$PREFS"
  fi
}

case "$cmd" in
  get)
    key="${1:?missing key}"
    default="${2:-}"
    [[ ! -f "$PREFS" ]] && { echo "$default"; exit 0; }
    val=$(jq -r --arg k "$key" 'if has($k) and (.[$k] != null) then .[$k] else "" end' "$PREFS")
    [[ -z "$val" ]] && val="$default"
    echo "$val"
    ;;
  set)
    key="${1:?missing key}"
    value="${2:?missing value}"
    ensure_file
    tmp="$(mktemp)"
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$PREFS" > "$tmp"
    mv "$tmp" "$PREFS"
    echo "$value"
    ;;
  delete|del|unset)
    key="${1:?missing key}"
    [[ ! -f "$PREFS" ]] && exit 0
    tmp="$(mktemp)"
    jq --arg k "$key" 'del(.[$k])' "$PREFS" > "$tmp"
    mv "$tmp" "$PREFS"
    ;;
  dump)
    [[ -f "$PREFS" ]] && cat "$PREFS" || echo '{}'
    ;;
  help|*)
    cat <<EOF
pref.sh — agent preferences store

  pref.sh get <key> [default]
  pref.sh set <key> <value>
  pref.sh delete <key>
  pref.sh dump
EOF
    ;;
esac
