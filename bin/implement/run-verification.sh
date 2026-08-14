#!/usr/bin/env sh
# Run the target repository's real verification commands against the worktree.
#
#   run-verification.sh <run-dir> [<label>]
#
# These are SweatCharge's own commands, taken from its root Makefile and the two
# GitHub Actions workflows -- not a guessed subset:
#
#   make test-ci-migrations   missing-migration check, disposable stack
#   make test-ci              the full Django suite, disposable stack
#   make test-ci-down         tear the stack down, always
#   yarn lint / test:unit / build   in sweatcharge_fe, only if it changed
#
# Running them from shell rather than asking the agent to run them is the point.
# The skill states that a frontend build is mandatory whenever frontend source
# changes and must come from the final source state; as prose that is a promise
# the agent has to remember across a two-hour run. Here it is a conditional and a
# second edge in the graph -- the review phase is followed by another invocation
# of this same DAG, so "after the last fix" is structural.
#
# The exit status is the verdict. `verify.log` holds the output for the agent
# that gets called to fix a failure, since the DAG's own step log is not a file
# it can read.
set -eu

run_dir=$1
label=${2:-verify}
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
base=$("$here/state.sh" get "$run_dir" base)
log="$run_dir/$label.log"
verdict="$run_dir/$label.status"
: > "$log"

# The verdict goes in a file as well as the exit status, because the step that
# decides whether to spend a model on fixing a failure is a dagu precondition,
# and a precondition is a shell test -- it can read a file, but it cannot read
# the previous step's exit code.
echo fail > "$verdict"

failed=0

step() {
  name=$1
  shift
  printf '\n=== %s ===\n' "$name" | tee -a "$log"
  if (cd "$worktree" && "$@") >> "$log" 2>&1; then
    printf '%-24s PASS\n' "$name"
  else
    printf '%-24s FAIL\n' "$name"
    failed=1
  fi
}

printf 'worktree: %s\n' "$worktree"
printf 'log:      %s\n\n' "$log"

step "backend migrations" make test-ci-migrations
step "backend tests" make test-ci

# Teardown is best-effort and must run even when the suite failed, or the next
# run inherits a half-up stack.
(cd "$worktree" && make test-ci-down) >> "$log" 2>&1 || true

# Only build the frontend when the frontend actually changed. `git diff` against
# the merge base, not the working tree, so this sees the whole branch rather than
# whatever happens to be uncommitted right now.
if git -C "$worktree" diff --name-only "$base"...HEAD | grep -q '^sweatcharge_fe/'; then
  echo "frontend:                changed -- running lint, unit tests and production build"
  step "frontend lint" sh -c 'cd sweatcharge_fe && yarn lint'
  step "frontend unit tests" sh -c 'cd sweatcharge_fe && yarn test:unit'
  step "frontend build" sh -c 'cd sweatcharge_fe && yarn build'
else
  echo "frontend:                unchanged -- skipping lint, unit tests and build"
fi

if [ "$failed" -ne 0 ]; then
  echo
  echo "[$label] verification failed; see $log" >&2
  tail -40 "$log" >&2
  exit 1
fi

echo pass > "$verdict"
echo
echo "[$label] all checks passed"
