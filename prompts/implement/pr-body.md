## Phase: write the pull request description and the issue report

Everything is built, reviewed, synced, archived and verified — in that order, so
the suite that passed ran against exactly the tree that is about to be pushed.
Nothing is pushed yet. Your job is the prose that a human reads before any of it — and nothing else.

Read the diff and the artifacts before writing a word:

```
{{DIFF_STAT_PATH}}          what changed, by file
{{DIFF_PATH}}               the diff itself, if the stat is not enough
{{BRIEF_PATH}}              what was asked for
{{RUN_DIR}}/explore.md      the findings the change was designed from
{{VERIFY_SUMMARY_PATH}}     the verification result
```

plus `rtk git log --oneline {{BASE}}..HEAD` from inside `{{WORKTREE}}`, and the
archived `{{CHANGE}}` artifacts. Describe what the diff actually contains. Do not
describe what the plan said it would contain.

## Write `{{RUN_DIR}}/pr-body.md`

The pull request body. It must include:

- **Summary** — what changed and why, in a few sentences.
- **User-visible behaviour** — what someone using the product will now be able
  to do, and what changes for them.
- `Closes #{{ISSUE_NUMBER}}` on its own line, so merging closes the issue.
- **OpenSpec** — change name, the specs synchronized, and the archive location.
- **Implementation notes** — backend and frontend, and the contract between them
  when the change crosses it.
- **Verification** — the commands that ran and their results. Take these from
  `{{VERIFY_SUMMARY_PATH}}`; do not claim a check that is not in it, and do not
  claim a coverage percentage no tool measured.
- **Risk** — migrations, compatibility, rollout, and anything left untested with
  the reason and the residual risk.
- **Assumptions** — every product decision made without confirmation, carried
  from the brief and the proposal, so they surface in review rather than in
  production.

Be honest about what is weak. A reviewer who finds a problem you knew about and
did not mention trusts nothing else in the description.

## Write `{{RUN_DIR}}/report.md`

A short comment posted verbatim on issue #{{ISSUE_NUMBER}}. Different audience:
someone skimming their notifications, who wants to know whether this needs them.
A few lines — what changed, what was verified, what to look at first. Not a
duplicate of the pull request body.

## Boundaries

Write two files. Do not commit, push, open the pull request, or change any code —
the next step does the delivery, and it will not re-read the diff. If you find a
real defect while reading, report `failed` with what you found rather than fixing
it here: fixing code after the verification suite last ran would ship an unchecked
change.
