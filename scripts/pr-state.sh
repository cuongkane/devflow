#!/usr/bin/env sh
# Dump everything the delivery agents need to know about one pull request.
#
#   pr-state.sh <owner/name> <pr-number>
#
# GraphQL rather than `gh pr view` because REST has no notion of review-thread
# resolution, and "is this conversation resolved?" is the signal the whole
# review loop turns on.
set -eu

repo=$1
pr=$2
owner=${repo%%/*}
name=${repo##*/}

gh api graphql \
  -f owner="$owner" -f name="$name" -F pr="$pr" \
  -f query='
    query($owner:String!, $name:String!, $pr:Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          number url title state isDraft merged mergedAt
          headRefName baseRefName
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line
              comments(first: 20) {
                nodes { author { login } createdAt body }
              }
            }
          }
          reviews(last: 50) {
            nodes { state submittedAt author { login } body }
          }
          comments(last: 100) {
            nodes { createdAt author { login } body }
          }
        }
      }
    }' \
  --jq '.data.repository.pullRequest'
