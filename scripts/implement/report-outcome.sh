#!/usr/bin/env sh
# Post the run's outcome on the issue and move it to its next state.
#
#   report-outcome.sh <repo> <run-dir> <run-id> <log-file>
#
# This step is the reason the phases upstream write their outcomes to disk. It
# runs whether they succeeded or not, reads state.json to learn which phase the
# run reached, and reports that phase by name. Under the previous single-step
# design a killed run produced one undifferentiated "failed" with no indication
# of whether it had got as far as writing code; now the comment says exactly
# where it stopped and what survives on disk for the next attempt.
set -eu

repo=$1
run_dir=$2
run_id=$3
log_file=$4
here=$(cd "$(dirname "$0")" && pwd)
scripts_dir=$(cd "$here/.." && pwd)

issue=$("$here/state.sh" get "$run_dir" issue)
phase=$("$here/state.sh" get "$run_dir" phase)
worktree=$("$here/state.sh" get "$run_dir" worktree)
pr_url=$(jq -r '.pr_url // ""' "$run_dir/state.json")
body="$run_dir/report.md"

# Did any phase stop on a blocker? That outcome outranks a plain failure: it
# means clarification missed something material and a human has to answer, which
# is a different destination label and a different message.
blocked_phase=""
blocked_question=""
for result in "$run_dir"/*/result.json; do
  [ -f "$result" ] || continue
  if [ "$(jq -r '.status // ""' "$result" 2>/dev/null || echo "")" = blocked ]; then
    blocked_phase=$(basename "$(dirname "$result")")
    blocked_question=$(jq -r '.question // "(no question recorded)"' "$result")
    break
  fi
done

if [ -n "$pr_url" ]; then
  outcome=completed
elif [ -n "$blocked_phase" ]; then
  outcome=blocked
else
  outcome=failed
fi

case "$outcome" in
  completed)
    state="agent:reviewing"
    pr_number=${pr_url##*/}

    case "$pr_number" in
      ''|*[!0-9]*)
        echo "[report] pr_url is unusable ('$pr_url')" >&2
        outcome=failed
        ;;
      *)
        [ -s "$body" ] || {
          # The write-up phase is the last agent step, so it is the one most
          # likely to have been cut off by the budget. Its absence should not
          # turn a delivered pull request into a reported failure.
          printf 'Opened %s for this issue.\n' "$pr_url" > "$body"
          echo "[report] no agent-written report.md; posting a minimal one" >&2
        }
        # This marker is how the delivery poller finds the pull request. It is
        # written here from GitHub's own URL rather than by the agent -- the one
        # fact in this pipeline that must not be paraphrased.
        printf '\n<!-- agent:pr=%s -->\n' "$pr_number" >> "$body"
        ;;
    esac
    ;;
  blocked)
    state="agent:revising"
    {
      printf 'Implementation stopped during `%s` on a blocker that clarification did not cover.\n\n' \
        "$blocked_phase"
      printf '%s\n' "$blocked_question"
      cat <<'EOF'

---

Answer above, then relabel this issue `agent:todo` to re-run clarification.

<!-- agent:questions -->
EOF
    } > "$body"
    ;;
esac

if [ "$outcome" = failed ]; then
  state="agent:failed"

  reason=$(jq -r '.error // empty' "$run_dir/$phase/result.json" 2>/dev/null || true)
  [ -n "$reason" ] || reason="The agent wrote no result.json for this phase. It was most likely killed, timed out, or exhausted its budget."

  {
    printf 'Implementation run `%s` did not complete.\n\n' "$run_id"
    printf 'It stopped in the **%s** phase.\n\n' "$phase"
    printf '%s\n\n' "$reason"
    printf 'Phases that finished:\n\n'
    for result in "$run_dir"/*/result.json; do
      [ -f "$result" ] || continue
      printf -- '- `%s` — %s\n' \
        "$(basename "$(dirname "$result")")" \
        "$(jq -r '.status // "unknown"' "$result" 2>/dev/null || echo unreadable)"
    done
    printf '\nThe worktree is left in place so the next attempt can see how far this one got.\n\n'
    printf 'Worktree: `%s`\nWorking files: `%s`\n' "$worktree" "$run_dir"
  } > "$body"
fi

gh issue comment "$issue" --repo "$repo" --body-file "$body"
"$scripts_dir/set-state.sh" "$repo" "$issue" "$state"

started=$(cat "$run_dir/started_at" 2>/dev/null || date +%s)
elapsed=$(( $(date +%s) - started ))
printf 'result:      %s\n' "$outcome"
printf 'issue:       #%s\n' "$issue"
printf 'last_phase:  %s\n' "$phase"
printf 'transition:  agent:implementing -> %s\n' "$state"
printf 'elapsed:     %dm%02ds\n' "$((elapsed / 60))" "$((elapsed % 60))"
# `|| true` on both: under `set -e` a bare failing test would abort the step
# before the final verdict below ever runs.
[ "$outcome" = completed ] && printf 'pull_request: %s\n' "$pr_url" || true
[ "$outcome" = failed ] && printf 'log:         %s\n' "$log_file" || true

# Surface a non-completed outcome as a red run in the dagu UI.
test "$outcome" = completed
