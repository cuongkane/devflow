---

## Correction: this is a minor run, and there is no specification

The instructions above are written for the major implementation flow. This issue
was claimed by the minor flow instead — the clarifier judged that its
requirements are already settled and that implementing it introduces no new
product meaning. **Where the two disagree, this section wins.**

What the phase above may refer to that does not exist here:

| Named above, absent here | What the phase above may tell you to do with it |
|---|---|
| the OpenSpec change `{{CHANGE}}` | `openspec show`, `openspec validate`, update its artifacts |
| its `proposal.md`, `design.md`, `tasks.md`, delta specs | work the task list, keep the specs honest |
| `{{RUN_DIR}}/explore.md` | read the earlier phase's findings |
| `{{REVIEW_COMMENTS_PATH}}` | resolve the review's findings |

`{{CHANGE}}` is a name in `state.json` and nothing more on this path: no change
directory was created, nothing will archive one, and this run does not touch the
main specs. Do not create any of it. Do not run `openspec new change`,
`openspec archive` or `openspec validate`, and do not edit anything under
`{{WORKTREE}}/openspec/`.

The requirements are in `{{BRIEF_PATH}}`, and only there.

**Nothing reviews this but a human.** The minor flow has no `review` phase and no
`resolve-review` phase. The verification suite runs from shell and its exit status
is the only automated gate before the pull request opens. So keep the diff to what
the work actually needs — an unrelated refactor or leftover debugging reaches the
pull request unread — and get the tests right the first time, because nothing
downstream will notice one that cannot fail.
