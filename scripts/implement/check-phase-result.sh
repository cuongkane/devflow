#!/usr/bin/env sh
# Enforce one phase's exit contract.
#
#   check-phase-result.sh <run-dir> <phase>
#
# Every agent phase writes `<run-dir>/<phase>/result.json`:
#
#   {"status": "done",    "summary": "<one or two sentences>"}
#   {"status": "blocked", "question": "<the single blocking question>"}
#   {"status": "failed",  "error": "<what broke, and where it stopped>"}
#
# A phase that produced no file at all is the important case: it means the agent
# was killed, timed out, or ran out of budget. Under the old single-step design
# that was indistinguishable from any other failure. Here the missing file is
# attributed to a named phase, and the run's state.json already records that the
# phase had started -- so the report says where it died rather than that it died.
#
# Exit 0 = done, 20 = blocked, 1 = failed. `blocked` gets its own code because it
# is a legitimate outcome that routes the issue back to a human, not a defect.
set -eu

run_dir=$1
phase=$2
result="$run_dir/$phase/result.json"

if [ ! -s "$result" ]; then
  echo "[$phase] no result.json: the agent was killed, timed out, or exhausted its budget" >&2
  exit 1
fi

status=$(jq -r '.status // "failed"' "$result" 2>/dev/null || echo failed)

case "$status" in
  done)
    summary=$(jq -r '.summary // empty' "$result" 2>/dev/null || true)
    printf 'phase:    %s\n' "$phase"
    printf 'status:   done\n'
    [ -z "$summary" ] || printf 'summary:  %s\n' "$summary"
    ;;
  blocked)
    question=$(jq -r '.question // "(no question recorded)"' "$result")
    printf 'phase:    %s\n' "$phase"
    printf 'status:   blocked\n'
    printf 'question: %s\n' "$question"
    exit 20
    ;;
  *)
    error=$(jq -r '.error // "(no error recorded)"' "$result" 2>/dev/null || echo "(unreadable result.json)")
    echo "[$phase] failed: $error" >&2
    exit 1
    ;;
esac
