#!/usr/bin/env sh
# Take the oldest issue waiting to be implemented, or the one named explicitly.
#
#   claim-ready-issue.sh <repo> [<issue>]
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
set -eu

repo=$1
issue=${2:-}
bin_dir=$(cd "$(dirname "$0")/.." && pwd)

if [ -z "$issue" ]; then
  issue=$("$bin_dir/pick-oldest.sh" "$repo" agent:ready-to-implement agent:implementing) || exit 1
fi

if [ "$issue" = none ]; then
  echo "[claim] no work: agent:ready-to-implement is empty" >&2
  jq -nc '{
    claimed: false,
    issue_number: "",
    message: "No issue is currently ready to implement. This poll completed without work."
  }'
elif "$bin_dir/relabel.sh" "$repo" "$issue" agent:ready-to-implement agent:implementing; then
  echo "[claim] #$issue: agent:ready-to-implement -> agent:implementing" >&2
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
