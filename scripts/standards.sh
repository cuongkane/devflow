#!/usr/bin/env sh
# Print the standards appendix for a prompt.
#
#   standards.sh <name> [<name> ...]
#
# `name` is a file in prompts/standards/ without its extension, e.g.
# `engineering-practices`. Output goes to stdout, ready to be appended to an
# assembled prompt.
#
# The standards used to live in the coding-agent skill, and every phase prompt
# opened with "read the `<skill>` skill and hold its standards". That cost each
# phase a SKILL.md plus its four reference files -- several thousand tokens and
# half a dozen tool calls -- to obtain two pages that never change from run to
# run. They now live in this repository and are pasted into the prompts that need
# them, so a phase starts already holding them.
set -eu

[ "$#" -gt 0 ] || exit 0

dir=$(cd "$(dirname "$0")/../prompts/standards" && pwd)

printf '\n---\n\n'
printf '%s\n\n' "# Standards for this phase"
for name in "$@"; do
  file="$dir/$name.md"
  [ -f "$file" ] || { echo "[standards] no such standard: $file" >&2; exit 1; }
  cat "$file"
  printf '\n'
done
