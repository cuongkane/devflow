## Phase: write the tests, and get them passing

The previous phase implemented `{{CHANGE}}` and wrote no tests. Write them, run
them, and do not finish until they pass.

Read `{{RUN_DIR}}/code/result.json` for what the implementation phase says it
built, then the change's `tasks.md` and delta specs, then the actual diff —
already written out for you, current as of the moment this phase started:

```
{{DIFF_STAT_PATH}}   what changed, by file
{{DIFF_PATH}}        the diff itself
```

Do not run `git diff` yourself; that is the same content a second time.

The testing standards at the end of this prompt govern how every test here is
written; hold them for the whole phase. Where they and this prompt disagree about
how a test is written, they win.

## What to cover

Every changed behaviour, branch and error path needs a test that actually
observes it. A test that would pass against the code as it was before this branch
is not a test of this change — check that by reasoning about the old behaviour,
and delete or fix any test that fails that bar.

Match the repository's existing test layout, naming and fixtures rather than
inventing a local style.

## The loop

Run the focused tests for what you have written — the individual test module or
target, not the whole suite — and keep going until they pass:

1. Write or extend the tests for one task.
2. Run them.
3. If they fail, decide what is actually wrong:
   - the test misreads the intended behaviour → fix the test;
   - the implementation is wrong or incomplete → **fix the implementation**, and
     say so in your summary.
4. Repeat until the tests you wrote pass, then move to the next task.

You are allowed to change production code here — this is the phase where a test
gets to reject the implementation. What you may not do is weaken a test, delete
an assertion, add a skip, loosen a type, or widen an exception to make something
go green. If a pre-existing test asserts behaviour the brief explicitly changes,
change it deliberately and cite that requirement in your summary.

Commit as you go on `{{BRANCH}}`, following the conventions in recent history.

## Boundaries

Do not run the full verification suite — the `verify` step runs the target
repository's own commands from shell immediately after you, and its exit status
is the verdict, not yours. Running it here spends your budget on the same answer.
Do not push, do not open a pull request, do not sync or archive specs, and do not
refactor code the change did not touch.

Report `done` only if the tests you wrote actually pass. If you leave anything
red, report `failed` with the failing test named — the next step will run the
suite regardless, and a false `done` here only makes its failure harder to read.
