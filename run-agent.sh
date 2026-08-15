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

# `<cli default>` rather than an empty string: for codex every tier currently
# maps to `default`, and a blank field in the log reads as "nobody chose", which
# is exactly the question this line exists to answer.
model_shown=${model:-<cli default>}

case "$agent" in
  codex)
    # Build the flags as an array: an unset model must contribute no argument at
    # all, and an empty string would be passed as one.
    args=(exec --json --dangerously-bypass-approvals-and-sandbox)
    [ -n "$model" ] && args+=(--model "$model")
    effort=$(setting "effort_codex_${tier}")
    [ -n "$effort" ] && args+=(-c "model_reasoning_effort=\"$effort\"")

    # stdout, not stderr: which model ran a phase is the first thing anyone asks
    # of a run log, and the dagu UI keeps stderr in a separate pane. This printf
    # is not part of the pipe into jq below, so it cannot corrupt the renderer.
    printf 'agent: codex  tier: %s  model: %s  effort: %s\n' \
      "$tier" "$model_shown" "${effort:-<cli default>}"

    codex "${args[@]}" - \
      < "$prompt_file" \
      | tee "$stream_file" \
      | jq -r --unbuffered \
          --arg agent codex --arg tier "$tier" --arg model "$model_shown" \
          -f "$project_dir/render-agent-stream.jq"
    ;;
  claude)
    # Claude Code exits 1 before emitting a token if bypassPermissions is asked
    # for by uid 0, unless IS_SANDBOX is set. The worker container is root by
    # construction -- every credential mount lands under /root -- so the flag can
    # never be used there without this. Setting it in compose.yaml is not enough:
    # dagu step subprocesses do not reliably carry the worker's environment,
    # which is the same reason worker-entrypoint.sh materializes a gh config
    # instead of trusting GH_TOKEN to arrive. Exporting it in the process that
    # execs claude is the only placement that cannot be lost in between.
    # Harmless off-container: on the macOS host uid is not 0, so the check the
    # variable disarms never fires.
    export IS_SANDBOX=1

    # Claude Code on the host keeps its OAuth credentials in the macOS Keychain,
    # which a Linux container cannot read -- the same problem worker-entrypoint.sh
    # solves for gh. So the worker carries its own credential: a dedicated
    # `claude setup-token` token, which is revocable on its own without touching
    # the login on this Mac. The file sits inside the project tree, which is
    # already mounted into the worker, so it needs no mount of its own.
    #
    # Read into the environment here rather than declared in compose.yaml: an
    # `environment:` entry is visible to `docker inspect` and to every step
    # subprocess, and it would not survive the trip in anyway -- same reason as
    # IS_SANDBOX above.
    token_file="$project_dir/.secrets/claude-oauth-token"
    if [ -r "$token_file" ]; then
      CLAUDE_CODE_OAUTH_TOKEN=$(cat "$token_file")
      export CLAUDE_CODE_OAUTH_TOKEN
    elif [ "$(id -u)" = 0 ]; then
      # uid 0 means the worker container, where there is no Keychain to fall back
      # to. Fail loudly rather than let claude start: unauthenticated it returns
      # `Not logged in` as its one and only turn, at zero cost, and the phase
      # contract has no way to tell that apart from a real answer.
      printf 'No agent token at %s\n' "$token_file" >&2
      printf 'Run `claude setup-token` on the host and write it to that file.\n' >&2
      exit 2
    fi

    args=(-p "$(cat "$prompt_file")"
          --permission-mode bypassPermissions
          --output-format stream-json
          --verbose
          --max-budget-usd "$budget_usd")
    [ -n "$model" ] && args+=(--model "$model")
    printf 'agent: claude  tier: %s  model: %s  budget: $%s\n' \
      "$tier" "$model_shown" "$budget_usd"

    claude "${args[@]}" \
      | tee "$stream_file" \
      | jq -r --unbuffered \
          --arg agent claude --arg tier "$tier" --arg model "$model_shown" \
          -f "$project_dir/render-agent-stream.jq"
    ;;
  opencode)
    # `--auto` is opencode's non-interactive permission mode: without it a tool
    # call that needs approval waits for a TUI that does not exist here, and the
    # phase hangs until its timeout instead of failing. It is the counterpart of
    # codex's --dangerously-bypass-approvals-and-sandbox and claude's
    # bypassPermissions, and it is acceptable for the same reason: the worker
    # container is the sandbox.
    args=(run --format json --auto)
    [ -n "$model" ] && args+=(--model "$model")
    variant=$(setting "variant_opencode_${tier}")
    [ -n "$variant" ] && args+=(--variant "$variant")

    # opencode has no spend cap flag, so $budget_usd is accepted and ignored --
    # same as codex. Say so in the log rather than printing a budget the run is
    # not actually held to.
    printf 'agent: opencode  tier: %s  model: %s  variant: %s  budget: not enforced\n' \
      "$tier" "$model_shown" "${variant:-<cli default>}"

    # Prompt on stdin, not as a positional argument: `opencode run` accepts both,
    # but a phase prompt is thousands of words of markdown and putting it on the
    # command line exposes it to ARG_MAX and to the process table.
    opencode "${args[@]}" \
      < "$prompt_file" \
      | tee "$stream_file" \
      | jq -r --unbuffered \
          --arg agent opencode --arg tier "$tier" --arg model "$model_shown" \
          -f "$project_dir/render-agent-stream.jq"
    status=$?

    # Session id last, not first: opencode has no session-start event -- every
    # event carries sessionID and none announces it -- so the earliest point at
    # which it can be printed exactly once is after the stream exists. It is
    # printed at all because `opencode export <id>` is how a finished phase gets
    # re-read, and the id is otherwise buried in the JSONL.
    session=$(head -n 1 "$stream_file" 2>/dev/null | jq -r '.sessionID // empty')
    [ -n "$session" ] && printf 'session %s  agent=opencode  tier=%s  model=%s\n' \
      "$session" "$tier" "$model_shown"
    exit "$status"
    ;;
  *)
    printf 'Unsupported agent %s in %s (expected codex, claude or opencode)\n' \
      "${agent:-<empty>}" "$config_file" >&2
    exit 2
    ;;
esac
