#!/usr/bin/env sh
# Archive the completed OpenSpec change and validate the main specs.
#
#   archive-change.sh <run-dir>
#
# Deliberately the CLI rather than the repository's `openspec-archive-change`
# skill: that skill prompts the operator to pick a change and to confirm
# warnings, which cannot work in an unattended run. `--yes` is the whole reason
# this is a shell step.
#
# `--skip-specs` is used, `--no-validate` is not. The sync phase already merged
# the delta specs with agent judgement (that is the entire point of the
# agent-driven sync step). The CLI's own spec merge is a second, purely
# mechanical pass over the same deltas, and it is not idempotent against an
# ADDED requirement that already exists: it aborts with "already exists"
# instead of treating it as a no-op. Re-running it after the agent has already
# applied the deltas turns a normal archive into a hard failure. Skipping it
# does not weaken verification -- `openspec validate --specs --strict` below is
# still the final consistency check over the merged result.
set -eu

run_dir=$1
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
change=$("$here/state.sh" get "$run_dir" change)

cd "$worktree"

echo "=== status ==="
openspec status --change "$change" || true

echo
echo "=== validate the change, strictly ==="
openspec validate "$change" --strict

echo
echo "=== archive ==="
openspec archive "$change" --yes --skip-specs

# The change must be gone from the active list afterwards. If it is still there
# the archive silently did nothing, and opening a pull request on top of an
# unarchived change is exactly the state this phase exists to prevent.
if openspec list --json | jq -e --arg c "$change" 'any(.[]?; (.name // .id // .) == $c)' >/dev/null 2>&1; then
  echo "[archive] '$change' is still active after archiving" >&2
  exit 1
fi

echo
echo "=== validate all main specs, strictly ==="
openspec validate --specs --strict --no-interactive

archived=$(find openspec/changes/archive -maxdepth 1 -type d -name "*$change" 2>/dev/null | head -1)
printf '\nchange:   %s\n' "$change"
printf 'archived: %s\n' "${archived:-<not found under openspec/changes/archive>}"
