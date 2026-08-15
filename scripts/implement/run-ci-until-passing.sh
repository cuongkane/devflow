#!/usr/bin/env sh
# Run the target repository's CI checks against the worktree, fixing what fails,
# until they pass.
#
#   run-ci-until-passing.sh <run-dir> <repo> <workspace> <skill>
#                           [<max-attempts>] [<tier>] [<budget-usd>] [<stage>]
#
# This used to be three DAG steps -- run, fix, rerun -- wired together with
# preconditions that read `verify.status` off disk, and it still only allowed a
# single fix. A second failure ended the run green-adjacent: the suite had failed,
# nothing was left to fix it, and the next step ran anyway.
#
# The loop belongs here instead. One step in the run view, one place that decides
# how many attempts are worth spending, and no ceiling built out of graph edges.
#
# What does NOT move into the agent is the verdict. `run-verification.sh` runs the
# target repository's own commands from shell on every attempt and its exit status
# is the answer; the agent is only ever the thing that reacts to a failure. An
# agent asked to both fix and declare the result would eventually declare.
#
# Exit status: 0 all checks pass, 20 the fix agent is blocked and a human is
# needed, 1 still failing after the last attempt (or the fix agent gave up).
set -eu

run_dir=$1
repo=$2
workspace=$3
skill=$4
attempts=${5:-3}
tier=${6:-standard}   # reacting to a named failure, with the suite as the check
budget=${7:-2}
stage=${8:-verify}

here=$(cd "$(dirname "$0")" && pwd)

# Always `verify` as the label, whatever the stage: the log lands on
# `<run-dir>/verify.log`, which is the path the fix-verify prompt names. Each
# failed attempt is then copied aside, so the history of a long fight survives
# for whoever reads the run afterwards without the fix agent having to guess
# which file is current.
attempt=1
while :; do
  printf '\n########## %s: attempt %s of %s ##########\n' "$stage" "$attempt" "$attempts"

  if "$here/run-verification.sh" "$run_dir" verify; then
    printf '\n[%s] verification passed on attempt %s\n' "$stage" "$attempt"
    exit 0
  fi

  # Keep the *summary* of each failed attempt, not the whole 300 KB log. The next
  # fix agent is told to read the earlier attempts so it does not retry what has
  # already failed, and for that it needs to know what failed, not every line the
  # suite printed while failing.
  cp "$run_dir/verify.summary.log" \
     "$run_dir/verify.$stage-$attempt.summary.log" 2>/dev/null || true

  if [ "$attempt" -ge "$attempts" ]; then
    echo "[$stage] still failing after $attempts attempts; giving up" >&2
    exit 1
  fi

  printf '\n########## %s: fixing (attempt %s) ##########\n' "$stage" "$attempt"

  # run-phase.sh exits 20 for `blocked`, which is a routing decision rather than
  # a defect -- looping again would spend a second model on the same unanswered
  # question. `set -e` would take the exit status as the script's own, so read it.
  status=0
  "$here/run-phase.sh" fix-verify "$run_dir" "$repo" "$workspace" "$skill" \
    "$tier" "$budget" || status=$?

  # Keep the whole attempt: the next one overwrites every file in the phase
  # directory, and a run that ends up failing is usually diagnosed from the
  # earlier ones. The agent stream is also what summarize-run.sh counts tokens
  # from, so an unpreserved attempt is one that cost money and does not appear in
  # the report.
  #
  # A directory per attempt rather than a suffix per file. Renaming each file
  # meant deciding where the suffix went relative to the extension, and left the
  # attempt's `result.json` under a name nothing looked for -- so the accounting
  # showed every attempt row with the *last* attempt's status. A directory needs
  # no naming rule and reads with exactly the same paths as any other phase.
  archive="$run_dir/fix-verify/$stage-$attempt"
  mkdir -p "$archive"
  for f in result.json agent-stream.jsonl started_at ended_at plan prompt.md; do
    [ -f "$run_dir/fix-verify/$f" ] && cp "$run_dir/fix-verify/$f" "$archive/" || true
  done

  case "$status" in
    0) ;;
    20)
      echo "[$stage] the fix phase is blocked; stopping" >&2
      exit 20
      ;;
    *)
      # `failed` from the fix agent is a considered verdict -- most often a
      # broken environment or a failure that predates this branch. Retrying it
      # buys nothing but another model's fee.
      echo "[$stage] the fix phase failed; stopping rather than retrying" >&2
      exit 1
      ;;
  esac

  attempt=$((attempt + 1))
done
