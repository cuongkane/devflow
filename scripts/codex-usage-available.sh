#!/usr/bin/env bash
# Compatibility entry point for queue gates. Exhaustion must fail the Dagu run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/select-agent.sh" "${1:-10}" >/dev/null
status=$?
[ "$status" -ne 75 ] || status=1
exit "$status"
