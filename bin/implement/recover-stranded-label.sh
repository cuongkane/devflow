#!/usr/bin/env sh
# Last resort: never leave an issue pinned to the working label.
#
#   recover-stranded-label.sh <repo> <issue> <run-id> <log-file>
#
# The report step handles every outcome it can see. This step covers what it
# cannot: the report step itself dying, or the worker vanishing before it ran. An
# issue left on agent:implementing is invisible to every poller including the one
# that claimed it, so it would sit there untouched forever.
#
# It also exits non-zero when the run ended in a failure or a blocker, so the run
# shows red in the UI rather than green-with-a-bad-comment.
set -eu

repo=$1
issue=$2
run_id=$3
log_file=$4
bin_dir=$(cd "$(dirname "$0")/.." && pwd)

labels=$(gh issue view "$issue" --repo "$repo" --json labels --jq '.labels[].name')

if printf '%s\n' "$labels" | grep -qx agent:implementing; then
  "$bin_dir/set-state.sh" "$repo" "$issue" agent:failed
  gh issue comment "$issue" --repo "$repo" \
    --body "Implementation run \`$run_id\` failed before reporting. Log: $log_file"
  exit 1
fi

if printf '%s\n' "$labels" | grep -Eq '^agent:(failed|revising)$'; then
  exit 1
fi
