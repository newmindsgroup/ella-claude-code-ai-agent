#!/usr/bin/env bash
# voice-transcribe.sh — transcribe a Telegram voice note via whisper.cpp.
#
# Usage:
#   voice-transcribe.sh /path/to/voice.ogg                    (DEFAULT: --lang auto, multilingual)
#   voice-transcribe.sh /path/to/voice.ogg --lang en          (force English, fastest)
#   voice-transcribe.sh /path/to/voice.ogg --lang es          (force Spanish)
#   voice-transcribe.sh /path/to/voice.ogg --lang auto        (explicit auto-detect)
#
# Default changed 2026-05-04: was --lang en (Halifax legacy assumption).
# Daniel is in Santo Domingo and speaks both English and Spanish, so
# auto-detect via the multilingual model is the correct default.
#
# Output format:
#   [LANG=xx] transcript text...
# The LANG prefix lets the caller route TTS reply to the matching voice.
#
# Models in use:
#   - small.en (forced --lang en, fastest, English-only, ~3-5s for 30s audio)
#   - small    (multilingual, supports 99 languages, ~5-15s for 30s audio)
set -euo pipefail

WHISPER_DIR="${TENANT_USER_HOME:-/opt/{{TENANT_LINUX_USER}}}/whisper.cpp"

# Resolve binary path
WHISPER_BIN=""
for candidate in \
  "$WHISPER_DIR/build/bin/whisper-cli" \
  "$WHISPER_DIR/build/whisper-cli" \
  "$WHISPER_DIR/main"; do
  if [[ -x "$candidate" ]]; then
    WHISPER_BIN="$candidate"
    break
  fi
done
[[ -z "$WHISPER_BIN" ]] && { echo "ERROR: whisper-cli not found in $WHISPER_DIR" >&2; exit 1; }

INPUT="${1:-}"
[[ -z "$INPUT" ]] && { echo "usage: $0 <audio-file> [--lang auto|en|es|fr|...]" >&2; exit 1; }
[[ ! -f "$INPUT" ]] && { echo "file not found: $INPUT" >&2; exit 1; }

# Default: auto (multilingual) — was 'en' before 2026-05-04.
LANG_FLAG="auto"
MODEL=""

# Parse --lang
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) LANG_FLAG="$2"; shift 2 ;;
    *)      shift ;;
  esac
done

# Pick model: small.en for forced English, small (multilingual) otherwise.
if [[ "$LANG_FLAG" == "en" ]]; then
  MODEL="$WHISPER_DIR/models/ggml-small.en.bin"
else
  MULTI_MODEL="$WHISPER_DIR/models/ggml-small.bin"
  if [[ -f "$MULTI_MODEL" ]]; then
    MODEL="$MULTI_MODEL"
  else
    echo "WARN: multilingual model not found at $MULTI_MODEL — falling back to small.en (English only)" >&2
    MODEL="$WHISPER_DIR/models/ggml-small.en.bin"
    LANG_FLAG="en"
  fi
fi

# Transcode to 16kHz mono WAV (whisper.cpp requirement).
WORKDIR="$(mktemp -d /tmp/voice-transcribe.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
WAV="$WORKDIR/input.wav"
ffmpeg -loglevel error -i "$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV"

# Run whisper. -nt = no timestamps. We deliberately DROP -np (no-progress)
# so that whisper's "whisper_full_with_state: auto-detected language: xx"
# line lands in stderr where we can parse it. Captured to a separate file
# so progress noise doesn't corrupt stdout.
STDERR_LOG="$WORKDIR/whisper.stderr"
TRANSCRIPT=$("$WHISPER_BIN" -m "$MODEL" -f "$WAV" -l "$LANG_FLAG" -t 2 -nt 2>"$STDERR_LOG")

# Extract detected language from whisper's stderr (when --lang auto). The
# `|| true` is essential — grep exits 1 on no-match and `set -e` would
# kill the script. We have a fallback below so non-match is recoverable.
DETECTED_LANG="$LANG_FLAG"
if [[ "$LANG_FLAG" == "auto" ]]; then
  DETECTED_LANG=$(grep -oE 'auto-detected language: [a-z]{2}' "$STDERR_LOG" 2>/dev/null | tail -1 | awk '{print $NF}' || true)
  [[ -z "$DETECTED_LANG" ]] && DETECTED_LANG="en"  # fallback if parse fails
fi

# Trim leading/trailing whitespace from transcript for tidy output.
TRANSCRIPT=$(echo "$TRANSCRIPT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r')

# Emit transcript with language prefix on first line. Caller can grep
# the prefix to pick the right TTS voice.
echo "[LANG=$DETECTED_LANG] $TRANSCRIPT"
