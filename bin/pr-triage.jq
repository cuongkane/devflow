# Decide what should happen to a pull request, from the JSON that
# bin/pr-state.sh emits. Shared by the delivery poller (which dispatches on
# `action`) and the responder agent (which reports the counts back).
#
# Author identity is deliberately never used to tell agent activity from human
# activity: the agent runs as the repository owner's own `gh` login, so every
# comment it writes carries the owner's name. The marker below is the only
# reliable discriminator.
def marker: "<!-- agent:responded -->";

. as $pr

# When the responder last declared itself finished. Everything newer than this
# is unseen.
| ([$pr.comments.nodes[] | select(.body | contains(marker)) | .createdAt] | max
   // "1970-01-01T00:00:00Z") as $since

# Unresolved threads whose newest comment predates $since are ones the responder
# has already replied to and chose not to resolve. Counting those would re-fire
# the responder on every poll forever, so only threads with genuinely new
# activity count as outstanding work.
| ([$pr.reviewThreads.nodes[]
     | select(.isResolved | not)
     | select(([.comments.nodes[].createdAt] | max // "1970-01-01T00:00:00Z") > $since)]
   | length) as $unresolved

# An approval needs no reply; a comment or a change request does.
| ([$pr.reviews.nodes[]
     | select(.submittedAt > $since)
     | select(.state != "APPROVED")]
   | length) as $new_reviews

| ([$pr.comments.nodes[]
     | select((.body | contains(marker)) | not)
     | select(.createdAt > $since)]
   | length) as $new_comments

| {
    pr: $pr.number,
    url: $pr.url,
    head: $pr.headRefName,
    base: $pr.baseRefName,
    merged: $pr.merged,
    state: $pr.state,
    since: $since,
    unresolved: $unresolved,
    new_reviews: $new_reviews,
    new_comments: $new_comments,
    action: (
      if $pr.merged then "close"
      elif $pr.state == "CLOSED" then "abandoned"
      elif ($unresolved + $new_reviews + $new_comments) > 0 then "respond"
      else "idle"
      end
    )
  }
