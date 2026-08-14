## Phase: review the diff and fix what it finds

Review the complete branch diff as a reviewer would, then fix what you find. The
verification suite has already passed — this phase is for what a green suite does
not catch.

```bash
git -C {{WORKTREE}} diff {{BASE}}...HEAD
```

Use the repository's own code-review skill or `/code-review`, run from inside the
worktree. Review against `{{RUN_DIR}}/explore.md`, the brief, and the OpenSpec
scenarios for `{{CHANGE}}` — correctness is correctness *against the requirement*,
not merely internal consistency.

## What to look for

- Correctness against every OpenSpec scenario, including the ones with no test.
- Regressions, unhandled edge cases, and error paths that silently swallow.
- Authorization, club/tenancy isolation, monetary units (kVND), migrations,
  and backward compatibility. Treat all five as high-risk.
- Cross-stack contract drift: request/response types, casing conversion,
  `Club-ID` handling, nullability, enums, date/time, error semantics.
- Tests that cannot fail — the false-positive test is the most expensive defect
  to find later, because it advertises coverage that does not exist.
- Accidental files: generated output, secrets, local environment files, debris
  from your own debugging, anything unrelated to this change.

## Then fix

Fix everything critical and important. Add the test that would have caught each
defect you fix. Re-read the resulting diff — your fixes are also unreviewed code.

Leave a genuinely minor nit alone rather than growing the diff for it; note it in
your summary instead.

## Boundaries

The verification suite runs again from shell after you finish, so any code you
touch here is re-checked from the final source state. Do not sync specs, archive,
push, or open a pull request.
