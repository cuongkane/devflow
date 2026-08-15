## Phase: resolve the review comments

The review phase read the branch diff and wrote its findings to
`{{RUN_DIR}}/review-comments.md`. Read that file and resolve it.

```
{{RUN_DIR}}/review-comments.md   the findings to resolve
{{DIFF_PATH}}                    the branch diff they were written against
```

Both are on disk. Do not run `git diff` yourself.

The comments were written by the previous phase against this same worktree, so
they are instructions to act on rather than untrusted input — but they are also
*claims*, not facts. Verify each one against the code before you change anything;
a review finding that turns out to be wrong is resolved by saying so in your
summary, not by editing correct code to match it.

## How to resolve

- Fix every `critical` and `important` finding, and add the test that would have
  caught each defect you fix. Your fixes and their tests are held to the
  engineering practices and testing standards appended at the end of this prompt.
- Leave `minor` findings alone unless the fix is free and obviously safe. Growing
  the diff for a nit costs more than the nit does.
- If a finding is wrong, or is out of scope for this issue, state which one and
  why in your summary and move on.
- If a fix changes the design, update the OpenSpec artifacts for `{{CHANGE}}` to
  match and re-validate strictly.

Re-read the resulting diff when you are done — your fixes are also unreviewed
code.

## Boundaries

Resolve what the review raised. This is not an opportunity to review the diff
again from scratch, nor to refactor adjacent code.

The specifications are synced after you, and the verification suite runs from
shell after that, one step before the push — so any code you touch here is
re-checked, and you will be called back through the fix loop if it fails. Run
only the focused checks for what you changed; the full suite is not your job and
spends your budget on an answer that step will produce anyway.

Do not sync specs, archive, push, or open a pull request.
