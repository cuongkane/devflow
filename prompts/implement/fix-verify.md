## Phase: fix the failing checks

The verification suite ran against `{{WORKTREE}}` and failed. Its full output is
in `{{RUN_DIR}}/verify.log`. Make it pass.

The commands that ran are the target repository's own:

```
make test-ci-migrations
make test-ci
cd sweatcharge_fe && yarn lint && yarn test:unit && yarn build   # if the frontend changed
```

They will be run again, unchanged, immediately after you finish, and you will be
called again if they still fail. You do not need to run the full suite yourself —
run the focused check for whatever you are fixing, and let the shell step be the
verdict.

If `{{RUN_DIR}}/verify.*-*.log` files exist, they are earlier attempts in this
same loop. Read the most recent one before starting: something has already been
tried and did not work, and repeating it wastes the remaining attempts.

## How to fix

Read the log first and find the actual first failure; later failures are often
consequences of it. Then fix the **cause**, to the engineering practices and
testing standards appended at the end of this prompt.

Do not weaken a test, delete an assertion, add a skip, loosen a type, or widen an
exception to make a check pass. If a test is genuinely wrong — it asserts
behaviour the brief explicitly changes — say so in your summary and change it
deliberately, citing the requirement that makes the old assertion obsolete.

If a failure is environmental rather than caused by this branch (a service that
will not start, a missing credential, a pre-existing failure on the base commit),
do not paper over it. Confirm it against the base ref if you can, and report
`failed` with that distinction stated plainly. A run that honestly reports a
broken environment is worth more than one that mutates tests until it is green.

If a fix changes the design, update the OpenSpec artifacts for `{{CHANGE}}` to
match and re-validate strictly.

## Boundaries

Fix what is failing. This is not an opportunity to refactor adjacent code, and
every unrequested change enlarges the diff the review phase must read.
