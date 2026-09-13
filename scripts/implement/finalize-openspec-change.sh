#!/usr/bin/env sh
# Merge the change's delta specs into the main specs, then remove the temporary
# change artifacts.
#
#   finalize-openspec-change.sh <run-dir> <repo> <workspace> <skill>
#                               [<tier>] [<budget-usd>]
#
# One step, because neither half is useful without the other: syncing without
# cleanup leaves the change active on top of specs that already describe it,
# and removing it without syncing throws the deltas away. As two steps the split
# bought a line in the run view and an ordering that was never in question.
#
# What stays divided is the kind of work, inside this script rather than in the
# graph. Merging prose into existing specs is judgement, so it is an agent;
# removing the now-redundant proposal, design, tasks, and delta files is exact
# shell work. The final branch retains only the synchronized spec changes.
#
# Exit status: the phase contract -- 0 done, 20 blocked, 1 failed.
set -eu

run_dir=$1
repo=$2
workspace=$3
skill=$4
tier=${5:-fast}
budget=${6:-1}

here=$(cd "$(dirname "$0")" && pwd)

# Read the status rather than letting `set -e` propagate it: `blocked` has to
# survive as 20 all the way up to the DAG, and the run view should say which half
# stopped the run.
status=0
"$here/run-phase.sh" sync "$run_dir" "$repo" "$workspace" "$skill" \
  "$tier" "$budget" || status=$?

if [ "$status" -ne 0 ]; then
  echo "[finalize-openspec] the sync phase did not finish; not removing the change" >&2
  exit "$status"
fi

exec "$here/remove-change.sh" "$run_dir"
