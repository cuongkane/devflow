#!/usr/bin/env sh
# Create the isolated worktree every later phase builds in.
#
#   create-worktree.sh <workspace> <run-dir>
#
# The skill used to do this itself, as its first mutation. It moves here for two
# reasons. Creating a worktree is an exact, checkable operation that a language
# model can only make less reliable; and once the path is decided by shell rather
# than discovered from an agent's prose, every later phase can be handed it as a
# working directory instead of having to rediscover it.
#
# Re-running this is safe. If the worktree already holds the right branch the
# script accepts it and returns -- which is what lets a single phase be re-run on
# its own after a failure without discarding the work already done.
set -eu

workspace=$1
run_dir=$2
here=$(cd "$(dirname "$0")" && pwd)

branch=$("$here/state.sh" get "$run_dir" branch)
worktree=$("$here/state.sh" get "$run_dir" worktree)
base=$("$here/state.sh" get "$run_dir" base)

if [ -d "$worktree" ]; then
  actual=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  if [ "$actual" = "$branch" ]; then
    echo "[worktree] reusing $worktree (already on $branch)"
    exit 0
  fi
  echo "[worktree] $worktree exists but is on '${actual:-detached}', not '$branch'" >&2
  exit 1
fi

# The source checkout is very often dirty -- it is the human's own working copy.
# `worktree add` touches none of it, which is the entire reason this pipeline
# uses worktrees rather than branching in place. Never stash, reset or clean here.
mkdir -p "$(dirname "$worktree")"
git -C "$workspace" worktree add -b "$branch" "$worktree" "$base"

printf 'worktree: %s\n' "$worktree"
printf 'branch:   %s\n' "$branch"
printf 'base:     %s (%s)\n' "$base" "$(git -C "$worktree" rev-parse --short HEAD)"

# A worktree that starts dirty means the base was not clean, and every later
# diff -- the review phase reads `git diff base...HEAD` -- would be wrong.
if [ -n "$(git -C "$worktree" status --porcelain)" ]; then
  echo "[worktree] refusing to continue: the new worktree is not clean" >&2
  git -C "$worktree" status --short >&2
  exit 1
fi
echo "status:   clean"
