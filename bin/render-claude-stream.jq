# Renders `claude --output-format stream-json` into something readable in the
# dagu run view. Used by bin/run-claude.sh; kept in one file so a fix here
# reaches every agent DAG at once.
if .type == "system" and .subtype == "init" then
  "session \(.session_id // "?")  model=\(.model // "?")"
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
