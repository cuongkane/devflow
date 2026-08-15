#!/usr/bin/env sh
# Report the run's outcome on the issue, then make certain the issue was not left
# pinned to the working label.
#
#   report-and-recover.sh <repo> <run-dir> <issue> <run-id> <log-file>
#
# The recovery half runs whatever the reporting half did, which is the entire
# point of it: report-outcome.sh handles every outcome it can see, and this
# covers the one it cannot -- itself failing -- which would otherwise leave the
# issue on agent:implementing, where no poller including the one that claimed it
# will ever look again.
#
# As two steps, that guarantee was `continue_on: failure` on the reporting step.
# It is now the `|| true` below, and it has the same reach: neither form survives
# this process being killed outright, and an issue stranded that way stays on
# agent:implementing until a human moves it.
#
# The issue number is an argument rather than a state.json read, because the
# recovery half has to work in exactly the case where the run directory is the
# thing that went wrong.
#
# Exit status: non-zero if either half saw a run that did not complete, so the
# run shows red in the UI rather than green with a bad comment on the issue.
set -eu

repo=$1
run_dir=$2
issue=$3
run_id=$4
log_file=$5

here=$(cd "$(dirname "$0")" && pwd)

report=0
"$here/report-outcome.sh" "$repo" "$run_dir" "$run_id" "$log_file" || report=$?

recover=0
"$here/recover-stranded-label.sh" "$repo" "$issue" "$run_id" "$log_file" || recover=$?

# The reporting half's verdict is the more specific of the two -- it names the
# phase the run stopped in -- so it wins when both are non-zero.
[ "$report" -eq 0 ] || exit "$report"
exit "$recover"
