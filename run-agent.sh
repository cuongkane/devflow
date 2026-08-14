#!/usr/bin/env bash
# Run the coding agent selected in agent.yaml and stream readable output.
#
# Usage: run-agent.sh <prompt-file> <budget-usd> <stream-jsonl> [tier]
#
# tier is fast, standard or deep. agent.yaml maps it to a concrete model for
# whichever agent is selected, so a DAG step asks for depth without naming a
# model -- and switching agent.yaml from codex to claude keeps every step valid.
set -uo pipefail

prompt_file=$1
budget_usd=$2
stream_file=$3
tier=${4:-standard}

case "$tier" in
  fast|standard|deep) ;;
  *)
    printf 'Unsupported tier %s (expected fast, standard or deep)\n' "$tier" >&2
    exit 2
    ;;
esac

project_dir=$(cd "$(dirname "$0")" && pwd)
config_file="$project_dir/agent.yaml"
agent=$(awk '/^[[:space:]]*agent:[[:space:]]*/ {print $2; exit}' "$config_file")

# Read one flat `key: value` pair from agent.yaml. A missing key and the literal
# `default` are the same answer -- let the CLI pick -- so a tier nobody has tuned
# degrades to the CLI's own configuration instead of breaking the run.
setting() {
  value=$(awk -v key="$1:" '$1 == key { print $2; exit }' "$config_file")
  [ "$value" = default ] && value=""
  printf '%s' "$value"
}

model=$(setting "model_${agent}_${tier}")

case "$agent" in
  codex)
    # Build the flags as an array: an unset model must contribute no argument at
    # all, and an empty string would be passed as one.
    args=(exec --json --dangerously-bypass-approvals-and-sandbox)
    [ -n "$model" ] && args+=(--model "$model")
    effort=$(setting "effort_codex_${tier}")
    [ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")
    printf 'agent: codex  tier: %s  model: %s  effort: %s\n' \
      "$tier" "${model:-<cli default>}" "${effort:-<cli default>}" >&2

    codex "${args[@]}" - \
      < "$prompt_file" \
      | tee "$stream_file" \
      | jq -r --unbuffered -f "$project_dir/render-agent-stream.jq"
    ;;
  claude)
    args=(-p "$(cat "$prompt_file")"
          --permission-mode bypassPermissions
          --output-format stream-json
          --verbose
          --max-budget-usd "$budget_usd")
    [ -n "$model" ] && args+=(--model "$model")
    printf 'agent: claude  tier: %s  model: %s  budget: $%s\n' \
      "$tier" "${model:-<cli default>}" "$budget_usd" >&2

    claude "${args[@]}" \
      | tee "$stream_file" \
      | jq -r --unbuffered -f "$project_dir/render-agent-stream.jq"
    ;;
  *)
    printf 'Unsupported agent %s in %s (expected codex or claude)\n' \
      "${agent:-<empty>}" "$config_file" >&2
    exit 2
    ;;
esac
