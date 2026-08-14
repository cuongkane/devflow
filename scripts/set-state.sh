#!/usr/bin/env sh
# Force an issue into exactly one agent:* state.
#
#   set-state.sh <repo> <issue> <to-label>
#
# Unlike relabel.sh this is unguarded and authoritative: it strips every other
# agent:* label and adds the one given. Agents use it to report an outcome,
# where the destination is known and must win regardless of what the issue was
# carrying -- including a hand-edited label, or a leftover working label from a
# run that died. relabel.sh is for the opposite case, claiming a queue entry
# that another process may have taken first.
set -eu

repo=$1
issue=$2
to=$3

current=$(gh issue view "$issue" --repo "$repo" --json labels \
  --jq '[.labels[].name | select(startswith("agent:"))] | join(",")')

remove=$(printf '%s' "$current" | tr ',' '\n' | grep -vx "$to" | paste -sd, - || true)

if [ -n "$remove" ]; then
  gh issue edit "$issue" --repo "$repo" --remove-label "$remove" --add-label "$to" >/dev/null
else
  gh issue edit "$issue" --repo "$repo" --add-label "$to" >/dev/null
fi

echo "[set-state] #$issue: ${current:-none} -> $to" >&2
