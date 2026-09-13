#!/usr/bin/env sh
# Remove a completed OpenSpec change after its deltas have been synchronized.
#
#   remove-change.sh <run-dir>
#
# The proposal, design, tasks, and delta specs are working artifacts. Once the
# sync phase has merged their final meaning into the main specs, a retained copy
# would duplicate that specification in the pull request. Delete the active
# change so the OpenSpec diff contains only the synchronized main-spec changes.
set -eu

OPENSPEC_TELEMETRY=0
export OPENSPEC_TELEMETRY

run_dir=$1
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
change=$("$here/state.sh" get "$run_dir" change)

# State normally derives this from the issue slug. Reject anything that is not
# one directory name before using it as the target of a recursive deletion.
case "$change" in
  ''|.|..|*/*)
    echo "[remove-change] unsafe change name: '$change'" >&2
    exit 1
    ;;
esac

cd "$worktree"
change_dir="openspec/changes/$change"

[ -d "$change_dir" ] || {
  echo "[remove-change] active change directory not found: $change_dir" >&2
  exit 1
}

echo "=== validate the synchronized change ==="
openspec status --change "$change" || true
openspec validate "$change" --strict

echo
echo "=== remove temporary change artifacts ==="
rm -rf -- "$change_dir"

[ ! -e "$change_dir" ] || {
  echo "[remove-change] failed to remove $change_dir" >&2
  exit 1
}

# OpenSpec discovers active changes from this directory. Check its view as well
# as the filesystem so a malformed or partially removed change cannot ship.
if openspec list --json | jq -e --arg c "$change" \
  'any(.[]?; (.name // .id // .) == $c)' >/dev/null 2>&1; then
  echo "[remove-change] '$change' is still active after removal" >&2
  exit 1
fi

echo
echo "=== validate all main specs, strictly ==="
openspec validate --specs --strict --no-interactive

printf '\nchange:  %s\nremoved: %s\n' "$change" "$change_dir"
