#!/usr/bin/env bash
# Run one headless Claude Code agent and stream a readable view to stdout.
#
#   run-claude.sh <prompt-file> <budget-usd> <stream-jsonl>
#
# Two things make the run visible in the dagu UI, and both are required.
#
# `--output-format json` emits a single blob only after the agent finishes, so
# the log stays empty for the whole run; and redirecting to a file sends even
# that somewhere dagu never reads. stream-json emits one JSON event per line as
# it happens, tee keeps the raw events on disk for debugging, and jq renders a
# readable view on stdout -- which is the pane dagu shows.
#
# stderr is deliberately NOT merged in: claude writes warnings there, and a
# non-JSON line reaching jq would abort the stream. dagu shows the stderr log
# next to this one anyway.
#
# pipefail is set here rather than at DAG level because dagu rejects a
# step-level `shell` alongside `run`, and the pipeline's exit status must be
# claude's rather than jq's.
set -uo pipefail

prompt_file=$1
budget_usd=$2
stream_file=$3
here=$(cd "$(dirname "$0")" && pwd)

claude -p "$(cat "$prompt_file")" \
  --permission-mode bypassPermissions \
  --model opus \
  --output-format stream-json \
  --verbose \
  --max-budget-usd "$budget_usd" \
  | tee "$stream_file" \
  | jq -r --unbuffered -f "$here/render-claude-stream.jq"
