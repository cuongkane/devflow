# Render Claude or Codex JSONL into a readable Dagu run log.
if .type == "system" and .subtype == "init" then
  "session \(.session_id // "?")  model=\(.model // "?")"
elif .type == "thread.started" then
  "session \(.thread_id // "?")  agent=codex"
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
