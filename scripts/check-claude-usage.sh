#!/usr/bin/env bash
# Check the same OAuth usage endpoint as Claude Code /usage.
# Exit 75 means below threshold; other failures mean the quota is unknown.
set -euo pipefail
minimum_remaining=${1:-10}
project_dir=$(cd "$(dirname "$0")/.." && pwd)
token=${CLAUDE_CODE_OAUTH_TOKEN:-}
if [ -r "$project_dir/.secrets/claude-oauth-token" ]; then
  token=$(cat "$project_dir/.secrets/claude-oauth-token")
fi
if [ -z "$token" ]; then
  credentials="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  if [ -r "$credentials" ]; then
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$credentials")
  elif [ "$(uname -s)" = Darwin ]; then
    token=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
      | jq -r '.claudeAiOauth.accessToken // empty') || token=
  fi
fi
if [ -z "$token" ]; then
  printf '[usage] Claude OAuth credential unavailable; cannot check five-hour quota\n' >&2
  exit 1
fi
# Feed the authorization header through stdin so it never appears in argv.
version=$(claude --version | awk '{print $1}')
response=$(printf 'Authorization: Bearer %s\n' "$token" | curl \
  --silent --show-error --fail --connect-timeout 5 --max-time 20 \
  --header @- --header 'anthropic-beta: oauth-2025-04-20' \
  --user-agent "claude-code/$version" \
  https://api.anthropic.com/api/oauth/usage) || {
  printf '[usage] could not read Claude five-hour quota; check HTTP error above (403 may require user:profile scope)\n' >&2
  exit 1
}
remaining=$(printf '%s\n' "$response" | jq -er '
  .five_hour.utilization | select(type == "number" and . >= 0 and . <= 100)
  | 100 - .
') || {
  printf '[usage] Claude returned no valid five-hour quota window\n' >&2
  exit 1
}
printf '[usage] Claude five-hour window: %s%% remaining\n' "$remaining" >&2
awk -v remaining="$remaining" -v minimum="$minimum_remaining" \
  'BEGIN { exit !(remaining >= minimum) }' || exit 75
