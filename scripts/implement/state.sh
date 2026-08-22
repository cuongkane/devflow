#!/usr/bin/env sh
# Read and write the run's shared state file.
#
#   state.sh get <run-dir> <field>
#   state.sh get-or <run-dir> <field> <default>
#   state.sh set <run-dir> <field> <value>
#   state.sh phase <run-dir> <phase-name>
#
# `<run-dir>/state.json` is the whole handoff between phases. Each phase of the
# implementation runs as a separate DAG in a separate one-shot agent process
# with no memory of the last one, so everything a later phase needs to address
# -- the branch, the worktree path, the OpenSpec change name -- is computed once
# by fetch-issue-brief.sh and read back from here.
#
# The `phase` verb is what makes a killed run diagnosable. Every phase stamps its
# own name on entry, so when the worker dies mid-run the report step can say
# which phase it died in instead of reporting an undifferentiated failure.
set -eu

verb=$1
run_dir=$2
file="$run_dir/state.json"

case "$verb" in
  get)
    jq -er --arg f "$3" '.[$f]' "$file"
    ;;
  get-or)
    # For a field that a later change introduced. `get` is deliberately strict --
    # a missing branch or worktree is a bug and must stop the phase before it
    # writes to the wrong tree -- so an optional field asks for this instead and
    # names its own default. `size` is the case: a run directory left behind by
    # an earlier version of this pipeline does not have one, and neither does a
    # `make phase` re-run against such a directory.
    jq -r --arg f "$3" --arg d "$4" \
      'if (.[$f] // "") == "" then $d else .[$f] end' "$file" 2>/dev/null \
      || printf '%s\n' "$4"
    ;;
  set|phase)
    [ "$verb" = phase ] && field=phase || field=$3
    [ "$verb" = phase ] && value=$3 || value=$4

    # Write through a temp file: a phase that dies mid-write would otherwise
    # leave truncated JSON, and every later phase reads this file first.
    tmp="$file.tmp.$$"
    jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$file" > "$tmp"
    mv "$tmp" "$file"
    # `|| true` matters: a bare failing test as the last command of the branch
    # would exit non-zero under `set -e` and fail the step for the `set` verb.
    [ "$verb" = phase ] && echo "[state] phase: $value" >&2 || true
    ;;
  *)
    echo "usage: state.sh get|get-or|set|phase <run-dir> ..." >&2
    exit 2
    ;;
esac
