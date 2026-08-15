#!/usr/bin/env bash
# Store the worker's Claude Code token where run-agent.sh looks for it.
#
#   scripts/set-agent-token.sh        # then paste the token at the prompt
#
# Run `claude setup-token` first, in a terminal of your own -- not through a
# Claude Code session, whose command output would carry the token into a
# transcript.
#
# The token is read with `read -rs`, so it never reaches the screen, the
# process table or shell history, and it is written to an absolute path derived
# from this script's own location: a relative path is how a token ends up in
# whichever directory the shell happened to be in.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
token_file="$project_dir/.secrets/claude-oauth-token"

printf 'Paste the token from `claude setup-token` (input stays hidden): '
read -rs token
printf '\n'

[ -n "$token" ] || { printf 'Nothing pasted; leaving %s alone.\n' "$token_file" >&2; exit 1; }

mkdir -p "$project_dir/.secrets"
chmod 700 "$project_dir/.secrets"

# umask before the redirect, not chmod after it: chmod leaves a window in which
# the token exists at the default mode, and this file is the one thing here that
# should never be world-readable for even an instant.
(umask 077 && printf '%s' "$token" > "$token_file")

printf 'Wrote %s bytes to %s\n' "$(wc -c < "$token_file" | tr -d ' ')" "$token_file"
printf 'The worker picks this up on its next phase; no rebuild or restart.\n'
