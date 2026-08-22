#!/usr/bin/env sh
# Take the oldest issue waiting on one implementation queue, or the one named.
#
#   claim-ready-issue.sh <repo> <queue-label> [<issue>]
#
# Emits one JSON object on stdout for the DAG to decode:
#
#   {"claimed": true|false, "issue_number": "42"|"", "message": "..."}
#
# `claimed: false` is the normal idle result, not an error -- this DAG runs every
# ten minutes and most ticks find nothing. Every step after this one is gated on
# the flag, so an idle poll costs one `gh` call and stops.
#
# The claim itself is relabel.sh's guarded swap. Losing the race is also
# `claimed: false`: another poller, or a human, moved the issue between the read
# and the write, and the next tick will pick up whatever is actually ready.
#
# The queue label is an argument because there are two implementation queues, one
# per flow: `agent:major-task:ready-to-implement` for a change that needs a
# specification and `agent:minor-task:ready-to-implement` for one that does not.
# The clarifier decides which, and the two DAGs poll one each. Keeping the queues
# disjoint is what lets them run as separate pollers at all -- both claim into the
# same `agent:implementing` working label, so a shared queue label would have them
# racing for the same issue on every tick.
set -eu

repo=$1
queue=$2
issue=${3:-}
scripts_dir=$(cd "$(dirname "$0")/.." && pwd)

if [ -z "$issue" ]; then
  issue=$("$scripts_dir/pick-oldest.sh" "$repo" "$queue" agent:implementing) || exit 1
fi

if [ "$issue" = none ]; then
  echo "[claim] no work: $queue is empty" >&2
  jq -nc --arg queue "$queue" '{
    claimed: false,
    issue_number: "",
    message: ("No issue is waiting on " + $queue + ". This poll completed without work.")
  }'
elif "$scripts_dir/relabel.sh" "$repo" "$issue" "$queue" agent:implementing; then
  echo "[claim] #$issue: $queue -> agent:implementing" >&2
  jq -nc --arg issue "$issue" '{
    claimed: true,
    issue_number: $issue,
    message: ("Claimed issue #" + $issue + " for implementation.")
  }'
else
  echo "[claim] #$issue: skipped because its state changed" >&2
  jq -nc --arg issue "$issue" '{
    claimed: false,
    issue_number: "",
    message: ("Issue #" + $issue + " was selected but could not be claimed because its state changed.")
  }'
fi
