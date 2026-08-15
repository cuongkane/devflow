## Phase: review the diff

Review the complete branch diff as a reviewer would and write down what you find.
**Do not fix anything in this phase.** A separate phase resolves your comments and
re-runs the verification suite; keeping the two apart means the findings are on
disk and attributable rather than folded silently into the diff.

## What you review

The diff against `{{BASE}}`, and nothing else. It is already on disk, generated
by shell immediately before this phase:

```
{{DIFF_STAT_PATH}}   what changed, by file — read this first, it is your agenda
{{DIFF_PATH}}        the diff itself
```

**You are reviewing a change, not surveying a codebase.** Do not re-explore the
repository: no repository-wide greps, no `find`, no reading files the diff does
not touch, and no `git diff` of your own. The previous run of this phase spent
118 commands and 730 KB of output to produce 1.8 KB of comments, almost all of it
rediscovering a repository that three earlier phases had already read.

When a hunk genuinely cannot be judged from its own context — you need the rest
of a function, or the caller — open *that file* at *that range* (`sed -n`,
`rtk read -n`). That is a handful of targeted reads across a review, not a sweep.

Judge against `{{RUN_DIR}}/explore.md`, `{{BRIEF_PATH}}`, and the OpenSpec
scenarios for `{{CHANGE}}` — correctness is correctness *against the requirement*,
not merely internal consistency. The engineering practices and testing standards
appended at the end of this prompt are the bar the diff is measured against; a
violation of either is a finding. Those three, plus the diff, are the whole input
set; you have everything you need to start.

## What to look for

- Correctness against every OpenSpec scenario, including the ones with no test.
- Regressions, unhandled edge cases, and error paths that silently swallow.
- Authorization, club/tenancy isolation, monetary units (kVND), migrations,
  and backward compatibility. Treat all five as high-risk.
- Cross-stack contract drift: request/response types, casing conversion,
  `Club-ID` handling, nullability, enums, date/time, error semantics.
- Tests that cannot fail — the false-positive test is the most expensive defect
  to find later, because it advertises coverage that does not exist.
- Accidental files: generated output, secrets, local environment files, debris
  from your own debugging, anything unrelated to this change.

## What to write

Write your comments to `{{RUN_DIR}}/review-comments.md`, in severity order, one
section per finding:

```markdown
### <critical|important|minor> — <file>:<line> — <one-line title>

What is wrong, why it is wrong against the requirement, and what the fix should
be. Name the test that is missing, if one is.
```

Raise only what is worth changing. A genuinely minor nit belongs in the file
marked `minor` — the resolving phase is told to leave those alone unless they are
free — not as a paragraph of prose.

If the diff is sound and there is nothing to change, write exactly `NONE` as the
first line of the file and nothing else. That is a real outcome, and the pipeline
reads it: it skips the resolving agent entirely and goes straight to verification.

## Boundaries

Do not edit code, tests, specs, or configuration. Do not sync specs, archive,
push, or open a pull request. The only file you write is
`{{RUN_DIR}}/review-comments.md` and your `result.json`.
