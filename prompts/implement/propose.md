## Phase: propose

Turn the exploration into an apply-ready OpenSpec change. Still no application
code.

Read `{{RUN_DIR}}/explore.md` first — it is the previous phase's findings, and
re-deriving them wastes the budget this phase has for design.

Invoke `openspec-propose`
(`{{WORKTREE}}/.claude/skills/openspec-propose/SKILL.md`). **The change is named
`{{CHANGE}}`** — create it under exactly that name (`openspec new change
"{{CHANGE}}"`). Every later phase addresses the change directory by that name;
choosing your own strands them.

Follow the CLI-reported artifact graph and paths rather than assuming locations.

## What the artifacts must cover

- Both backend and frontend when the behaviour crosses the API boundary.
- API contracts, authorization, monetary units (kVND), validation, and failure
  behaviour, wherever the change touches them.
- Explicit implementation, test, verification, and Feature RFC update tasks in
  `tasks.md`. The next phase works through that list and checks items off, so a
  vague task becomes vague code — make each one small and independently checkable.
- Facts and assumptions distinguished, with the assumptions carried forward from
  `explore.md` so they surface in review.
- A scope narrow enough for one reviewable pull request.

## Before you finish

Run `openspec status --change "{{CHANGE}}"` and `openspec validate "{{CHANGE}}"
--strict`. Fix every artifact error. A change that does not validate here fails
the archive phase two hours later, after all the expensive work is done.

## Boundaries

Do not implement anything. Do not edit application source or tests. Do not
commit. Write the proposal, design, delta specs and tasks — nothing else.
