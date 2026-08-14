#!/usr/bin/env sh
# Say on the issue that the pipeline has picked it up.
#
#   announce-start.sh <repo> <run-dir> <run-id>
#
# Implementation takes 30-90 minutes with nothing visible on the issue until the
# report step runs. Without this comment, a human reading their notifications has
# no way to tell the work is already under way and may start it by hand.
#
# It also publishes the branch and worktree names, which are now decided before
# any agent runs -- so someone who wants to watch the work can check out the
# branch while it is still being written.
set -eu

repo=$1
run_dir=$2
run_id=$3
here=$(cd "$(dirname "$0")" && pwd)

issue=$("$here/state.sh" get "$run_dir" issue)
branch=$("$here/state.sh" get "$run_dir" branch)

gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
🤖 Started implementing this issue.

Run \`$run_id\` is working on it now, on branch \`$branch\`. It runs as a
sequence of phases — explore, propose, code, verify, review, resolve, sync,
deliver — each
visible separately in the run view, so progress is observable while it works.

A pull request or a report will be posted here when it finishes. No action needed
in the meantime.
EOF
)"

printf 'announced: issue #%s is now being implemented on %s\n' "$issue" "$branch"
