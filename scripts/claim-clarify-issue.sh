#!/usr/bin/env sh
# Gate clarification before changing the queue label. Exit 75 is a healthy defer.
set -eu
repo=$1
issue=$2
scripts_dir=$(cd "$(dirname "$0")" && pwd)
if "$scripts_dir/codex-usage-available.sh" 10; then
  if "$scripts_dir/relabel.sh" "$repo" "$issue" agent:todo agent:clarifying; then
    echo yes
  else
    status=$?
    [ "$status" -eq 10 ] || exit "$status"
    echo no
  fi
else
  status=$?
  [ "$status" -eq 75 ] || exit "$status"
  echo '[claim] clarification deferred: less than 10% Codex quota remains; issue stays queued' >&2
  echo no
fi
