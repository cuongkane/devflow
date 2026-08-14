#!/usr/bin/env sh
# Run one agent phase of the implementation, end to end.
#
#   run-phase.sh <phase> <run-dir> <repo> <workspace> <skill> <tier> <budget-usd>
#
# Build the prompt, run the agent at the requested model tier, then enforce the
# phase's exit contract. Three things that always happen together, so the DAG
# spends one line per phase instead of nine and the phases stay visibly uniform.
#
# The exit status is the phase's verdict: 0 done, 20 blocked, 1 failed. The agent
# runner's own exit status is deliberately ignored -- what the agent left in
# result.json is more reliable than how its process happened to terminate, and a
# CLI that dies after writing a good result should not fail the phase.
set -eu

phase=$1
run_dir=$2
repo=$3
workspace=$4
skill=$5
tier=$6
budget=$7
here=$(cd "$(dirname "$0")" && pwd)
project_dir=$(cd "$here/../.." && pwd)

"$here/build-prompt.sh" "$phase" "$run_dir" "$repo" "$workspace" "$skill"

"$project_dir/run-agent.sh" \
  "$run_dir/$phase/prompt.md" \
  "$budget" \
  "$run_dir/$phase/agent-stream.jsonl" \
  "$tier" || echo "[$phase] agent exited non-zero; judging it by its result.json" >&2

"$here/check-phase-result.sh" "$run_dir" "$phase"
