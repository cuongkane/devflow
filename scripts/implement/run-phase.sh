#!/usr/bin/env sh
# Run one agent phase of the implementation, end to end.
#
#   run-phase.sh <phase> <run-dir> <repo> <workspace> <skill> <tier> <budget-usd> [session]
#
# Build the prompt, run the agent at the requested model tier, then enforce the
# phase's exit contract. Three things that always happen together, so the DAG
# spends one line per phase instead of nine and the phases stay visibly uniform.
#
# The optional trailing `session` is an agent session id to continue instead of
# starting fresh. The fix loop uses it to keep one session across attempts, so a
# re-run does not pay to re-read the diff and standards it already holds.
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
continue_session=${8:-}
here=$(cd "$(dirname "$0")" && pwd)
project_dir=$(cd "$here/../.." && pwd)

"$here/build-prompt.sh" "$phase" "$run_dir" "$repo" "$workspace" "$skill"

# Wall clock around the agent alone, not around prompt assembly or the exit
# check. summarize-run.sh reads these two files to report how long each phase
# actually spent with a model, which is the number worth putting next to that
# phase's token count. A phase that is killed leaves `started_at` without
# `ended_at`, and the report says so rather than showing a blank.
date +%s > "$run_dir/$phase/started_at"

"$project_dir/run-agent.sh" \
  "$run_dir/$phase/prompt.md" \
  "$budget" \
  "$run_dir/$phase/agent-stream.jsonl" \
  "$tier" \
  "$continue_session" || echo "[$phase] agent exited non-zero; judging it by its result.json" >&2

date +%s > "$run_dir/$phase/ended_at"
printf 'tier:     %s\nbudget:   $%s\n' "$tier" "$budget" > "$run_dir/$phase/plan"

"$here/check-phase-result.sh" "$run_dir" "$phase"
