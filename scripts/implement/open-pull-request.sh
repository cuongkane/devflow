#!/usr/bin/env sh
# Commit what the run produced, push the branch, and open the pull request.
#
#   open-pull-request.sh <repo> <run-dir>
#
# Pushing and opening a PR are exact operations with a real blast radius, so they
# are shell rather than agent work. The agent's contribution to this phase is the
# prose in `pr-body.md`, written by the phase before this one; everything that
# decides *where* the code goes is decided here.
#
# The remote is verified before every push. The pipeline runs with the human's
# own credentials and unrestricted shell, so the one guarantee worth enforcing
# mechanically is that the destination is the repository the operator configured.
set -eu

repo=$1
run_dir=$2
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
branch=$("$here/state.sh" get "$run_dir" branch)
base=$("$here/state.sh" get "$run_dir" base)
issue=$("$here/state.sh" get "$run_dir" issue)
title=$("$here/state.sh" get "$run_dir" title)
body="$run_dir/pr-body.md"

cd "$worktree"

# Verify the destination before anything is published. `$repo` is the operator's
# own configuration; `origin` is whatever the checkout happens to carry.
origin=$(git remote get-url origin)
case "$origin" in
  *"$repo"*) : ;;
  *)
    echo "[deliver] origin is '$origin', which is not $repo -- refusing to push" >&2
    exit 1
    ;;
esac

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "$title" -m "Closes #$issue"
  echo "[deliver] committed the remaining working-tree changes"
fi

# The base ref is a remote-tracking name like origin/master; the pull request
# needs the branch name on its own.
base_branch=${base#origin/}

if [ -z "$(git log --oneline "$base".."$branch")" ]; then
  echo "[deliver] $branch has no commits over $base -- there is nothing to open a pull request for" >&2
  exit 1
fi

git push -u origin "$branch"

[ -s "$body" ] || {
  echo "[deliver] $body is missing or empty; refusing to open a pull request with no description" >&2
  exit 1
}

# `Closes #N` must be present or merging the PR will not close the issue, and the
# delivery poller will keep re-inspecting it forever.
grep -q "Closes #$issue" "$body" || printf '\nCloses #%s\n' "$issue" >> "$body"

url=$(gh pr create --repo "$repo" --base "$base_branch" --head "$branch" \
  --title "$title" --body-file "$body")

# Take the URL from GitHub's own output and never construct one: the number in it
# is what the review-response DAG follows, and a predicted number strands the issue.
"$here/state.sh" set "$run_dir" pr_url "$url"

printf 'branch:   %s\n' "$branch"
printf 'base:     %s\n' "$base_branch"
printf 'pull_request: %s\n' "$url"
