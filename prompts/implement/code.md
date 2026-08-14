## Phase: write the code and its tests

Implement the change `{{CHANGE}}` against the tasks its proposal defines. This is
the longest phase of the run; it is also the only one that writes application
code.

Read, in this order: `{{RUN_DIR}}/explore.md`, then the change's own artifacts
(`openspec show "{{CHANGE}}"`, its `proposal.md`, `design.md` and `tasks.md`).
Then read the `{{SKILL}}` skill's `references/engineering-practices.md` and
`references/testing-standards.md` and hold both for the whole phase.

Invoke `openspec-apply-change`
(`{{WORKTREE}}/.claude/skills/openspec-apply-change/SKILL.md`) with change name
`{{CHANGE}}`.

## Per task

1. Read the CLI-provided context files.
2. Inspect the local pattern for the thing you are about to write, and match it.
3. Implement the smallest cohesive change that satisfies the task.
4. Add or update its tests in the same task, not "later".
5. Run the focused check for what you just changed.
6. Check the task off only once its code **and** its tests are done.

Every changed behaviour, branch and error path needs a test that actually
observes it. A test that would pass against the old code is not a test of your
change.

If implementing something invalidates the design, update the proposal, design,
delta specs or tasks before continuing, and re-validate. Never leave shipped
behaviour differing from the artifacts — the archive phase merges those artifacts
into the main specs, so a lie here becomes a lie in the specification.

## Commit as you go

Commit coherent units of work as you complete tasks, on `{{BRANCH}}`. Follow the
commit conventions you can see in recent history. Leaving everything uncommitted
means a phase that dies later loses the lot; committing lets the next attempt
start from real work.

## Boundaries

Do not run the full verification suite — the next phase does that from shell, and
running it here just spends your budget twice. Focused checks only. Do not push,
do not open a pull request, do not sync or archive specs.
