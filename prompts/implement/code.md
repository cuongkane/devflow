## Phase: write the implementation

Implement the change `{{CHANGE}}` against the tasks its proposal defines. This
phase writes the **production code** only. The next phase, `tests`, writes the
tests that prove it — do not write the test suite here.

Read, in this order: `{{RUN_DIR}}/explore.md`, then the change's own artifacts
(`openspec show "{{CHANGE}}"`, its `proposal.md`, `design.md` and `tasks.md`).
The engineering practices at the end of this prompt apply to every line you
write; hold them for the whole phase.

Invoke `openspec-apply-change`
(`{{WORKTREE}}/.claude/skills/openspec-apply-change/SKILL.md`) with change name
`{{CHANGE}}`.

## Per task

1. Read the CLI-provided context files.
2. Inspect the local pattern for the thing you are about to write, and match it.
3. Implement the smallest cohesive change that satisfies the task.
4. Run the focused check for what you just changed — a type check, a lint, an
   existing test that touches the code — enough to know it is not obviously
   broken.
5. Check the task off once its implementation is done, and note in `tasks.md`
   what still needs test coverage.

Leave the code testable: no behaviour that can only be reached through a
private path, no logic buried where a test cannot observe it. The next phase has
to write a test for every changed behaviour, branch and error path, and it
cannot change the design to make that possible.

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

Do not write the tests — that is the `tests` phase, which runs next with its own
budget and the testing standards loaded. Do not run the full verification suite;
focused checks only. Do not push, do not open a pull request, do not sync or
archive specs.

Your `summary` in `{{RESULT_PATH}}` must say which tasks you implemented and what
behaviour the next phase has to cover, so it does not have to infer that from the
diff alone.
