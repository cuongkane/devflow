#!/usr/bin/env sh
# Decide what the delivery poller should do about one issue under review.
#
#   triage-issue.sh <repo> <issue>
#
# Emits the scripts/pr-triage.jq decision object on stdout, with two extra actions
# this layer can determine on its own:
#
#   none     no issue was passed (the queue was empty)
#   orphan   the issue carries no <!-- agent:pr=N --> marker, so there is no
#            pull request to look at -- someone labelled it agent:reviewing by
#            hand, or the implementer's report comment was deleted
set -eu

repo=$1
issue=${2:-none}
here=$(cd "$(dirname "$0")" && pwd)

if [ "$issue" = "none" ]; then
  echo '{"action":"none","pr":null}'
  exit 0
fi

# `last` rather than `first`: if the issue went round the loop more than once,
# the newest marker is the live pull request.
pr=$(gh issue view "$issue" --repo "$repo" --json comments --jq '
  [ .comments[].body
    | select(test("<!-- agent:pr=[0-9]+ -->"))
    | capture("<!-- agent:pr=(?<n>[0-9]+) -->").n ]
  | last // empty')

if [ -z "$pr" ]; then
  echo '{"action":"orphan","pr":null}'
  exit 0
fi

"$here/pr-state.sh" "$repo" "$pr" | jq -f "$here/pr-triage.jq"
