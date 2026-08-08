#!/usr/bin/env bash
# Run the coding agent selected in agent.yaml and stream readable output.
#
# Usage: run-agent.sh <prompt-file> <claude-budget-usd> <stream-jsonl>
set -uo pipefail

prompt_file=$1
budget_usd=$2
stream_file=$3
project_dir=$(cd "$(dirname "$0")" && pwd)
config_file="$project_dir/agent.yaml"
agent=$(awk '/^[[:space:]]*agent:[[:space:]]*/ {print $2; exit}' "$config_file")

case "$agent" in
  codex)
    codex exec \
      --json \
      --dangerously-bypass-approvals-and-sandbox \
      - \
      < "$prompt_file" \
      | tee "$stream_file" \
      | jq -r --unbuffered -f "$project_dir/render-agent-stream.jq"
    ;;
  claude)
    claude -p "$(cat "$prompt_file")" \
      --permission-mode bypassPermissions \
      --model opus \
      --output-format stream-json \
      --verbose \
      --max-budget-usd "$budget_usd" \
      | tee "$stream_file" \
      | jq -r --unbuffered -f "$project_dir/render-agent-stream.jq"
    ;;
  *)
    printf 'Unsupported agent %s in %s (expected codex or claude)\n' \
      "${agent:-<empty>}" "$config_file" >&2
    exit 2
    ;;
esac
