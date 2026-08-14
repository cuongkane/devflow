#!/usr/bin/env sh
# Resolve the review's comments, then verify the result.
#
#   resolve-review-comments.sh <run-dir> <repo> <workspace> <skill>
#                              [<tier>] [<budget-usd>] [<verify-attempts>]
#
# The review phase now only reviews: it writes `<run-dir>/review-comments.md` and
# touches nothing else. This step is the other half -- act on that file, then let
# the target repository's own checks be the verdict on the result.
#
# Verification is part of this step rather than a step of its own because the two
# are not independent: fixes made here are unreviewed code, the skill requires the
# frontend production build to come from the *final* source state, and a review
# fix that broke something should be fixed rather than end the run red one step
# from the pull request. `verify-until-green.sh` already owns that loop.
#
# When the review found nothing, no model runs at all -- the file says `NONE`, and
# what is left is one clean pass of the suite.
#
# Exit status is the same contract as every other step: 0 done, 20 blocked and a
# human is needed, 1 failed.
set -eu

run_dir=$1
repo=$2
workspace=$3
skill=$4
tier=${5:-deep}
budget=${6:-3}
attempts=${7:-2}

here=$(cd "$(dirname "$0")" && pwd)
comments="$run_dir/review-comments.md"

if [ ! -s "$comments" ]; then
  # The review phase reported `done` -- check-phase-result.sh already enforced
  # that -- but left no file. Treat it as a defect rather than as "nothing to do":
  # silently skipping the resolution is how an unreviewed diff reaches a pull
  # request looking reviewed.
  echo "[resolve-review] the review phase left no $comments" >&2
  exit 1
fi

if [ "$(head -n 1 "$comments" | tr -d '[:space:]')" = "NONE" ]; then
  printf '[resolve-review] the review found nothing to change; verifying only\n'
else
  printf '\n########## resolve-review: comments ##########\n'
  cat "$comments"
  printf '\n########## resolve-review: resolving ##########\n'

  # `set -e` would swallow the distinction between blocked and failed, and
  # `blocked` has to survive as 20 all the way up to the DAG.
  status=0
  "$here/run-phase.sh" resolve-review "$run_dir" "$repo" "$workspace" "$skill" \
    "$tier" "$budget" || status=$?
  [ "$status" -eq 0 ] || exit "$status"
fi

exec "$here/verify-until-green.sh" "$run_dir" "$repo" "$workspace" "$skill" \
  "$attempts" deep 2 final
