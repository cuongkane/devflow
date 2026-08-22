#!/usr/bin/env sh
# Put node_modules in the worktree, in shell, before any agent needs it.
#
#   install-frontend-deps.sh <run-dir>
#
# A git worktree is a fresh checkout: it shares the repository but not ignored
# files, so `sweatcharge_fe/node_modules` does not exist in it no matter how
# complete the human's own checkout is. Nothing in this pipeline used to install
# it. `run-verification.sh` went straight to `yarn lint` / `test:unit` / `build`,
# and the phases that wanted a focused frontend test found nothing there either.
#
# So the first phase that needed the frontend improvised the install itself,
# inside its own budget and timeout. On issue #158 that was the `tests` phase: it
# spent six minutes on `yarn install`, hit a cold cache, and reported `failed`
# without ever running the tests it had just written. That is the failure mode
# this script removes -- not by making the install cheaper, but by moving it out
# of an agent phase and into a step whose only job it is.
#
# Idempotent, and deliberately so: it is called once as its own DAG step and
# again from run-verification.sh, which covers `make verify` against a run
# directory whose worktree was cleaned in between. A worktree that already has
# node_modules costs one `test -f`.
#
# `--immutable` is CI semantics and is kept on purpose. As the DAG step this runs
# before any code exists, so the lockfile is exactly the base commit's and the
# flag can only pass. From run-verification.sh it can genuinely fail, and when it
# does it is reporting something real: package.json was changed without
# committing the updated yarn.lock. That is a defect to surface, not to paper
# over with a lockfile rewrite nobody reviewed.
set -eu

run_dir=$1
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
fe="$worktree/sweatcharge_fe"

if [ ! -f "$fe/package.json" ]; then
  printf 'frontend: %s has no package.json -- nothing to install\n' "$fe"
  exit 0
fi

# Yarn 4's node-modules linker writes this on a successful install. Its presence
# is the check rather than `test -d node_modules`, which is also true of a
# directory left half-written by an install that died.
if [ -f "$fe/node_modules/.yarn-state.yml" ]; then
  printf 'frontend: node_modules already installed in %s\n' "$fe"
  exit 0
fi

# One lock around the install, because the cache is one directory. sweatcharge_fe
# leaves `enableGlobalCache` at its default, so every worktree's install reads and
# writes `~/.yarn/berry/cache` -- and service.yaml allows four implementation runs
# at once, in this one container. Two cold installs fetching the same package
# concurrently is how yarn produces `YN0001: While persisting <cache entry>`.
#
# The wait is generous because the thing being serialised is genuinely slow on a
# cold cache, and a run that waits its turn is far cheaper than two runs
# corrupting a cache entry that then has to be found and deleted by hand.
lock=/tmp/dagu-agent/.yarn-cache.lock

printf 'frontend: installing dependencies in %s\n' "$fe"
printf 'lock:     %s\n' "$lock"
printf 'cache:    %s\n' "$(cd "$fe" && yarn config get cacheFolder 2>/dev/null || echo '<unknown>')"

start=$(date +%s)
flock -w 2400 "$lock" sh -c 'cd "$1" && yarn install --immutable' _ "$fe"
elapsed=$(( $(date +%s) - start ))

printf 'frontend: installed in %dm%02ds\n' "$((elapsed / 60))" "$((elapsed % 60))"
