#!/usr/bin/env bash
# memory-vault.sh — persistent second brain for the chief-of-staff agent.
#
# Append-only event log + materialized indexes. Memory types:
#   fact         — atomic factual statements
#   decision     — choices made
#   relationship — people + companies + connections
#   preference   — likes/dislikes
#   pattern      — patterns the agent has detected
#   commitment   — promises made to others
#   goal         — strategic goals
#   context      — general background
#
# Subcommands:
#   add         --type T --text "..." [--tags "a,b,c"] [--source S] [--expires DATE] [--confidence 0.95] [--supersedes ID]
#   supersede   --id OLD_ID --type T --text "NEW TEXT" [--tags ...] [--source ...]
#               Saves new memory, marks old one as superseded. Use when facts change.
#   invalidate  --id MEMORY_ID [--reason "why"]   Mark a memory invalid without a replacement.
#   history     --id MEMORY_ID                    Show full validity chain for a memory.
#   recall      [--type T] [--tags "a,b"] [--query "fts"] [--since DATE] [--limit N] [--include-history]
#   summarize   [--type T] [--tags "a,b"] [--limit N]    Renders MarkdownV2 for Telegram
#   forget      --id MEMORY_ID
#   rebuild     Re-materialize indexes
#   list        List all memory IDs

set -euo pipefail

MEM_DIR="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}/memory"
VAULT="$MEM_DIR/vault.jsonl"
INDEX_DIR="$MEM_DIR/index"
HELPERS="$(dirname "$0")/_memory_helpers.py"

mkdir -p "$MEM_DIR" "$INDEX_DIR"
touch "$VAULT"
[[ ! -f "$INDEX_DIR/recent.json" ]] && echo "[]" > "$INDEX_DIR/recent.json"
[[ ! -f "$INDEX_DIR/by-id.json"  ]] && echo "{}" > "$INDEX_DIR/by-id.json"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
gen_id() { printf "m-%s-%s" "$(date +%Y%m%d)" "$(openssl rand -hex 2)"; }

cmd="${1:-help}"; shift || true
type_="" text="" tags="" source_="" expires="" confidence="0.9" links=""
id="" query="" since="" limit="20" supersedes="" include_history="" reason=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)        type_="$2"; shift 2 ;;
    --text)        text="$2"; shift 2 ;;
    --tags)        tags="$2"; shift 2 ;;
    --source)      source_="$2"; shift 2 ;;
    --expires)     expires="$2"; shift 2 ;;
    --confidence)  confidence="$2"; shift 2 ;;
    --links)       links="$2"; shift 2 ;;
    --id)          id="$2"; shift 2 ;;
    --query)       query="$2"; shift 2 ;;
    --since)       since="$2"; shift 2 ;;
    --limit)       limit="$2"; shift 2 ;;
    --supersedes)  supersedes="$2"; shift 2 ;;
    --include-history) include_history="1"; shift ;;
    --reason)      reason="$2"; shift 2 ;;
    *)             shift ;;
  esac
done

export MEM_DIR

usage() {
  cat <<EOF
memory-vault.sh — persistent second brain

Subcommands:
  add       --type T --text TEXT [--tags "a,b"] [--source S] [--expires DATE] [--confidence N] [--links id1,id2]
            Returns: new memory ID
  recall    [--type T] [--tags "a,b"] [--query "fts"] [--since DATE] [--limit N]
            Returns: JSON array of matching memories, newest first
  summarize [--type T] [--tags "a,b"] [--limit N]
            Returns: MarkdownV2 summary for Telegram
  forget    --id MEMORY_ID    Marks a memory as forgotten
  rebuild   Re-materialize indexes from vault.jsonl
  list      List all memory IDs

Vault: $VAULT
Indexes: $INDEX_DIR/
EOF
}

