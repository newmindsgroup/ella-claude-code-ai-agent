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
#   add       --type T --text "..." [--tags "a,b,c"] [--source S] [--expires DATE] [--confidence 0.95] [--links id1,id2]
#   recall    [--type T] [--tags "a,b"] [--query "fts"] [--since DATE] [--limit N]
#   summarize [--type T] [--tags "a,b"] [--limit N]    Renders MarkdownV2 for Telegram
#   forget    --id MEMORY_ID
#   rebuild   Re-materialize indexes
#   list      List all memory IDs

set -euo pipefail

MEM_DIR="${TENANT_AGENT_HOME:-/opt/{{TENANT_LINUX_USER}}/agents}/memory"
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
id="" query="" since="" limit="20"
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
                --arg conf "$confidence" --argjson links "$links_json" \
        '{ts:$ts, id:$id, event:"add", type:$type, text:$text, tags:$tags,
          source:$source, expires_at:(if $expires=="" then null else $expires end),
          created_at:$ts, confidence:($conf|tonumber), links:$links}')
    echo "$ev" >> "$VAULT"
    python3 "$HELPERS" rebuild >/dev/null
    echo "$new_id"
    ;;
  recall)
    MV_TYPE="$type_" MV_TAGS="$tags" MV_QUERY="$query" MV_SINCE="$since" MV_LIMIT="$limit" \
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
  help|*)
    usage; exit 0
    ;;
esac
