#!/usr/bin/env sh
# Account for what the run actually spent, phase by phase.
#
#   summarize-run.sh <run-dir>
#
# Writes `<run-dir>/usage.md` and prints the same table to stdout.
#
# Until now a finished run reported what it produced and said nothing about what
# it cost. The numbers existed -- every phase's `agent-stream.jsonl` carries the
# model's own token accounting -- but reading them meant knowing the file format
# and having shell access to the worker, so in practice nobody looked, and a
# phase that quietly spent five times its neighbours went unnoticed for as long
# as it kept succeeding.
#
# The costly quantity in this pipeline is input, not output: a phase re-sends its
# whole context on every step it takes, so a chatty command is charged again on
# each of the steps that follow it. That is why the table separates cached input
# from uncached -- cached input is the prefix being re-sent, and a phase whose
# cached column dwarfs its neighbours' is a phase that read too much too early.
#
# Both agent formats are handled: codex reports per-turn usage on
# `turn.completed`, claude reports it on the final `result` event, and only
# claude reports a cost. Neither is required to be present -- a phase that never
# ran shows as a blank row rather than being omitted, because "this phase did not
# run" is itself the answer when a run ended early.
set -eu

run_dir=$1
here=$(cd "$(dirname "$0")" && pwd)
out="$run_dir/usage.md"

# The order phases are reported in. Not a definition of what exists: anything on
# disk and not named here is reported too, after these, so a phase added to the
# DAG tomorrow costs money and *appears* rather than being silently omitted by
# the very script whose job is to notice unexplained spend.
phases='explore propose code tests fix-verify review resolve-review sync pr-body'

