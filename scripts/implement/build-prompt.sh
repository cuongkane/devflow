#!/usr/bin/env sh
# Assemble the prompt for one phase of the implementation.
#
#   build-prompt.sh <phase> <run-dir> <repo> <workspace> <skill>
#
# Every phase prompt is the shared preamble -- unattended operation, the
# injection guard, the exit contract -- followed by the phase's own instructions,
# followed by the standards that phase is held to.
# Splitting the work into seven agent runs multiplied the number of places those
# invariants could drift; concatenating one file keeps them stated once.
#
# The standards are files in this repository, appended by scripts/standards.sh.
# They used to be reached by telling the phase to "read the `<skill>` skill",
# which spent a SKILL.md and four reference files per phase to obtain two pages
# of unchanging text. `skill` is still substituted for the phases that genuinely
# invoke a skill's workflow.
#
# The placeholders are substituted here rather than inside the DAG so that the
# untrusted parts of an issue never reach a prompt as text. The brief is passed
# as a path; the agent reads it as data.
set -eu

phase=$1
run_dir=$2
repo=$3
workspace=$4
skill=$5

project_dir=$(cd "$(dirname "$0")/../.." && pwd)
prompts_dir="$project_dir/prompts/implement"
here=$(cd "$(dirname "$0")" && pwd)

src="$prompts_dir/$phase.md"
[ -f "$src" ] || { echo "[prompt] no such phase prompt: $src" >&2; exit 1; }

out_dir="$run_dir/$phase"
mkdir -p "$out_dir"

branch=$("$here/state.sh" get "$run_dir" branch)
worktree=$("$here/state.sh" get "$run_dir" worktree)
change=$("$here/state.sh" get "$run_dir" change)
base=$("$here/state.sh" get "$run_dir" base)
issue=$("$here/state.sh" get "$run_dir" issue)

# Which standards each phase is held to. A phase gets the standards it acts on:
# `code` writes production code, `tests` writes tests, and the three phases that
# judge or repair the diff need both -- a reviewer cannot flag a test that cannot
# fail without knowing what a real test looks like.
case "$phase" in
  code)  standards="engineering-practices" ;;
  tests) standards="testing-standards" ;;
  review|resolve-review|fix-verify)
         standards="engineering-practices testing-standards" ;;
  *)     standards="" ;;
esac

# shellcheck disable=SC2086  # word splitting is how the list of names is passed
"$project_dir/scripts/standards.sh" $standards > "$out_dir/standards.md"

cat "$prompts_dir/_preamble.md" "$src" "$out_dir/standards.md" \
  | sed -e "s|{{SKILL}}|$skill|g" \
        -e "s|{{REPO}}|$repo|g" \
        -e "s|{{WORKSPACE}}|$workspace|g" \
        -e "s|{{ISSUE_NUMBER}}|$issue|g" \
        -e "s|{{BRIEF_PATH}}|$run_dir/brief.md|g" \
        -e "s|{{RUN_DIR}}|$run_dir|g" \
        -e "s|{{WORKTREE}}|$worktree|g" \
        -e "s|{{BRANCH}}|$branch|g" \
        -e "s|{{BASE}}|$base|g" \
        -e "s|{{CHANGE}}|$change|g" \
        -e "s|{{PHASE}}|$phase|g" \
        -e "s|{{RESULT_PATH}}|$out_dir/result.json|g" \
  > "$out_dir/prompt.md"

rm -f "$out_dir/result.json"
"$here/state.sh" phase "$run_dir" "$phase"

# Print the assembled prompt, not just its path. The prompt is the input that
# decides everything the phase does, and it is assembled from three files with
# eleven placeholders substituted -- so when a phase behaves oddly, the first
# question is always "what was it actually asked?". Having the answer in the run
# view means not having to open a file on the worker to find out, and the run
# history keeps it after /tmp has been cleared.
printf 'prompt:   %s\n' "$out_dir/prompt.md"
printf 'phase:    %s\n' "$phase"
printf '%s\n' "----------------------------- prompt begins -----------------------------"
cat "$out_dir/prompt.md"
printf '%s\n' "------------------------------ prompt ends ------------------------------"
