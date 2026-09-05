#!/usr/bin/env sh
# Drop the regenerable build artifacts from a finished run's worktree.
#
#   reclaim-workspace.sh <workspace> <run-dir>
#
# Every implementation run installs `sweatcharge_fe/node_modules` into its own
# worktree, because a git worktree shares the repository but not ignored files
# and so starts without one. Nothing ever removed it. At 611MB per run and one
# worktree per issue, 142 finished runs had put 83.6GB of identical node_modules
# on the host -- against 29MB for all the actual source in those same worktrees.
# The dependencies were 95% of what the pipeline cost the disk, and 100% of it
# was reconstructible with a command the pipeline already runs.
#
# So this removes the artifacts and keeps the worktree. That asymmetry is the
# whole design, and it is deliberate:
#
#   * The worktree must survive. `create-worktree.sh` is idempotent so a failed
#     phase can be re-run against the work already done; reclaim-stranded.sh
#     tells the issue in writing that "any worktree the previous attempt created
#     is still on disk and will be reused"; and resolve-code-review.yaml answers
#     review comments in that same worktree days later. Removing it here would
#     break all three to reclaim the 29MB that is not the problem.
#
#   * The artifacts must not. `install-frontend-deps.sh` is idempotent by
#     construction and is already called both as its own DAG step and from
#     run-verification.sh -- its own comment names the case it was written for,
#     "a run directory whose worktree was cleaned in between". This script is
#     what makes that sentence true. A re-run reinstalls, and pays for it in a
#     shell step rather than out of an agent phase's budget and timeout, which
#     is the arrangement install-frontend-deps.sh exists to guarantee.
#
# The worktree that is finished with is removed elsewhere and on a different
# signal: `finish_merged` in resolve-code-review.yaml drops it once the pull
# request actually merges. Delivery, not the end of a run, is when a branch stops
# being worth keeping.
#
# Called from `handler_on.exit`, so it runs last and it runs on every outcome --
# success, failure, timeout, abort. That matters more than it sounds: a run that
# dies mid-phase is the one whose worktree lingers longest, so cleanup that only
# fired on success would miss precisely the worst cases.
#
# It never fails the run. By the time this executes the work is delivered or
# lost, and either way that verdict is already reported; turning a green run red
# over an unlinked directory would only teach the reader to distrust the colour.
set -u

workspace=$1
run_dir=$2

# An idle poll is the common case -- ten times an hour, no issue claimed, no run
# directory. It is not an error and must not look like one.
[ -d "$run_dir" ] || exit 0

here=$(cd "$(dirname "$0")" && pwd)

# Two flows reach this script and they record their worktree in different places,
# so it knows both -- each read from a file the flow has already written, rather
# than from an argument a caller could get wrong.
#
#   state.json  the implementation flow. fetch-issue-brief.sh computes the
#               worktree path up front and every phase reads it back from here.
#
#   triage.json the review flow, which has no state.json. It never chose a path:
#               it is answering comments on a branch that already exists, and
#               finds the worktree by asking git which one holds that branch.
worktree=""
if [ -f "$run_dir/state.json" ]; then
  worktree=$("$here/state.sh" get-or "$run_dir" worktree "")
fi

if [ -z "$worktree" ] && [ -f "$run_dir/triage.json" ]; then
  head_ref=$(jq -r '.head // empty' "$run_dir/triage.json" 2>/dev/null)
  if [ -n "$head_ref" ]; then
    worktree=$(git -C "$workspace" worktree list --porcelain 2>/dev/null \
      | awk -v ref="refs/heads/$head_ref" '
          /^worktree / { p = substr($0, 10) }
          $0 == "branch " ref { print p; exit }')
  fi
fi

if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
  echo "[reclaim] no worktree recorded for $run_dir -- nothing to reclaim"
  exit 0
fi

# Three guards before anything is unlinked. This script is the only thing in the
# pipeline that runs `rm -rf` on a path it read out of a file, so the path has to
# earn it: a corrupted state.json must not be able to point this at a home
# directory. Each guard is a separate refusal so a tripped one says which.
case "$worktree" in
  /*) ;;
  *) echo "[reclaim] refusing: '$worktree' is not an absolute path" >&2; exit 0 ;;
esac

# The human's own checkout is never a target. It is where they work, its
# node_modules is theirs, and nothing here has any business touching it.
if [ "${worktree%/}" = "${workspace%/}" ]; then
  echo "[reclaim] refusing: $worktree is the source checkout, not a run worktree" >&2
  exit 0
fi

# And it must actually be a linked worktree of this repository. `.git` is a file
# rather than a directory in a worktree, which is the cheapest true signature.
if [ ! -f "$worktree/.git" ]; then
  echo "[reclaim] refusing: $worktree is not a linked git worktree" >&2
  exit 0
fi

before=$(du -sk "$worktree" 2>/dev/null | awk '{print $1}')

# Regenerable, and rebuilt by a command the pipeline already runs. The list below
# is only a list of *candidates*: each one is put to `git check-ignore` and
# removed only if this repository actually ignores it.
#
# That check is the safety property, and it is deliberately mechanical rather
# than a promise made in a comment. Anything tracked is source. Anything
# untracked but not ignored may be work an agent wrote and has not committed
# yet -- losing that is exactly the failure this cleanup must not become. Asking
# git means the rule cannot drift out of sync with .gitignore the way a
# hand-maintained list silently would: add `dist` here speculatively and it stays
# inert until the day the repo actually ignores a `dist`.
#
# `-prune` so the walk stops at each match instead of descending into a
# node_modules with 40,000 files in it looking for more node_modules.
find "$worktree" -maxdepth 4 -type d \
  \( -name node_modules \
  -o -name .angular \
  -o -name www \
  -o -name dist \
  -o -name playwright-report \
  -o -name test-results \
  -o -name .pytest_cache \
  -o -name __pycache__ \
  \) -prune -print 2>/dev/null \
| while IFS= read -r candidate; do
    if git -C "$worktree" check-ignore -q "$candidate" 2>/dev/null; then
      rm -rf "$candidate" 2>/dev/null
    else
      printf 'skipped:   %s (not ignored by this repository)\n' "$candidate"
    fi
  done

after=$(du -sk "$worktree" 2>/dev/null | awk '{print $1}')

# Report in the same shape as the other deterministic steps: what, where, and
# how much. The number is the point -- it is the only place the pipeline ever
# states what a run cost the disk, and a run that suddenly reclaims nothing is
# how a broken install step will first show itself.
printf 'worktree:  %s\n' "$worktree"
if [ -n "${before:-}" ] && [ -n "${after:-}" ]; then
  printf 'reclaimed: %sMB (%sMB -> %sMB)\n' \
    "$(( (before - after) / 1024 ))" "$(( before / 1024 ))" "$(( after / 1024 ))"
fi
printf 'kept:      the worktree and its branch, for re-runs and review replies\n'
exit 0