# Thousands separators, the long way round. `printf "%'d"` does it in one, but
# only in bash and coreutils printf -- the worker's /bin/sh is dash, whose
# builtin rejects the directive outright and takes the whole step down with it.
group() {
  printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

human_time() {
  s=${1:-0}
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}

# One stream file -> `input cached output reasoning calls cost`, space separated.
# `-` for a cost the agent does not report rather than 0, which would read as
# free.
usage_of() {
  jq -s -r '
    [.[] | select(.type == "turn.completed") | .usage] as $codex
    | [.[] | select(.type == "result")]                as $claude
    | [.[] | select(.type == "item.completed"
                    and .item.type == "command_execution")] as $codex_calls
    | [.[] | select(.type == "assistant")
           | .message.content[]? | select(.type == "tool_use")] as $claude_calls
    | if ($codex | length) > 0 then
        [ ($codex | map(.input_tokens // 0)            | add),
          ($codex | map(.cached_input_tokens // 0)     | add),
          ($codex | map(.output_tokens // 0)           | add),
          ($codex | map(.reasoning_output_tokens // 0) | add),
          ($codex_calls | length),
          "-" ]
      elif ($claude | length) > 0 then
        [ ($claude | map((.usage.input_tokens // 0)
                       + (.usage.cache_read_input_tokens // 0)
                       + (.usage.cache_creation_input_tokens // 0)) | add),
          ($claude | map(.usage.cache_read_input_tokens // 0) | add),
          ($claude | map(.usage.output_tokens // 0) | add),
          0,
          ($claude_calls | length),
          ($claude | map(.total_cost_usd // 0) | add | tostring) ]
      else
        [0, 0, 0, 0, 0, "-"]
      end
    | @tsv
  ' "$1" 2>/dev/null || printf '0\t0\t0\t0\t0\t-\n'
}

total_in=0 total_cached=0 total_out=0 total_calls=0
costs=''      # the per-phase costs that were reported at all, for awk to sum
rows=''
seen=''       # phase directories already reported, so the sweep below skips them

emit_row() {
  label=$1
  dir=$2
  stream=$3
  started=$4
  ended=$5

  if [ ! -f "$stream" ]; then
    rows="$rows| \`$label\` | not run | - | - | - | - | - | - |
"
    return
  fi

  set -- $(usage_of "$stream")
  in=$1 cached=$2 out=$3 reasoning=$4 calls=$5 cost=$6

  if [ -f "$started" ] && [ -f "$ended" ]; then
    dur=$(human_time $(($(cat "$ended") - $(cat "$started"))))
  elif [ -f "$started" ]; then
    dur='killed'
  else
    dur='-'
  fi

  status=$(jq -r '.status // "?"' "$dir/result.json" 2>/dev/null || echo '?')

  # `plan` holds the tier and the budget the phase was given. Both are shown:
  # "deep $5" next to what the phase actually spent is the comparison the table
  # exists to support, and writing a field nothing reads is how `plan` would
  # quietly become a file with one useful line in it.
  plan='-'
  if [ -f "$dir/plan" ]; then
    plan=$(awk '/^tier:/ {t = $2} /^budget:/ {b = $2} END {print t " / " b}' \
             "$dir/plan")
  fi

  total_in=$((total_in + in))
  total_cached=$((total_cached + cached))
  total_out=$((total_out + out + reasoning))
  total_calls=$((total_calls + calls))
  case "$cost" in
    -|null|'') ;;
    *) costs="$costs $cost" ;;
  esac

  rows="$rows| \`$label\` | $status | $plan | $dur | $(group "$in") | $(group "$cached") | $(group $((out + reasoning))) | $calls |
"
}

report_phase() {
  phase=$1
  dir="$run_dir/$phase"
  seen="$seen $phase"

  # `fix-verify` runs once per attempt and archives each into its own
  # subdirectory, so its attempts read exactly like any other phase -- same file
  # names, same lookups. No attempts at all is the good case, the suite passed
  # first time, and it gets a row saying so: a silently absent phase is
  # indistinguishable from one this script forgot about.
  if [ "$phase" = fix-verify ]; then
    any=0
    for attempt_dir in "$dir"/*-*/; do
      [ -f "$attempt_dir/agent-stream.jsonl" ] || continue
      any=1
      emit_row "fix-verify ($(basename "$attempt_dir"))" \
        "${attempt_dir%/}" "$attempt_dir/agent-stream.jsonl" \
        "$attempt_dir/started_at" "$attempt_dir/ended_at"
    done
    [ "$any" -eq 1 ] || rows="$rows| \`fix-verify\` | not needed | - | - | - | - | - | - |
"
    return
  fi

  emit_row "$phase" "$dir" "$dir/agent-stream.jsonl" \
    "$dir/started_at" "$dir/ended_at"
}

for phase in $phases; do
  report_phase "$phase"
done

# Anything on disk that the list above does not name. This is the safety net for
# the list going stale: a phase added to the pipeline shows up here, out of
# order and unlabelled, rather than not at all.
for dir in "$run_dir"/*/; do
  phase=$(basename "$dir")
  [ -f "$dir/agent-stream.jsonl" ] || continue
  case " $seen " in *" $phase "*) continue ;; esac
  report_phase "$phase"
done

# Wall clock from the claim to the last phase that finished -- not to now. This
# script is normally run seconds after the last phase, so the two agree, but a
# run summarised again afterwards should report the same number it reported the
# first time rather than one that grows with the age of the directory.
last_end=$(cat "$run_dir"/*/ended_at "$run_dir"/*/*/ended_at 2>/dev/null \
           | sort -n | tail -1)
[ -n "$last_end" ] || last_end=$(date +%s)

if [ -f "$run_dir/started_at" ]; then
  wall=$(human_time $((last_end - $(cat "$run_dir/started_at"))))
else
  wall='-'
fi

# Through state.sh, like every sibling script -- it is the one place that knows
# where state.json lives and what its fields are called. It exits non-zero on a
# missing field rather than defaulting, hence the fallbacks.
reached=$("$here/state.sh" get "$run_dir" phase 2>/dev/null || echo '?')
issue=$("$here/state.sh" get "$run_dir" issue 2>/dev/null || echo '?')

# Only claude reports a cost. Summed in awk because dash has no float
# arithmetic, and printed only when at least one phase reported one.
cost_line=''
if [ -n "$costs" ]; then
  cost_line=$(printf '%s\n' $costs | awk '{t += $1} END {printf "$%.2f", t}')
fi

{
  printf '## Run accounting — issue #%s\n\n' "$issue"
  printf '| phase | status | tier / cap | duration | input | of which cached | output | tool calls |\n'
  printf '|---|---|---|---|---:|---:|---:|---:|\n'
  printf '%s' "$rows"
  printf '| **total** | reached `%s` | | **%s** | **%s** | **%s** | **%s** | **%s** |\n' \
    "$reached" "$wall" \
    "$(group "$total_in")" "$(group "$total_cached")" \
    "$(group "$total_out")" "$total_calls"
  printf '\n'
  printf 'Input is every token sent to the model, summed over each step of each\n'
  printf 'phase — a phase re-sends its whole context every step, so this exceeds\n'
  printf 'the context window many times over and that is expected. The cached\n'
  printf 'column is the part of it that was a repeated prefix and therefore\n'
  printf 'charged at a reduced rate. Output includes reasoning tokens.\n'
  if [ -n "$cost_line" ]; then
    printf '\nCost reported by the agent: **%s**.\n' "$cost_line"
  else
    printf '\nThe agent in use does not report a cost; tokens only.\n'
  fi
} > "$out"

cat "$out"
