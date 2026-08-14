#!/usr/bin/env sh
# Fetch the issue, derive the run's identity, and build the brief the agent reads.
#
#   fetch-issue-brief.sh <repo> <issue> <run-dir> <workspace> <skill>
#
# This is where the run stops being anonymous. Previously the agent invented the
# slug, the branch name, the worktree path and the OpenSpec change name inside a
# single opaque step, so nothing outside that step could address any of them --
# which is precisely why the work could not be split into phases. All four are
# derived here, deterministically, from the issue number and title, and written
# to state.json for every later phase to read.
#
# Deriving them rather than asking for them also fixes a second problem: the
# branch now starts with the issue number, so the review-response DAG can find
# the worktree for an issue without guessing at a slug.
set -eu

repo=$1
issue=$2
run_dir=$3
workspace=$4
skill=$5

mkdir -p "$run_dir"
rm -f "$run_dir/result.json" "$run_dir/report.md"
date +%s > "$run_dir/started_at"

gh issue view "$issue" --repo "$repo" \
  --json number,title,body,comments > "$run_dir/issue.json"

title=$(jq -r '.title' "$run_dir/issue.json")
comments=$(jq -r '.comments | length' "$run_dir/issue.json")

# A short, stable, filesystem- and git-safe name. Truncated to 40 characters
# because it becomes a directory name and a branch name, and prefixed with the
# issue number so two issues with similar titles cannot collide.
full_slug=$(printf '%s' "$title" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
slug=$(printf '%s' "$full_slug" | cut -c1-40)
# Chop the trailing partial word when the title was longer than the budget --
# "within-2-ho" reads like a typo in a branch name, "within-2" does not.
[ "$full_slug" = "$slug" ] || slug=$(printf '%s' "$slug" | sed -e 's/-[^-]*$//')
slug=$(printf '%s' "$slug" | sed -e 's/-$//')
[ -n "$slug" ] || slug="issue"
name="$issue-$slug"

# The base the worktree branches from. Do not fetch first: the poller runs every
# ten minutes and a fetch here would race the human's own work in the checkout.
base=$(git -C "$workspace" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -z "$base" ]; then
  if git -C "$workspace" rev-parse --verify --quiet origin/master >/dev/null; then
    base=origin/master
  else
    base=master
  fi
fi

jq -n \
  --arg issue "$issue" --arg title "$title" --arg slug "$slug" \
  --arg branch "feature/$name" \
  --arg worktree "$workspace-worktrees/$name" \
  --arg change "$slug" --arg base "$base" \
  '{issue: $issue, title: $title, slug: $slug, branch: $branch,
    worktree: $worktree, change: $change, base: $base, phase: "fetch_issue_brief"}' \
  > "$run_dir/state.json"

# Stdout, not stderr: dagu shows the stdout log in the UI, and a run with none
# reads as "<No log output>". Whoever opens this run should be able to see what
# it picked up and where it will build it without opening the working files.
printf 'repo:     %s\n' "$repo"
printf 'issue:    #%s\n' "$issue"
printf 'title:    %s\n' "$title"
printf 'url:      https://github.com/%s/issues/%s\n' "$repo" "$issue"
printf 'comments: %s\n' "$comments"
printf 'skill:    %s\n' "$skill"
printf 'run_dir:  %s\n' "$run_dir"
printf 'branch:   feature/%s\n' "$name"
printf 'worktree: %s-worktrees/%s\n' "$workspace" "$name"
printf 'change:   %s\n' "$slug"
printf 'base:     %s\n' "$base"

# The clarifier's refined brief supersedes the raw issue body: it has already
# resolved the ambiguities and folded in the human's answers, and this pipeline
# is not allowed to ask anything. Fall back to the body only when the issue
# reached here without ever passing through clarification -- a hand-applied
# label, or `make implement`.
brief=$(jq -r '[.comments[] | select(.body | contains("<!-- agent:brief -->"))]
               | last | .body // empty' "$run_dir/issue.json")

# The issue body and every comment are untrusted text. They only ever reach the
# agent as a file, never interpolated into a shell command or a prompt string.
if [ -n "$brief" ]; then
  echo "brief:    clarifier's refined <!-- agent:brief --> comment"
  {
    jq -r '"# Issue #\(.number): \(.title)"' "$run_dir/issue.json"
    printf '\n\n'
    printf '%s\n' "$brief"
  } > "$run_dir/brief.md"
else
  echo "brief:    WARNING: no <!-- agent:brief --> comment; using the raw issue body"
  jq -r '"# Issue #\(.number): \(.title)\n\n\(.body // "(no description)")"' \
    "$run_dir/issue.json" > "$run_dir/brief.md"
fi
