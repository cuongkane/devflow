#!/usr/bin/env sh
# Write the branch diff to disk for the phases that judge it.
#
#   write-diff.sh <run-dir>
#
# The review phase used to obtain the diff itself, and it did not stop at the
# diff: reviewing issue #116 took 118 commands and 730 KB of output -- greps,
# `find`, whole source files, `git diff --unified=80` twice -- to produce 1.8 KB
# of comments. It was re-exploring the repository when its job is to read what
# changed against the base ref.
#
# So the diff is produced here, by shell, once per phase, and the prompt names
# the file. The agent still opens a source file when a hunk is not
# self-explanatory; what it no longer does is rediscover the change.
#
# Two files, because they answer different questions and the small one is often
# the whole answer:
#
#   <run-dir>/diff.stat  what changed, by file (~2 KB)
#   <run-dir>/diff.md    the diff itself
#
# `-U3`, not the `-U80` the review phase was reaching for: on the same branch
# that is 122 KB instead of 228 KB, and eighty lines of unchanged context around
# every hunk is most of a file quoted back at whoever reads it.
#
# Lockfiles and snapshots are excluded from `diff.md` but not from `diff.stat`.
# A `yarn.lock` churn is routinely hundreds of kilobytes of text that no reviewer
# reads line by line, and it is charged to every step of every phase that holds
# the diff. The stat still lists it, so a reviewer who needs to know it moved
# can see that it moved.
#
# Above a ceiling the diff stops being affordable at all -- it enters the context
# once and is then re-sent on every request for the rest of the phase -- so a
# large diff is condensed with `rtk diff`, which keeps the changed lines and
# drops the context. The file says which of the two it is, so the agent knows
# whether the context lines are missing or simply absent.
set -eu

run_dir=$1
here=$(cd "$(dirname "$0")" && pwd)

worktree=$("$here/state.sh" get "$run_dir" worktree)
base=$("$here/state.sh" get "$run_dir" base)

# 150 KB, about 37k tokens. Beyond that the diff alone dominates the phase.
ceiling=153600

git -C "$worktree" diff --stat "$base"...HEAD > "$run_dir/diff.stat"
git -C "$worktree" diff -U3 "$base"...HEAD -- . \
  ':(exclude)**/yarn.lock' \
  ':(exclude)**/package-lock.json' \
  ':(exclude)**/poetry.lock' \
  ':(exclude)**/*.snap' \
  > "$run_dir/diff.raw"

size=$(wc -c < "$run_dir/diff.raw" | tr -d ' ')

# One output block: the header, the fences and the destination are the same
# either way, and only the note and the body producer differ.
{
  printf '# Branch diff: `%s...HEAD`\n\n' "$base"
  if [ "$size" -le "$ceiling" ] || ! command -v rtk >/dev/null 2>&1; then
    form='full -U3'
    printf 'Full `git diff -U3`, three lines of context around every hunk.\n'
    printf 'Lockfiles and snapshots are excluded; `diff.stat` still lists them.\n\n'
    printf '```diff\n'
    cat "$run_dir/diff.raw"
  else
    form="rtk-condensed (raw was $size bytes)"
    printf 'The full diff is %s bytes, too large to hold for a whole phase, so\n' "$size"
    printf 'this is the condensed form: **changed lines only, no context lines**.\n'
    printf 'When a hunk needs its surroundings, open that file at that range --\n'
    printf 'that is a handful of targeted reads, not another copy of the diff.\n\n'
    printf '```\n'
    rtk diff - < "$run_dir/diff.raw"
  fi
  printf '```\n'
} > "$run_dir/diff.md"

# The raw diff is the input to the condensed form, so it is worth keeping when
# the two differ -- somebody diagnosing a review afterwards may want it. When
# they are the same bytes it is just a second copy, and deleting it also removes
# the temptation to name it in a prompt: an escape hatch back to the full diff,
# advertised inside the file whose whole purpose is to bound the full diff,
# would undo the ceiling in one command.
[ "$form" = 'full -U3' ] && rm -f "$run_dir/diff.raw" || true

printf 'diff:     %s -> %s (%s bytes)\n' \
  "$form" "$run_dir/diff.md" "$(wc -c < "$run_dir/diff.md" | tr -d ' ')"
printf 'stat:     %s\n' "$run_dir/diff.stat"