case "$cmd" in
  add)
    [[ -z "$type_" || -z "$text" ]] && { echo "missing --type or --text" >&2; exit 1; }
    new_id=$(gen_id)
    tags_json=$(python3 -c "import json,sys; t='$tags'; print(json.dumps([x.strip() for x in t.split(',') if x.strip()]))")
    links_json=$(python3 -c "import json,sys; t='$links'; print(json.dumps([x.strip() for x in t.split(',') if x.strip()]))")
    ev=$(jq -nc --arg ts "$(now)" --arg id "$new_id" --arg type "$type_" --arg text "$text" \
                --argjson tags "$tags_json" --arg source "$source_" --arg expires "$expires" \
                --arg conf "$confidence" --argjson links "$links_json" --arg sup "$supersedes" \
        '{ts:$ts, id:$id, event:"add", type:$type, text:$text, tags:$tags,
          source:$source, expires_at:(if $expires=="" then null else $expires end),
          created_at:$ts, confidence:($conf|tonumber), links:$links,
          supersedes:(if $sup=="" then null else $sup end)}')
    echo "$ev" >> "$VAULT"
    # If superseding an old memory, mark it
    if [[ -n "$supersedes" ]]; then
      sup_ev=$(jq -nc --arg ts "$(now)" --arg old_id "$supersedes" --arg new_id "$new_id" \
        '{ts:$ts, id:$old_id, event:"superseded_by", superseded_by:$new_id}')
      echo "$sup_ev" >> "$VAULT"
    fi
    python3 "$HELPERS" rebuild >/dev/null
    # Mirror to Discord (fire-and-forget, never block on failure)
    DISCORD_SCRIPT="$(dirname "$0")/discord-memory.sh"
    if [[ -x "$DISCORD_SCRIPT" ]]; then
      bash "$DISCORD_SCRIPT" post \
        --type "$type_" --text "$text" --tags "$tags" --id "$new_id" &>/dev/null &
      # For relationship memories, also create/update a client thread
      if [[ "$type_" == "relationship" ]]; then
        NAME=$(echo "$text" | python3 -c "import sys,re; m=re.match(r'^([^—\-\|]+)', sys.stdin.read()); print(m.group(1).strip() if m else '')")
        [[ -n "$NAME" ]] && bash "$DISCORD_SCRIPT" client-thread \
          --name "$NAME" --text "$text" &>/dev/null &
      fi
    fi
    echo "$new_id"
    ;;
  recall)
    MV_TYPE="$type_" MV_TAGS="$tags" MV_QUERY="$query" MV_SINCE="$since" MV_LIMIT="$limit" \
      MV_INCLUDE_HISTORY="$include_history" \
      python3 "$HELPERS" recall
    ;;
  summarize)
    MV_TYPE="$type_" MV_TAGS="$tags" MV_LIMIT="$limit" \
      python3 "$HELPERS" summarize
    ;;
  forget)
    [[ -z "$id" ]] && { echo "missing --id" >&2; exit 1; }
    ev=$(jq -nc --arg ts "$(now)" --arg id "$id" '{ts:$ts, id:$id, event:"forget"}')
    echo "$ev" >> "$VAULT"
    python3 "$HELPERS" rebuild >/dev/null
    echo "ok"
    ;;
  rebuild)
    python3 "$HELPERS" rebuild
    ;;
  list)
    jq -r 'keys[]' "$INDEX_DIR/by-id.json"
    ;;
  supersede)
    [[ -z "$id" || -z "$type_" || -z "$text" ]] && { echo "missing --id, --type, or --text" >&2; exit 1; }
    # Create new memory that supersedes the old one
    new_id=$(bash "$0" add --type "$type_" --text "$text" --tags "$tags" --source "$source_" \
                           --confidence "$confidence" --supersedes "$id")
    echo "$new_id"
    ;;
  invalidate)
    [[ -z "$id" ]] && { echo "missing --id" >&2; exit 1; }
    MV_ID="$id" MV_REASON="$reason" python3 "$HELPERS" invalidate
    python3 "$HELPERS" rebuild >/dev/null
    ;;
  history)
    [[ -z "$id" ]] && { echo "missing --id" >&2; exit 1; }
    MV_ID="$id" python3 "$HELPERS" history
    ;;
  help|*)
    usage; exit 0
    ;;
esac
