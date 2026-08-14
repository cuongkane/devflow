#!/bin/sh
set -eu

# GitHub CLI on macOS stores its token in Keychain. Dagu step subprocesses do
# not reliably retain the worker's GH_TOKEN, so materialize a Linux-local gh
# config when the container starts. This file lives only in the container.
if [ -z "${GH_TOKEN:-}" ]; then
  echo "worker: GH_TOKEN is missing; start with 'make up'" >&2
  exit 1
fi

token=$GH_TOKEN
unset GH_TOKEN GITHUB_TOKEN
mkdir -p /root/.config/gh
printf '%s\n' "$token" | gh auth login --hostname github.com --with-token
export GH_TOKEN=$token

exec "$@"
