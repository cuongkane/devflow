#!/usr/bin/env sh
# Move an issue between agent:* states, but only from the state it is expected
# to be in.
#
#   relabel.sh <repo> <issue> <from-label> <to-label>
#
# The label IS the lock in this system: an agent claims an issue by swapping the
# queue label for its own working label before doing any work. Every other
# poller queries a different label, so it cannot see a claimed issue.
#
# The guard below is a check-then-act, not a compare-and-swap -- the GitHub API
# offers no conditional label write. Two processes reading `from` at the same
# instant could both proceed. That window is closed in practice because only one
# poller ever queries a given label, and each poller DAG sets
# `overlap_policy: skip`, so it never runs concurrently with itself. The guard's
# real job is catching the cases that do happen: a human relabelling by hand
# mid-poll, or a stale dispatch arriving after the state already moved on.
#
# Exit 10 means "not in the expected state" -- the caller should treat that as
# "someone else has it", not as an error.
set -eu

repo=$1
issue=$2
from=$3
to=$4

labels=$(gh issue view "$issue" --repo "$repo" --json labels --jq '.labels[].name')

if ! printf '%s\n' "$labels" | grep -qx "$from"; then
  echo "[relabel] #$issue is not '$from' (now: $(printf '%s' "$labels" | tr '\n' ' ')); leaving it alone" >&2
  exit 10
fi

gh issue edit "$issue" --repo "$repo" --remove-label "$from" --add-label "$to" >/dev/null
echo "[relabel] #$issue: $from -> $to" >&2
