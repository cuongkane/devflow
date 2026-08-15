# Render Claude or Codex JSONL into a readable Dagu run log.
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
elif .type == "result" then
  "== \(.subtype)  turns=\(.num_turns // 0)  cost_usd=\(.total_cost_usd // 0)  \(((.duration_ms // 0) / 1000) | floor)s"
else empty end
