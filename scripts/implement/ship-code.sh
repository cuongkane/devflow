#!/usr/bin/env sh
# Commit, push, and open the pull request -- no agent, no re-reading the diff.
#
#   ship-code.sh <repo> <run-dir>
#
# The pull request body used to be written by an agent phase that re-read the
# whole diff and the archived artifacts before writing prose, which made the
# cheapest phase in the pipeline one of the most expensive. Everything that body
# described is already on disk as shell-produced files, so it is assembled from
# those instead: the issue title as the summary, the OpenSpec change name, and
# the verification summary as the evidence of what passed.
#
# Nothing is checked or verified here -- the suite that passed ran against this
# exact tree in the previous step. `open-pull-request.sh` does the commit, push
# and `gh pr create`; this script only owns the prose the PR is opened with.
#
# Both flows ship through here. The body differs in one section: a major run names
# the OpenSpec change it archived, a minor run says that there is none and that
# nothing has reviewed the diff yet.
set -eu

repo=$1
run_dir=$2
here=$(cd "$(dirname "$0")" && pwd)

title=$("$here/state.sh" get "$run_dir" title)
issue=$("$here/state.sh" get "$run_dir" issue)
change=$("$here/state.sh" get "$run_dir" change)
size=$("$here/state.sh" get-or "$run_dir" size major)

body="$run_dir/pr-body.md"

{
  printf '## Summary\n\n%s\n' "$title"
  printf '\nCloses #%s\n' "$issue"

  # What the reviewer is looking at, and what has already looked at it. A minor
  # run has no change to name and -- more to the point -- no automated review
  # behind it, so the person opening this pull request is its first reviewer.
  # Saying so is not a disclaimer; it is the difference between a diff that gets
  # read and one that gets waved through because the pipeline "already reviewed
  # it".
  if [ "$size" = minor ]; then
    printf '\n## Process\n\n'
    printf 'Implemented through the **minor** pipeline: code, tests, verification, ship.\n'
    printf 'No OpenSpec change was written and the main specifications were not touched,\n'
    printf 'because the clarifier judged this a change whose requirements were already\n'
    printf 'settled. **There was no automated review** — this diff has not been read by\n'
    printf 'anything but the phase that wrote its tests.\n'
    printf '\nIf it turns out to need a specification, that is worth saying on the issue:\n'
    printf 'the clarifier sized it, and a wrong call there is the thing to correct.\n'
  else
    printf '\n## OpenSpec\n\nChange: `%s`\n' "$change"
  fi

  printf '\n## Verification\n\n'
  if [ -s "$run_dir/verify.summary.log" ]; then
    printf '```\n'
    cat "$run_dir/verify.summary.log"
    printf '```\n'
  else
    printf 'All checks passed.\n'
  fi
} > "$body"

exec "$here/open-pull-request.sh" "$repo" "$run_dir"
