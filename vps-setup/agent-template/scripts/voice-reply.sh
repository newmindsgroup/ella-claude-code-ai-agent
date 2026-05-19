#!/usr/bin/env bash
# voice-reply.sh — synthesize text to a Telegram-ready voice note (OGG/Opus).
#
# Usage:
#   voice-reply.sh "Hello, here's your update."                  (default: en-US Andrew)
#   voice-reply.sh --lang es "Buenos días, aquí tu resumen."     (Spanish — see DEFAULT_ES below)
#   voice-reply.sh --lang auto "..."                              (detect from text)
#   voice-reply.sh --voice es-DO-RamonaNeural "..."               (specific voice)
#   voice-reply.sh --out /path/to/output.ogg "..."                (default: /tmp/voice-reply-PID.ogg)
#
# Output is OGG/Opus 16kHz mono — Telegram sendVoice format. Prints the
# output file path on stdout. Failures go to stderr with non-zero exit.
#
# TTS engine: edge-tts (Microsoft Edge, free, no API key). MP3 from edge-tts
# is transcoded to OGG/Opus via ffmpeg. Average synthesis time ~1-2s for
# typical sentences.
#
# Voice selection (defaults — override via --voice or change DEFAULT_ES / DEFAULT_EN below):
#   en  → en-US-AndrewNeural (warm, confident, conversational)
#   es  → es-DO-EmilioNeural (a Spanish voice — the full list of regional
#         options is at https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support
#         pick es-MX, es-ES, es-AR, es-CO, etc. to match your tenant's locale)
#   auto → simple heuristic on the first 200 chars (no library dependency)
set -euo pipefail

EDGE_TTS="${EDGE_TTS:-/opt/{{TENANT_LINUX_USER}}/.local/bin/edge-tts}"
[[ -x "$EDGE_TTS" ]] || { echo "ERROR: edge-tts not found at $EDGE_TTS" >&2; exit 1; }

LANG_FLAG="auto"
VOICE=""
OUT=""
TEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang)  LANG_FLAG="$2"; shift 2 ;;
    --voice) VOICE="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    --) shift; TEXT="$*"; break ;;
    *)  TEXT="$1"; shift ;;
  esac
done

[[ -z "$TEXT" ]] && { echo "usage: $0 [--lang en|es|auto] [--voice VOICE] [--out PATH] \"text\"" >&2; exit 1; }

# Auto-detect language: count Spanish-distinctive markers in first 200 chars.
detect_lang() {
  local sample="${TEXT:0:200}"
  # Lowercase + count Spanish-only character/word markers.
  local lower
  lower=$(printf '%s' "$sample" | tr '[:upper:]' '[:lower:]')
  local es_markers=0
  # Spanish-specific characters
  for ch in 'ñ' '¿' '¡' 'á' 'é' 'í' 'ó' 'ú'; do
    es_markers=$((es_markers + $(printf '%s' "$lower" | grep -o "$ch" 2>/dev/null | wc -l)))
  done
  # Spanish-distinctive function words (whole-word match via space boundaries)
  for word in ' el ' ' la ' ' los ' ' las ' ' que ' ' para ' ' está ' ' está ' ' como ' ' por ' ' con ' ' una ' ' uno ' ' del ' ' al ' ' eso ' ' este ' ' esta '; do
    [[ "$lower" == *"$word"* ]] && es_markers=$((es_markers + 1))
  done
  if [[ $es_markers -ge 2 ]]; then echo es; else echo en; fi
}

if [[ "$LANG_FLAG" == "auto" ]]; then
  LANG_FLAG=$(detect_lang)
fi

if [[ -z "$VOICE" ]]; then
  case "$LANG_FLAG" in
    es) VOICE="es-DO-EmilioNeural" ;;
    en) VOICE="en-US-AndrewNeural" ;;
    *)  VOICE="en-US-AndrewNeural" ;;
  esac
fi

[[ -z "$OUT" ]] && OUT="/tmp/voice-reply-$$.ogg"

WORKDIR="$(mktemp -d /tmp/voice-reply.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
MP3="$WORKDIR/tts.mp3"

# 1. Synthesize via edge-tts (writes MP3)
"$EDGE_TTS" --voice "$VOICE" --text "$TEXT" --write-media "$MP3" >/dev/null 2>&1 || {
  echo "ERROR: edge-tts synthesis failed for voice=$VOICE" >&2
  exit 2
}

# 2. Transcode MP3 → OGG/Opus 16kHz mono (Telegram sendVoice format)
ffmpeg -loglevel error -y -i "$MP3" \
  -c:a libopus -b:a 32k -ar 48000 -ac 1 \
  -application voip "$OUT" 2>/dev/null || {
  echo "ERROR: ffmpeg transcode to OGG/Opus failed" >&2
  exit 3
}

[[ -s "$OUT" ]] || { echo "ERROR: output file empty: $OUT" >&2; exit 4; }
echo "$OUT"
