# Render the outstanding review feedback on a pull request as markdown, for the
# responder agent to read as a file.
#
#   jq -r --argjson triage "$(cat triage.json)" -f review-digest.jq pr.json
#
# $triage supplies `since` so this file and scripts/pr-triage.jq cannot drift on
# what counts as new.
def marker: "<!-- agent:responded -->";

($triage.since) as $since

| [ "# Review feedback on PR #\(.number)",
    "",
    "\(.url)",
    "",
    "Branch `\(.headRefName)` into `\(.baseRefName)`.",
    "Everything below arrived after \($since).",
    ""
  ]

+ ( [ .reviewThreads.nodes[]
        | select(.isResolved | not)
        | select(([.comments.nodes[].createdAt] | max // "1970-01-01T00:00:00Z") > $since) ]
    | if length == 0 then []
      else ["## Unresolved threads", ""]
           + ( to_entries | map(
                 "### Thread \(.key + 1) — `\(.value.path // "(no file)")`"
                 + (if .value.line then " line \(.value.line)" else "" end)
                 + (if .value.isOutdated then " *(outdated — the code moved since)*" else "" end)
                 + "\n\nThread id: `\(.value.id)`\n"
                 + ( [.value.comments.nodes[]
                       | "\n**\(.author.login // "?")** at \(.createdAt)\n\n\(.body)"]
                     | join("\n") )
                 + "\n" ) )
      end )

+ ( [ .reviews.nodes[]
        | select(.submittedAt > $since)
        | select(.state != "APPROVED")
        | select((.body // "") != "") ]
    | if length == 0 then []
      else ["## New reviews", ""]
           + map("**\(.author.login // "?")** — \(.state) at \(.submittedAt)\n\n\(.body)\n")
      end )

+ ( [ .comments.nodes[]
        | select((.body | contains(marker)) | not)
        | select(.createdAt > $since) ]
    | if length == 0 then []
      else ["## New pull request comments", ""]
           + map("**\(.author.login // "?")** at \(.createdAt)\n\n\(.body)\n")
      end )

| join("\n")
