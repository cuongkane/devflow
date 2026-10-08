#!/usr/bin/env bash
# Print the usable provider; agent.yaml is the preferred provider, never mutated.
# Exit 75: both quotas are low. Exit 1: availability could not be established.
set -uo pipefail
minimum=${1:-10}
case "$minimum" in
  ''|*[!0-9]*) printf '[usage] invalid minimum percentage: %s\n' "$minimum" >&2; exit 2 ;;
esac
[ "$minimum" -le 100 ] || { printf '[usage] minimum must be 0..100\n' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
agent=$(awk '/^[[:space:]]*agent:[[:space:]]*/ {print $2; exit}' "$here/../agent.yaml")
case "$agent" in
  claude) fallback=codex ;;
  codex) fallback=claude ;;
  opencode) printf '%s\n' "$agent"; exit 0 ;;
  *) printf '[usage] unsupported agent: %s\n' "$agent" >&2; exit 2 ;;
esac
"$here/check-$agent-usage.sh" "$minimum"
first_status=$?
if [ "$first_status" -eq 0 ]; then
  printf '%s\n' "$agent"
  exit 0
fi
"$here/check-$fallback-usage.sh" "$minimum"
second_status=$?
if [ "$second_status" -eq 0 ]; then
  printf '[usage] switching %s -> %s\n' "$agent" "$fallback" >&2
  printf '%s\n' "$fallback"
  exit 0
fi
if [ "$first_status" -eq 75 ] && [ "$second_status" -eq 75 ]; then
  printf '[usage] STOP: Claude and Codex both have less than %s%% of their five-hour quota remaining\n' "$minimum" >&2
  exit 75
fi
printf '[usage] STOP: no usable agent; could not verify Claude/Codex five-hour quota\n' >&2
exit 1
