## Phase: write the implementation

Build what `{{BRIEF_PATH}}` asks for. This phase writes the **production code**
only — the next phase, `tests`, writes the tests that prove it.

This is the minor flow. The clarifier judged this issue a change whose
requirements are already settled: a defect fix, a copy or layout correction, a
missing guard, a narrow adjustment to behaviour the product already specifies.
So there is no exploration phase before you and no OpenSpec change to work from.
**`{{BRIEF_PATH}}` is the whole specification**, and finding the code is part of
your job.

Do not create an OpenSpec change, do not run `openspec new change` or
`openspec validate`, and do not edit anything under `{{WORKTREE}}/openspec/`. If
the work genuinely cannot be done without changing a specification, see *When it
is not minor* at the bottom.

## Find the code first, narrowly

No earlier phase read the repository for you, and the reason this flow exists is
that a small fix does not need a survey. Locate the code and read *that*:

1. `rtk grep` for the symbol, the user-visible string, or the label the brief
   names. A visible string is usually the shortest path to the right file.
2. Read the file at that range — `rtk read -n`, or `sed -n '<from>,<to>p>'`. Not
   the whole file unless it is short.
3. Read the existing tests for that code. They tell you both the intended
   behaviour and the fixture style the next phase has to match.
4. Read `{{CONVENTIONS_PATH}}` for anything repository-specific that applies.

Do not run `openspec list --specs`, do not sweep the repository, and do not open
files the change will not touch. If three or four targeted reads have not found
it, grep for a different anchor rather than widening to a directory listing.

## Write the smallest correct fix

- Fix the **cause**, not the symptom. A guard added where the bad value is
  consumed, when the bug is that it is produced, moves the defect rather than
  removing it.
- Match the local pattern for whatever you are writing — inspect the neighbouring
  code and follow it rather than importing a style from elsewhere.
- Change nothing the brief did not ask for. No adjacent refactor, no rename, no
  reformatting a file you only needed to read, no dependency bumps. On this flow
  the diff goes to a human with no automated review in between, and every
  unrequested line spends that reviewer's attention.
- Leave the code testable: no behaviour reachable only through a private path.
  The next phase must be able to write a test that observes the fix without
  redesigning anything.
- Run the focused check for what you changed — a type check, a lint, the existing
  test that covers the code — enough to know it is not obviously broken. Not the
  full suite; a later step runs that from shell and its exit status is the verdict.

## Commit as you go

Commit on `{{BRANCH}}`, following the conventions in recent history. A phase that
dies with everything uncommitted loses the lot; committing lets the next attempt
start from real work.

## When it is not minor

You may find the fix cannot be made without changing an API contract, adding a
migration, altering authorization or club/tenancy isolation, touching monetary
values or kVND units, or changing what a requirement *means* rather than how it
is implemented.

Implement the smallest correct form of it anyway, and **say so plainly in your
`summary`** — name what it touched and why it was unavoidable. Your summary
reaches the issue, and the pull request is where a human decides whether this
should have gone through the major flow instead. Do not grow the change into a
feature, and do not write a specification for it here.

## Boundaries

Do not write the tests — that is the next phase, with the testing standards
loaded and its own budget. Do not run the full verification suite. Do not push,
open a pull request, or touch the OpenSpec artifacts.

Your `summary` in `{{RESULT_PATH}}` must name the files you changed and the
behaviour the next phase has to cover, so it does not have to infer that from the
diff alone.
