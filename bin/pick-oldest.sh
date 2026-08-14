#!/usr/bin/env sh
# Choose the next issue for one agent to work on.
#
#   pick-oldest.sh <repo> <queue-label> [<working-label>]
#
# Prints the issue number on stdout, or `none`. Everything else goes to stderr,
# because dagu captures this step's stdout into a variable and a stray log line
# would become the issue number.
#
# A gh failure exits non-zero rather than printing `none`: a silently green idle
# poll is indistinguishable from "nothing queued" and would hide broken auth for
# days.
set -eu

repo=$1
queue=$2
working=${3:-}

log() { echo "[pick $queue] $*" >&2; }

# Purely informational, but it is the fastest way to spot a run that died
# holding a working label -- the issue is invisible to every queue from then on.
if [ -n "$working" ]; then
  stuck=$(gh issue list --repo "$repo" --label "$working" --state open --limit 100 \
    --json number,updatedAt \
    --jq '[.[] | "#\(.number) (last touched \(.updatedAt))"] | join(", ")') \
    || { log "ERROR: gh failed listing $working"; exit 1; }
  [ -z "$stuck" ] || log "in flight on $working: $stuck"
fi

# --limit matters: gh defaults to 30 newest-first, and the sort below is
# client-side, so a smaller page could hide the genuinely oldest issue.
queued=$(gh issue list --repo "$repo" --label "$queue" --state open --limit 200 \
  --json number,title) || { log "ERROR: gh failed listing $queue"; exit 1; }

if [ "$(printf '%s' "$queued" | jq 'length')" = "0" ]; then
  log "idle: no open issue labelled $queue"
  echo none
  exit 0
fi

log "queued: $(printf '%s' "$queued" | jq -r 'sort_by(.number) | [.[] | "#\(.number)"] | join(", ")')"
picked=$(printf '%s' "$queued" | jq -r 'sort_by(.number) | .[0].number')
log "picked #$picked (oldest by issue number)"
echo "$picked"
