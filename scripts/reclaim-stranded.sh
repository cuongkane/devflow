#!/usr/bin/env sh
# Return issues stranded on a working label to their queue.
#
#   reclaim-stranded.sh <repo> <working-label> <queue-label> <max-age-minutes>
#
# An agent claims an issue by swapping its queue label for a working label, and
# the run's `handler_on.failure` is what puts the label back when the run dies.
# That handler runs on the worker -- so it cannot fire for the one failure that
# needs it most: the worker itself disappearing. The coordinator expires the
# lease, marks the run failed, and the issue stays pinned to a working label
# that no poller queries. It is then invisible forever.
#
# This closes that hole from the other side. Rather than trying to clean up at
# the moment of failure, each poller sweeps before it picks, so a stranded issue
# is recovered on the first tick after the worker comes back -- no matter how
# the previous run died.
#
# Age, not liveness, is the test. There is no reliable way to ask "is a run
# still executing for this issue?" from here, but there is a hard ceiling: each
# agent DAG sets `timeout_sec`, so an issue that has been untouched for
# comfortably longer than that ceiling cannot still be legitimately in flight.
# Call it with a margin over the DAG's timeout, never a value below it.
#
# `updatedAt` is the clock. It is set when the poller claims the issue, and
# every subsequent agent action -- comment, label edit -- pushes it forward. A
# genuinely running agent keeps it fresh; a stranded one leaves it frozen at the
# moment of the claim.
#
# Reclaiming uses relabel.sh, not set-state.sh: the guard means a race with an
# agent that just finished exits 10 and changes nothing, rather than yanking an
# issue out of the state that agent had legitimately moved it to.
set -eu

repo=$1
working=$2
queue=$3
max_age_min=$4

scripts_dir=$(cd "$(dirname "$0")" && pwd)

log() { echo "[reclaim $working] $*" >&2; }

cutoff=$(date -u -v-"${max_age_min}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
  || cutoff=$(date -u -d "${max_age_min} minutes ago" +%Y-%m-%dT%H:%M:%SZ)

# A gh failure must not be mistaken for "nothing stranded" -- that would make a
# broken token look like a healthy sweep for as long as it stays broken.
stranded=$(gh issue list --repo "$repo" --label "$working" --state open --limit 100 \
  --json number,updatedAt \
  --jq --arg cutoff "$cutoff" '[.[] | select(.updatedAt < $cutoff) | .number] | .[]') \
  || { log "ERROR: gh failed listing $working"; exit 1; }

[ -n "$stranded" ] || exit 0

for issue in $stranded; do
  log "#$issue has been $working since before $cutoff; returning it to $queue"

  # Comment first. If the relabel fails the issue keeps its working label and
  # will be swept again next tick, and a stray note is cheaper than a silent
  # state change nobody can trace.
  gh issue comment "$issue" --repo "$repo" --body \
"This issue was left on \`$working\` by a run that died without reporting -- most
likely the host worker stopped while the agent was mid-flight, which also
prevents that run's own failure handler from firing.

It has been returned to \`$queue\` and will be picked up on a following tick.
Any worktree the previous attempt created is still on disk and will be reused." \
    >/dev/null || log "WARNING: could not comment on #$issue"

  if ! ./"$(dirname "$0")"/relabel.sh "$repo" "$issue" "$working" "$queue" 2>/dev/null; then
    log "#$issue changed state underneath the sweep; leaving it alone"
  fi
done
