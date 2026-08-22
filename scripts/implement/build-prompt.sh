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
# as a path; the agent reads it as data. The same holds for the branch diff and
# the repository's conventions: shell produces the file, the prompt names the
# path, and the phase spends one read instead of a discovery.
#
# There are two flows, and three of the phases are shared between them. A minor
# run has no OpenSpec change, no exploration and no automated review, so the
# shared phases cannot be given the same instructions: `prompts/implement/*.md`
# is written for the major flow, and a minor run prefers
# `prompts/implement/minor/<phase>.md` when one exists. A phase with no minor
# variant -- `fix-verify` is the case -- gets the major prompt with `_minor.md`
# appended, which is a short correction rather than a rewrite. Patching every
# shared prompt with an addendum was the alternative, and it produced prompts
# that spent a page arguing with themselves about which files exist.
set -eu

phase=$1
run_dir=$2
repo=$3
workspace=$4
skill=$5

project_dir=$(cd "$(dirname "$0")/../.." && pwd)
prompts_dir="$project_dir/prompts/implement"
here=$(cd "$(dirname "$0")" && pwd)

out_dir="$run_dir/$phase"
mkdir -p "$out_dir"

# The review's findings file. It lives in the `review` phase directory next to
# that phase's `result.json`, not in the run directory -- one placeholder, so the
# phase that writes it and the phase that reads it cannot disagree about where it
# is. They did: the prompt named `<run-dir>/review-comments.md` while
# `result.json` was `<run-dir>/review/result.json`, the review agent collocated
# both in the phase directory, and the resolving step then found no file and
# failed a run whose review had in fact produced six findings.
review_comments="$run_dir/review/review-comments.md"

branch=$("$here/state.sh" get "$run_dir" branch)
worktree=$("$here/state.sh" get "$run_dir" worktree)
change=$("$here/state.sh" get "$run_dir" change)
base=$("$here/state.sh" get "$run_dir" base)
issue=$("$here/state.sh" get "$run_dir" issue)

# Which flow claimed this issue. `get-or`, not `get`: a run directory left by an
# earlier version of the pipeline has no such field, and `major` -- the full
# pipeline, and what the unqualified prompts are written for -- is the answer
# that is merely expensive rather than wrong.
size=$("$here/state.sh" get-or "$run_dir" size major)
[ "$size" = minor ] || size=major

# The prompt for this phase, and the correction appended when there is no
# purpose-written one for a minor run.
src="$prompts_dir/$phase.md"
addendum=""
if [ "$size" = minor ]; then
  if [ -f "$prompts_dir/minor/$phase.md" ]; then
    src="$prompts_dir/minor/$phase.md"
  else
    addendum="$prompts_dir/_minor.md"
  fi
fi
[ -f "$src" ] || { echo "[prompt] no such phase prompt: $src" >&2; exit 1; }

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

# The diff, handed to the phase rather than obtained by it, and regenerated here
# because every phase runs after something changed the branch.
#
# Every phase, not a list of the ones that obviously want it. A list was cheaper
# by one `git diff` and made the preamble false: it tells all nine phases the
# diff "is complete and current", so the phases left off the list were being
# pointed at a file that was either absent or left over from an earlier phase and
# silently stale. `fix-verify` was the worst of the two -- it runs after the code
# and test phases have committed, so the stale copy it would have read was
# missing exactly the changes it was called in to fix.
"$here/write-diff.sh" "$run_dir"

# shellcheck disable=SC2086  # $addendum is one optional path, empty when unused
cat "$prompts_dir/_preamble.md" "$src" $addendum "$out_dir/standards.md" \
  | sed -e "s|{{SKILL}}|$skill|g" \
        -e "s|{{REPO}}|$repo|g" \
        -e "s|{{WORKSPACE}}|$workspace|g" \
        -e "s|{{ISSUE_NUMBER}}|$issue|g" \
        -e "s|{{BRIEF_PATH}}|$run_dir/brief.md|g" \
        -e "s|{{RUN_DIR}}|$run_dir|g" \
        -e "s|{{REVIEW_COMMENTS_PATH}}|$review_comments|g" \
        -e "s|{{CONVENTIONS_PATH}}|$run_dir/conventions.md|g" \
        -e "s|{{DIFF_PATH}}|$run_dir/diff.md|g" \
        -e "s|{{DIFF_STAT_PATH}}|$run_dir/diff.stat|g" \
        -e "s|{{VERIFY_SUMMARY_PATH}}|$run_dir/verify.summary.log|g" \
        -e "s|{{VERIFY_TAIL_PATH}}|$run_dir/verify.tail.log|g" \
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
# eighteen placeholders substituted -- so when a phase behaves oddly, the first
# question is always "what was it actually asked?". Having the answer in the run
# view means not having to open a file on the worker to find out, and the run
# history keeps it after /tmp has been cleared.
printf 'prompt:   %s\n' "$out_dir/prompt.md"
printf 'phase:    %s\n' "$phase"
printf 'flow:     %s (%s)\n' "$size" "${src#"$prompts_dir/"}"
printf '%s\n' "----------------------------- prompt begins -----------------------------"
cat "$out_dir/prompt.md"
printf '%s\n' "------------------------------ prompt ends ------------------------------"
