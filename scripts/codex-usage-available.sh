#!/usr/bin/env bash
# Decide whether an AI-backed workflow may claim work.
#
#   codex-usage-available.sh [<minimum-remaining-percent>]
#
# Non-Codex agents always pass. For Codex, query the same account rate-limit
# snapshot used by the CLI and require the requested headroom in every reported
# rolling window. Exit 75 means "defer this poll without claiming work"; any
# other non-zero status means the quota could not be checked and should be
# surfaced as a workflow failure rather than risking a half-finished claim.
set -euo pipefail

minimum_remaining=${1:-10}
project_dir=$(cd "$(dirname "$0")/.." && pwd)
config_file="$project_dir/agent.yaml"
agent=$(awk '/^[[:space:]]*agent:[[:space:]]*/ {print $2; exit}' "$config_file")

if [ "$agent" != codex ]; then
  printf '[usage] agent=%s; Codex quota gate does not apply\n' "${agent:-<empty>}" >&2
  exit 0
fi

case "$minimum_remaining" in
  ''|*[!0-9]*)
    printf '[usage] invalid minimum remaining percentage: %s\n' "$minimum_remaining" >&2
    exit 2
    ;;
esac
if [ "$minimum_remaining" -gt 100 ]; then
  printf '[usage] minimum remaining percentage must be between 0 and 100\n' >&2
  exit 2
fi

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
while IFS= read -r -t 20 line <&4; do
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
if ! printf '%s\n' "$response" | jq -e '.result.rateLimits != null' >/dev/null 2>&1; then
  message=$(printf '%s\n' "$response" | jq -r '.error.message // "unknown app-server error"' 2>/dev/null)
  printf '[usage] could not read Codex rate limits: %s\n' "$message" >&2
  sed 's/^/[usage codex] /' "$runtime_dir/stderr" >&2
  exit 1
fi

windows=$(printf '%s\n' "$response" | jq -r '
  (.result.rateLimitsByLimitId.codex // .result.rateLimits) as $limit
  | [
      ($limit.primary
       | select(. != null)
       | ["primary", (100 - .usedPercent), .usedPercent,
          (.windowDurationMins // "unknown"), (.resetsAt // "unknown")]),
      ($limit.secondary
       | select(. != null)
       | ["secondary", (100 - .usedPercent), .usedPercent,
          (.windowDurationMins // "unknown"), (.resetsAt // "unknown")]),
      ($limit.individualLimit
       | select(. != null)
       | ["individual", .remainingPercent, (100 - .remainingPercent),
          "spend-control", (.resetsAt // "unknown")])
    ]
  | .[] | @tsv
') || {
  printf '[usage] Codex returned an unreadable rate-limit snapshot\n' >&2
  exit 1
}

if [ -z "$windows" ]; then
  printf '[usage] Codex returned no quota windows; refusing to claim work\n' >&2
  exit 1
fi

defer=no
while IFS=$'\t' read -r name remaining used duration resets_at; do
  printf '[usage] Codex %s window: %s%% remaining (%s%% used, duration=%s, resets_at=%s)\n' \
    "$name" "$remaining" "$used" "$duration" "$resets_at" >&2
  if [ "$remaining" -lt "$minimum_remaining" ]; then
    defer=yes
  fi
done <<< "$windows"

if [ "$defer" = yes ]; then
  printf '[usage] deferring workflow: Codex has less than %s%% remaining; work stays queued\n' \
    "$minimum_remaining" >&2
  exit 75
fi

printf '[usage] Codex has at least %s%% remaining in every quota window\n' \
  "$minimum_remaining" >&2
