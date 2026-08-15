# Render Claude, Codex or opencode JSONL into a readable Dagu run log.
#
# $agent, $tier and $model come from run-agent.sh, which resolved them from
# agent.yaml. The two session lines below were asymmetric -- claude reported a
# model and no agent, codex an agent and no model -- so neither answered "what
# actually ran this phase" on its own.
if .type == "system" and .subtype == "init" then
  # Claude reports the model it loaded. Prefer it over the configured name: the
  # configuration holds a tier alias like `opus`, this is what that resolved to.
  "session \(.session_id // "?")  agent=\($agent)  tier=\($tier)  model=\(.model // $model)"
elif .type == "thread.started" then
  # Codex's thread.started carries no model, so the configured name is the best
  # available answer -- and `<cli default>` says honestly that we do not know.
  "session \(.thread_id // "?")  agent=\($agent)  tier=\($tier)  model=\($model)"
elif .type == "item.started" and .item.type == "command_execution" then
  "-> shell \(.item.command // "")"
elif .type == "item.completed" and .item.type == "command_execution" then
  (if (.item.exit_code // 0) != 0 then
     "   command error (exit \(.item.exit_code)): \((.item.aggregated_output // "") | .[0:300])"
   else empty end)
elif .type == "item.completed" and .item.type == "agent_message" then
  (.item.text // empty)
elif .type == "turn.completed" then
  "== success  input_tokens=\(.usage.input_tokens // 0)  output_tokens=\(.usage.output_tokens // 0)"
elif .type == "turn.failed" then
  "== failed  \(.error.message // .error // "unknown error")"
elif .type == "assistant" then
  (.message.content[]? |
     if .type == "text" then (.text | select(length > 0))
     elif .type == "tool_use" then
       "-> \(.name) \(.input | tostring | .[0:200])"
     else empty end)
elif .type == "user" then
  (.message.content[]? | select(.type == "tool_result")
     | select(.is_error // false)
     | "   tool error: \((.content | tostring) | .[0:300])")

# opencode. Its event names do not collide with the two above, so the same
# renderer serves all three. It has no session-start event at all -- every event
# just carries sessionID -- so the session line is printed by run-agent.sh once
# the stream file exists, and `step_start` renders nothing here rather than
# repeating a banner on every turn.
elif .type == "step_start" then empty
elif .type == "text" then
  (.part.text // "" | select(length > 0))
elif .type == "tool_use" then
  ("-> \(.part.tool // "?") \(.part.state.input // {} | tostring | .[0:200])"),
  (if .part.state.status == "error" then
     "   tool error: \((.part.state.error // .part.state.output // "") | tostring | .[0:300])"
   elif (.part.state.metadata.exit // 0) != 0 then
     "   command error (exit \(.part.state.metadata.exit)): \((.part.state.output // "") | .[0:300])"
   else empty end)
elif .type == "step_finish" then
  # One step per assistant turn, and a turn that ends in `tool-calls` is only
  # pausing to run them -- reporting those would put a usage line between every
  # tool call and the next. Only the steps that actually end a message are shown;
  # summarize-run.sh reads the full per-step accounting back out of the JSONL.
  (if (.part.reason // "") == "tool-calls" then empty
   else
     "== \(.part.reason // "?")  input_tokens=\(.part.tokens.input // 0)  output_tokens=\(.part.tokens.output // 0)  cost_usd=\(.part.cost // 0)"
   end)
elif .type == "error" then
  # opencode reports a failed prompt or a session error as its own event and
  # then exits non-zero, so this line is the only description of *why* a phase
  # failed that reaches the log. `.error.data.message` is the human sentence when
  # there is one; `.error.name` is the class of failure when there is not.
  "== failed  \(.error.data.message // .error.name // (.error | tostring) | tostring | .[0:500])"

elif .type == "result" then
  "== \(.subtype)  turns=\(.num_turns // 0)  cost_usd=\(.total_cost_usd // 0)  \(((.duration_ms // 0) / 1000) | floor)s"
else empty end
