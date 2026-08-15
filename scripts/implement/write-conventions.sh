#!/usr/bin/env sh
# Collect the target repository's own agent instructions into one file.
#
#   write-conventions.sh <workspace> <run-dir>
#
# Every phase was independently discovering and reading the same four files --
# the root `CLAUDE.md`, `AGENTS.md`, and the per-component ones -- and paying for
# the discovery as well as the content. In the run for issue #116 that cost 45 KB
# in `explore`, 29.5 KB in `code` and 27.6 KB in `tests`, each spread over two or
# three commands whose `wc -l` and `printf` framing was itself a large part of
# the output. The content is identical every time and never changes during a run.
#
# So it is concatenated once, here, into `<run-dir>/conventions.md`, and the
# preamble points every phase at that one path and forbids re-reading the
# originals. One file, one read, no discovery.
#
# The files are read from the workspace rather than the worktree because the
# worktree does not exist yet when this runs, and a branch does not change its
# own repository's conventions.
set -eu

workspace=$1
run_dir=$2
out="$run_dir/conventions.md"

mkdir -p "$run_dir"

{
  printf '# Repository conventions\n\n'
  printf 'Every tracked `CLAUDE.md` and `AGENTS.md` in this checkout, concatenated\n'
  printf 'at the start of the run. Root first, then the rest by path.\n'
} > "$out"

# Discovered, not listed. An earlier version named the six paths this repository
# happens to have and told the agent it was "the complete set -- there is nothing
# to go and find", while the preamble forbade it from looking. Those two claims
# are only both true if the list is right, and a list of files that announce
# themselves by name is the kind that goes quietly out of date: add a component,
# or point PROJECT_WORKSPACE somewhere else, and the pipeline hands every phase a
# file that is lying to it with the discovery path closed off.
#
# `git ls-files` rather than `find`: it is the same one line, it respects
# .gitignore, and it will not descend into node_modules.
found=0
for rel in $(git -C "$workspace" ls-files 'CLAUDE.md' 'AGENTS.md' \
                                          '*/CLAUDE.md' '*/AGENTS.md' \
             | sort -t/ -k1,1); do
  file="$workspace/$rel"
  [ -f "$file" ] || continue
  found=$((found + 1))
  {
    printf '\n\n---\n\n## %s\n\n' "$rel"
    cat "$file"
  } >> "$out"
done

# Nothing found means the concatenation is empty and every phase is about to be
# told the repository has no conventions. That is almost certainly a wrong
# workspace rather than a repository without a CLAUDE.md, and it is worth a loud
# line in the run view even though it is not fatal.
[ "$found" -gt 0 ] || echo "[conventions] WARNING: no CLAUDE.md or AGENTS.md in $workspace" >&2

printf 'conventions: %s file(s), %s bytes -> %s\n' \
  "$found" "$(wc -c < "$out" | tr -d ' ')" "$out"
