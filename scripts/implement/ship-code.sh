#!/usr/bin/env sh
# Write the pull request description, then commit, push and open the pull request.
#
#   ship-code.sh <repo> <run-dir> <workspace> <skill> [<tier>] [<budget-usd>]
#
# One step: the description exists only to be the body of the pull request opened
# immediately after it, and neither half has any use on its own. What stays split
# is the kind of work -- the agent writes the prose, shell decides where the code
# actually goes -- which is a division inside this script rather than in the graph.
#
# A missing or empty pr-body.md is open-pull-request.sh's own precondition, so a
# description phase that finished but produced nothing stops the push there,
# where the check already lives, rather than being re-checked here.
#
# Exit status: the phase contract -- 0 done, 20 blocked, 1 failed.
set -eu

repo=$1
run_dir=$2
workspace=$3
skill=$4
tier=${5:-fast}
budget=${6:-1}

here=$(cd "$(dirname "$0")" && pwd)

# `blocked` has to survive as 20 all the way up to the DAG, and nothing should be
# pushed on the strength of a phase that did not finish.
status=0
"$here/run-phase.sh" pr-body "$run_dir" "$repo" "$workspace" "$skill" \
  "$tier" "$budget" || status=$?

if [ "$status" -ne 0 ]; then
  echo "[ship] the pr-body phase did not finish; not pushing" >&2
  exit "$status"
fi

exec "$here/open-pull-request.sh" "$repo" "$run_dir"
