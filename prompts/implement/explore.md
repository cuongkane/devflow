## Phase: explore

Understand what the brief asks for and how this repository already does it. You
are not designing the change yet and you are not writing any application code.

Invoke the worktree's `openspec-explore` skill
(`{{WORKTREE}}/.claude/skills/openspec-explore/SKILL.md`) and hold its stance.
Start from OpenSpec — `openspec list --specs`, `openspec list`, `openspec show
<item>` — so you find the requirements that already govern this behaviour before
you read any code. Then read the affected code, its tests, the Feature RFCs, and
enough git history to know what the product does today.

Read the root `CLAUDE.md` and the instructions for every component the brief
plausibly touches. Repository-local instructions override anything generic.

## What to write

Write `{{RUN_DIR}}/explore.md`. The proposal phase reads this **instead of**
re-exploring, so it has to stand on its own:

- **Problem and desired outcome** — from the brief.
- **Current behaviour** — what the code actually does today, with the paths and
  symbols that establish it. Be specific: this is the one phase whose job is to
  turn a requirements-only brief into concrete repository facts.
- **Proposed user-visible behaviour.**
- **Backend / frontend boundary** — what crosses the API, and what the contract
  would have to say about types, casing, authorization, `Club-ID`, and kVND units.
- **Existing OpenSpec capabilities affected**, by name, with what they say today.
- **Constraints, edge cases and failure paths** the brief does not mention.
- **Facts vs assumptions** — keep these separate and label them. An assumption
  recorded here reaches the proposal and surfaces in review; one you forget to
  record ships silently.

Resolve ordinary unknowns from repository evidence rather than reporting them.

## Boundaries

This phase is **read-only for application code**. Do not edit source, do not
create the OpenSpec change, do not run the test suite, do not commit. The
worktree already exists — do not create another.
