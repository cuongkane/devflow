#!/usr/bin/env sh
# Resolve the review's comments.
#
#   resolve-review-comments.sh <run-dir> <repo> <workspace> <skill>
#                              [<tier>] [<budget-usd>]
#
# The review phase only reviews: it writes `<run-dir>/review/review-comments.md`
# and touches nothing else. This step is the other half -- act on that file.
#
# That path is not spelled here twice by accident of history: it is the same
# `{{REVIEW_COMMENTS_PATH}}` that build-prompt.sh substitutes into both phases'
# prompts, so the writer and the reader cannot drift apart. They did once -- the
# prompt said `<run-dir>/review-comments.md`, the agent wrote it next to its own
# `result.json` in `<run-dir>/review/`, and this step failed a run whose review
# had produced six findings.
#
# It used to run the verification suite afterwards too, so that the frontend
# production build came from the final source state. It no longer does, because
# it was not the final source state: the spec sync that follows commits further
# changes, and the build the run shipped on had been taken before them. The
# verification loop is now its own step, immediately before the push, where
# "final" is structurally true rather than nearly true.
#
# When the review found nothing, no model runs at all -- the file says `NONE`, and
# this step is a no-op.
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

here=$(cd "$(dirname "$0")" && pwd)
comments="$run_dir/review/review-comments.md"

if [ ! -s "$comments" ]; then
  # The review phase reported `done` -- check-phase-result.sh already enforced
  # that -- but left no file. Treat it as a defect rather than as "nothing to do":
  # silently skipping the resolution is how an unreviewed diff reaches a pull
  # request looking reviewed.
  echo "[resolve-review] the review phase left no $comments" >&2
  exit 1
fi

if [ "$(head -n 1 "$comments" | tr -d '[:space:]')" = "NONE" ]; then
  printf '[resolve-review] the review found nothing to change; nothing to do\n'
  exit 0
fi

printf '\n########## resolve-review: comments ##########\n'
cat "$comments"
printf '\n########## resolve-review: resolving ##########\n'

# `set -e` would swallow the distinction between blocked and failed, and
# `blocked` has to survive as 20 all the way up to the DAG.
exec "$here/run-phase.sh" resolve-review "$run_dir" "$repo" "$workspace" "$skill" \
  "$tier" "$budget"
