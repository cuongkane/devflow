#!/usr/bin/env bash
# Check Codex five-hour quota. Exit 75 means below the requested threshold.
set -euo pipefail
minimum_remaining=${1:-10}
cleanup() {
  exec 3>&- || true
  exec 4<&- || true
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ -n "${runtime_dir:-}" ]; then
    rm -f "$runtime_dir/request" "$runtime_dir/response" "$runtime_dir/stderr"
    rmdir "$runtime_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# app-server is Codex's non-interactive protocol surface. Keep stdin open until
# the response arrives: closing it immediately makes the server stop before an
# authenticated rate-limit request has completed.
runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/dagu-codex-usage.XXXXXX")
mkfifo "$runtime_dir/request" "$runtime_dir/response"
codex app-server --stdio \
  <"$runtime_dir/request" >"$runtime_dir/response" 2>"$runtime_dir/stderr" &
server_pid=$!
exec 3>"$runtime_dir/request"
exec 4<"$runtime_dir/response"

printf '%s\n' \
  '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"dagu-usage-check","version":"1"}}}' \
  '{"method":"initialized"}' \
  '{"id":2,"method":"account/rateLimits/read","params":null}' \
  >&3

response=
deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$deadline" ] && IFS= read -r -t "$((deadline - SECONDS))" line <&4; do
  if printf '%s\n' "$line" | jq -e '.id == 2' >/dev/null 2>&1; then
    response=$line
    break
  fi
done

if [ -z "$response" ]; then
  printf '[usage] Codex did not return an account rate-limit snapshot\n' >&2
  sed 's/^/[usage codex] /' "$runtime_dir/stderr" >&2
  exit 1
fi
if ! printf '%s\n' "$response" | jq -e '(.result.rateLimitsByLimitId.codex // .result.rateLimits) != null' >/dev/null 2>&1; then
  message=$(printf '%s\n' "$response" | jq -r '.error.message // "unknown app-server error"' 2>/dev/null)
  printf '[usage] could not read Codex rate limits: %s\n' "$message" >&2
  sed 's/^/[usage codex] /' "$runtime_dir/stderr" >&2
  exit 1
fi

remaining=$(printf '%s\n' "$response" | jq -er '
  (.result.rateLimitsByLimitId.codex // .result.rateLimits)
  | [.primary, .secondary
     | select(.windowDurationMins == 300)
     | .usedPercent | select(type == "number" and . >= 0 and . <= 100)
     | 100 - .]
  | select(length > 0) | min
') || {
  printf '[usage] Codex returned no valid five-hour quota window\n' >&2
  exit 1
}
printf '[usage] Codex five-hour window: %s%% remaining\n' "$remaining" >&2
awk -v remaining="$remaining" -v minimum="$minimum_remaining" \
  'BEGIN { exit !(remaining >= minimum) }' || exit 75
