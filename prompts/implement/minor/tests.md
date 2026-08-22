## Phase: write the tests, and get them passing

The previous phase wrote the fix and no tests. Write them, run them, and do not
finish until they pass.

This is the minor flow, so there is no OpenSpec change to check against and no
`tasks.md` to work through. Your inputs are:

```
{{RUN_DIR}}/code/result.json   what the previous phase says it changed and why
{{BRIEF_PATH}}                 what was asked for
{{DIFF_STAT_PATH}}             what changed, by file
{{DIFF_PATH}}                  the diff itself
```

Both diff files are already on disk, current as of the moment this phase started.
Do not run `git diff` yourself; that is the same content a second time.

The testing standards at the end of this prompt govern how every test here is
written; hold them for the whole phase. Where they and this prompt disagree about
how a test is written, they win.

## What to cover

The changed behaviour, its branches, and its error paths. On a fix that is
usually smaller than it sounds:

- **The defect itself** — a test that fails against the old behaviour and passes
  against the new one. This is the one test that must exist. Check it by reasoning
  about what the code did before the diff: a test that would also have passed
  before is not a test of this change.
- **The boundary the fix introduced** — the empty case, the null, the off-by-one
  edge, whichever the fix actually turns on.
- **Nothing else.** Do not backfill coverage for code this change did not touch.
  That is a larger diff for a reviewer who asked for a fix, and it is how a minor
  change stops being minor.

Match the repository's existing test layout, naming and fixtures rather than
inventing a local style — the tests you read in the previous phase are the model.

## The loop

Run the focused tests for what you have written — the individual test module or
target, not the whole suite — and keep going until they pass:

1. Write the test.
2. Run it.
3. If it fails, decide what is actually wrong:
   - the test misreads the intended behaviour → fix the test;
   - the fix is wrong or incomplete → **fix the production code**, and say so in
     your summary.
4. Repeat until the tests you wrote pass.

You are allowed to change production code here — this is the phase where a test
gets to reject the fix. What you may not do is weaken a test, delete an assertion,
add a skip, loosen a type, or widen an exception to make something go green. If a
pre-existing test asserts the behaviour this issue calls a defect, change it
deliberately and quote the requirement that makes the old assertion obsolete.

Commit as you go on `{{BRANCH}}`, following the conventions in recent history.

## This is the last phase that reads the code

There is no `review` phase on the minor flow. After you, the verification suite
runs from shell, and if it is green the branch is pushed and the pull request
opens. So before you report `done`, read the whole diff once as a reviewer would
and make sure of three things:

- Nothing unrelated is in it — no debugging leftovers, no generated files, no
  local environment files, no reformatted code the change did not need.
- The test you wrote genuinely fails without the fix.
- The fix addresses the brief, not merely the symptom the brief described.

Fix what you find; if what you find is that the implementation is wrong and you
cannot correct it, report `failed` and say so.

## Boundaries

Do not run the full verification suite — the step immediately after you runs the
target repository's own commands from shell, and its exit status is the verdict,
not yours. Running it here spends your budget on the same answer. Do not push,
open a pull request, touch the OpenSpec artifacts, or refactor code the change did
not touch.

Report `done` only if the tests you wrote actually pass. If you leave anything red,
report `failed` with the failing test named — the next step runs the suite
regardless, and a false `done` only makes its failure harder to read.
