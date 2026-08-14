## Phase: synchronize the specifications

Merge what was actually built into the repository's specifications, so the specs
describe the shipped behaviour rather than the intended behaviour.

Invoke `openspec-sync-specs`
(`{{WORKTREE}}/.claude/skills/openspec-sync-specs/SKILL.md`) with the explicit
change name `{{CHANGE}}`.

Confirm the merge is idempotent and that it preserves unrelated requirements —
a sync that overwrites a neighbouring capability's requirements is worse than no
sync at all, because the loss is invisible in the pull request diff of the code.

Also update any frontend Feature RFC required by `{{WORKTREE}}/sweatcharge_fe/AGENTS.md`
and its current spec guide.

## Reconcile before you merge

By now the code has been through implementation, a verification fix, and a
review. If any of those changed the behaviour away from what the delta specs for
`{{CHANGE}}` describe, update the delta specs to match the code **before**
syncing — the shipped behaviour is the truth, and the specification is what has
to move.

## Before you finish

Confirm every task in the change is checked off, then run:

```bash
openspec status --change "{{CHANGE}}"
openspec validate "{{CHANGE}}" --strict
```

Fix anything either reports. The next step archives this change from shell with
`--yes` and no human to confirm a warning, so it has to be clean when you leave it.

Commit the spec changes.

## Boundaries

Do not archive the change — the next step does that. Do not push or open a pull
request.
