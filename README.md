# DAGU — three task DAGs, one GitHub issue, one merged pull request

File an issue and label it `agent:todo`. Three task DAGs move it the rest of the
way: clarify requirements, implement the result, then resolve review feedback
or tidy up after the merge.

Three scheduled DAGs own the three lifecycle phases. Each DAG polls, claims and
processes its own work directly; there are no dispatcher or child-agent DAGs.
The **issue label is the interface between phases** — a phase claims work by
taking a label and hands it on by setting a different one.

The coding-agent CLI is selected once in `agent.yaml`:

```yaml
agent: codex
```

Change it to `agent: claude` to switch every AI-backed stage, then restart the
worker. Both CLIs are installed in the worker image and use the host credentials
mounted by Compose.

The same file maps three **model tiers** — `fast`, `standard`, `deep` — to a
concrete model for each agent. A DAG step asks for a tier, never a model, so
switching the agent above leaves every step valid:

```yaml
model_claude_deep: opus
model_codex_deep: default     # `default` means "pass no model flag"
effort_codex_deep: high       # codex expresses depth as reasoning effort
```

## Start it

```bash
make up        # build and start dagu + worker in Docker
make worker    # optionally follow the worker logs
make health    # prove the worker is reachable, tooled and logged in
make labels    # create the agent:* labels on the repo
make state     # see where every open issue currently sits
```

Web UI: <http://localhost:8525>

Both services are required, and `make up` starts both. The `dagu` service holds
the schedule and history; the `worker` service does all the work.

## The state machine

```
   you file an issue
          │
          ▼
   ┌─ agent:todo ─────────────┐  clarify poller, every 5 min
   │                          ▼
   │                  agent:clarifying ──── questions ───▶ agent:revising
   │                          │                                  │
   │                     clear enough                      you answer and
   │                          │                          relabel agent:todo
   │                          ▼                                  │
   └──────────────── agent:ready-to-implement ◀───────────────────┘
                              │                implement poller, every 10 min
                              ▼
                     agent:implementing
                              │  opens a PR, ready for review
                              ▼
                     agent:reviewing ◀──────────────┐  delivery poller, 10 min
                              │                     │
              ┌───────────────┴───────────────┐     │
     you leave review comments          PR merged   │
              │                               │     │
              ▼                               ▼     │
      agent:responding ──── pushes fixes ─────┼─────┘
                                              ▼
                                       agent:finished
```

| Label | Who holds it | Meaning |
|---|---|---|
| `agent:todo` | queue | Filed. The clarifier takes the oldest every 5 min. |
| `agent:clarifying` | clarifier | Being read. Nothing else can touch it. |
| `agent:revising` | **you** | Questions are waiting in a comment. Answer them, then relabel `agent:todo`. |
| `agent:ready-to-implement` | queue | Clarified. The implementer takes the oldest every 10 min. |
| `agent:implementing` | implementer | Being built. |
| `agent:reviewing` | **you** | A pull request is open and ready for your review. |
| `agent:responding` | responder | Your review comments are being addressed. |
| `agent:finished` | terminal | Merged, issue closed, worktree reclaimed. |
| `agent:failed` | **you** | A run broke. The comment says where. |

### The label is the lock

There is no mutex, no queue table, and no shared state between the agents. Each
poller queries exactly one label, and claims an issue by swapping that label for
its own working label before doing any work. From that moment the issue is
invisible to every poller including the one that took it, so two agents cannot
collide on the same issue — and you can move an issue anywhere in the pipeline
by editing its label from the GitHub UI.

`bin/relabel.sh` performs the claim and refuses if the issue is not in the state
it expected. That is a check-then-act, not a compare-and-swap — GitHub has no
conditional label write. The gap is closed by there being exactly one poller per
label, and `overlap_policy: skip` on each poller so it never runs concurrently
with itself. The guard exists for the cases that do happen: you relabelling by
hand mid-poll, or a stale dispatch landing after the state moved on.

### The markers

Agents hand facts to each other through hidden HTML comments, because there is
nowhere else durable to put them:

| Marker | Written by | Read by |
|---|---|---|
| `<!-- agent:brief -->` | clarifier, on the issue | implementer — this comment *is* the spec, in preference to the issue body |
| `<!-- agent:pr=N -->` | implementer's report step, on the issue | delivery poller — how it finds the pull request |
| `<!-- agent:responded -->` | responder, on the PR | delivery poller — the timestamp "new since" is measured against |

The third one solves a problem worth knowing about: the agent runs as **your**
`gh` login, so every comment it writes carries your name. "Did a human write
this?" cannot be answered from the author, so `bin/pr-triage.jq` answers it from
that marker instead.

The same file also treats a review thread as outstanding only when its newest
comment is newer than the marker. Without that, a thread the responder replied to
but deliberately left unresolved — because it disagreed — would re-trigger the
responder every ten minutes forever.

## Why two services

The coordinator and worker remain separate processes, but Compose now manages
both. The worker image carries the coding-agent CLIs and development tools. It
uses explicit mounts for the target repository, Docker socket, Git identity,
SSH keys, GitHub CLI auth, coding-agent auth/skills, and the target repository's
worktree directory.

```
┌─ dagu service ────────────┐          ┌─ worker service ─────────────┐
│ dagu start-all            │          │ dagu worker                  │
│  • scheduler (cron)       │◀─ gRPC ──│  --worker.labels host=true   │
│  • web UI      :8525      │          │  codex/claude, gh, git, jq, │
│  • coordinator :50055     │          │  make, docker, repositories  │
└───────────────────────────┘          └──────────────────────────────┘
```

All three task DAGs set `worker_selector: {host: "true"}`, at DAG level, so
every step runs on the worker. The coordinator ships task definitions over gRPC
and the worker streams logs back. The project mount exists for scripts, prompts,
and configuration referenced by absolute path within those definitions.

### Credential mounts

Compose forwards the existing host login rather than copying secrets into the
image. `make up` reads the GitHub token from the macOS Keychain through
`gh auth token` and injects it into the worker runtime; Codex and Claude use
their mounted credential files. At startup the worker writes the token into its
own Linux-local GitHub CLI configuration because Dagu steps do not inherit every
worker environment variable. Agent configuration, skills, Git config, and SSH
keys are read-only. Anyone able to control a workflow can still execute commands
with those credentials, so keep the web UI bound to localhost and treat the
worker as trusted local infrastructure.

## Files

```
compose.yaml                          dagu container
service.yaml                          named queue concurrency limits
Makefile                              every command you need
agent.yaml                            global coding-agent selection
project.env                          shared repository, workspace and skill defaults

dags/clarify-task.yaml                poll -> claim -> clarify -> report
dags/implement-clarified-task.yaml    poll -> claim -> seven phases -> report
dags/resolve-code-review.yaml         poll -> triage -> respond | finish
dags/check-health.yaml                host worker health check

prompts/clarify-issue.md              the headless prompts, each with its own
prompts/respond-review.md             result.json exit contract
prompts/implement/_preamble.md        shared by every implementation phase
prompts/implement/{explore,propose,   one per phase of the implementation
  code,fix-verify,review,sync,
  pr-body}.md

bin/relabel.sh                        guarded claim: swap FROM -> TO
bin/set-state.sh                      unguarded report: force exactly one state
bin/pick-oldest.sh                    read a queue label, pick the oldest issue
bin/triage-issue.sh                   issue -> pull request -> decision
bin/pr-state.sh                       GraphQL dump of one pull request
bin/pr-triage.jq                      the respond/close/idle decision
bin/review-digest.jq                  outstanding feedback, as markdown

bin/implement/state.sh                the run's shared state.json, read and write
bin/implement/claim-ready-issue.sh    take the oldest ready issue
bin/implement/fetch-issue-brief.sh    derive slug, branch, worktree, change name
bin/implement/announce-start.sh       say on the issue that work has begun
bin/implement/create-worktree.sh      git worktree add, deterministically
bin/implement/build-prompt.sh         preamble + phase prompt, placeholders filled
bin/implement/run-phase.sh            prompt -> agent at a model tier -> contract
bin/implement/check-phase-result.sh   enforce one phase's exit contract
bin/implement/run-verification.sh     the target repo's own test/lint/build set
bin/implement/archive-change.sh       openspec archive --yes, then validate
bin/implement/open-pull-request.sh    verify origin, commit, push, gh pr create
bin/implement/report-outcome.sh       comment the outcome, name the failed phase

run-agent.sh                          configured agent + tier + live streaming
render-agent-stream.jq                shared Claude/Codex stream renderer

data/  logs/                          runtime state (gitignored)
```

DAG discovery is **not recursive** — `dags/` must stay flat.

## The implementation phases

Implementation used to be a single agent step: one prompt, a two-hour timeout,
one $15 budget, and nothing in the run view to say whether it was exploring,
writing code, or stuck. A run that died reported one undifferentiated failure and
the next attempt started from nothing.

It is now the skill's own phases, one step each:

| Step | Kind | Tier | Budget | Timeout |
|---|---|---|---|---|
| `claim_ready_issue` | shell | — | — | — |
| `fetch_issue_brief` | shell | — | — | — |
| `announce_start_on_issue` | shell | — | — | — |
| `create_feature_worktree` | shell | — | — | — |
| `explore_codebase_context` | agent | fast | 1 | 15m |
| `write_openspec_proposal` | agent | standard | 2 | 15m |
| `write_code_and_tests` | agent | **deep** | 7 | 75m |
| `run_verification_suite` | shell | — | — | 40m |
| `fix_failing_checks` | agent | deep | 2 | 40m |
| `rerun_verification_suite` | shell | — | — | 40m |
| `review_and_fix_diff` | agent | **deep** | 3 | 30m |
| `verify_after_review_fixes` | shell | — | — | 40m |
| `sync_openspec_specs` | agent | fast | 1 | 15m |
| `archive_openspec_change` | shell | — | — | 10m |
| `write_pr_description` | agent | fast | 1 | 15m |
| `push_and_open_pull_request` | shell | — | — | 15m |
| `report_outcome_on_issue` | shell | — | — | — |

The steps are one line each because their bodies live in `bin/implement/` and
their prompts in `prompts/implement/`. This DAG only says what order things
happen in; changing what a phase *does* means editing a script or a prompt.

**Phases hand off through files, not through a session.** Each is a separate
one-shot agent process with no memory of the last one. Everything durable is on
disk: `state.json`, the worktree, and the OpenSpec change directory. That is what
lets a single phase be re-run on its own against a run directory that already
exists:

```bash
make phase ISSUE=42 PHASE=review     # re-run just the review, keeping everything else
make verify ISSUE=42                 # re-run just the checks
```

**Identity is decided in shell, before any agent runs.** `fetch_issue_brief`
derives the slug, branch (`feature/42-<slug>`), worktree path and OpenSpec change
name from the issue and writes them to `state.json`. Previously the agent invented
all four inside the opaque step, so nothing outside it could address them — which
is precisely why the work could not be split. Each phase also stamps its name on
`state.json`, so when a run is killed the report says which phase it died in and
what survives on disk.

**Deterministic phases have no model behind them.** The worktree, the verification
commands, the archive, the push and the pull request are exact, checkable
operations. `run_verification_suite` runs the target repository's own
`make test-ci-migrations`, `make test-ci` and — only when `sweatcharge_fe/`
changed — `yarn lint`, `yarn test:unit` and `yarn build`. Running them from shell
turns the skill's rule that a frontend build must come from the *final* source
state into a second step in the graph rather than a promise an agent has to keep
two hours into a run.

`resolve-code-review` owns both response and cleanup because both start from
`agent:reviewing`. It inspects each pull request once and follows the appropriate
conditional branch. Cleanup remains deterministic and does not invoke a model.

The closer is the one agent with no model behind it. Closing an issue and
removing a worktree are exact, checkable operations; a language model could only
make them less reliable and more expensive.

## Manual runs

Each stage can be run on demand. Queue selection is bypassed, but clarification
and implementation still perform their normal guarded label claim:

```bash
make clarify   ISSUE=42
make implement ISSUE=42
make respond   ISSUE=42
make close     ISSUE=42
```

Implementation can also be resumed one phase at a time, against the run directory
a previous attempt left behind. This is the point of the file-based handoff — it
was impossible while implementation was a single step:

```bash
make phase  ISSUE=42 PHASE=review          # tier defaults to deep
make phase  ISSUE=42 PHASE=code TIER=deep BUDGET=7
make verify ISSUE=42                       # just the test/lint/build suite
```

`dagu start` runs a DAG **locally**; only the queue dispatches to the worker.
That is why `make health` uses `dagu enqueue` while these use `dagu start` — the
latter runs on this Mac, which already has the toolchain.

The review DAG discovers the pull request from the issue's `agent:pr` marker and
decides whether to respond or finish it.

## When nothing is happening

1. `make state` — where is the issue, and is it labelled at all?
2. `make health` — fails on the exact broken step.
3. Is the worker healthy in `docker compose ps` and `make worker`?
4. `make logs`, or the run history at <http://localhost:8525>.

An issue with no `agent:*` label is invisible to every poller. Only the
agent-feature issue template applies `agent:todo`, so a blank issue or a plain
`gh issue create` lands unlabelled — the clarify poller logs a hint listing them.

`agent_auth` failing means the selected CLI's mounted host credential is missing
or expired. Authenticate the CLI on the host, run `make up` to recreate the
worker with the current credentials, then run `make health` again.

## Unsticking a killed run

Each agent DAG has a failure handler that moves a working label to `agent:failed`
if the run dies, so a stuck issue should be rare. If one is genuinely pinned to
`agent:clarifying`, `agent:implementing` or `agent:responding` with no run behind
it, move it back by hand — the label is the only state there is:

```bash
gh issue edit <N> --repo cuongkane/sweatcharge \
  --remove-label agent:implementing --add-label agent:ready-to-implement
```

The pollers log anything sitting in a working label on every tick, with the time
it was last touched, so a corpse shows up in the run view within ten minutes.

Orphaned worktrees are reclaimed by the closer when its pull request merges. To
clear one from a run that never got there:

```bash
git -C /Users/lexuancuong/CUONG/SWC worktree list
git -C /Users/lexuancuong/CUONG/SWC worktree remove ../SWC-worktrees/<slug>
```

Working files from every run are kept under `/tmp/dagu-agent/<issue>/<stage>/`
(`brief.md`, `prompt.md`, the raw agent JSONL stream, `result.json`, `report.md`).

## Watching an agent work

Every coding-agent step streams a readable view into its stdout log, so the run view at
<http://localhost:8525> fills in live rather than sitting empty for the whole run:

```
session 63bd10ab-...  agent=codex
-> Bash {"command":"git worktree add ...","description":"..."}
-> Edit {"file_path":"...","old_string":"..."}
   tool error: Exit code 1
== success  turns=47  cost_usd=3.81  2913s
```

The surrounding orchestration steps also emit compact operational summaries:
the selected issue and title, label transitions, clarification question counts,
review-feedback counts, pull-request details, final outcome, and elapsed time.
Queue polls explicitly say when there is no work, so an idle run is distinguishable
from a silent or failed one.

The dispatcher selects the provider-specific JSONL mode (`--json` for Codex or
`--output-format stream-json` for Claude). The raw event stream is teed to
`agent-stream.jsonl` for debugging; stderr stays a separate pane, because a
non-JSON warning mixed into stdout would abort the `jq` renderer.

All of that lives in `run-agent.sh`, so the selection and streaming behavior
reach all three agents.

## Using another repository

Change the five values in `project.env`: repository, local workspace, and the
three coding-agent skills. All three DAGs and the Makefile load that single
project configuration. Then run `make labels` for the target repo.

## Known constraints

- **The agents run with `--permission-mode bypassPermissions`** — unrestricted
  shell as you, which is what makes them unattended. The containment is that
  none of them merges anything, and the closer only acts on a pull request
  GitHub reports as already merged. `--max-budget-usd` caps spend, not blast
  radius: 4 for clarify, 8 for respond, and a per-phase budget for implement
  (1 explore, 2 propose, 7 code, 2 fix, 3 review, 1 sync, 1 write-up) totalling
  17. Splitting implementation into phases means several fresh agents re-read the
  repository instead of one accumulating context, so expect the first runs to
  cost more than the old single $15 step until the tiers and budgets are tuned.
- **Two implementations at a time.** Each `implement-clarified-task` run claims
  one issue and exposes its full processing sequence as top-level DAG steps.
  Scheduled runs use the `implementation` queue, whose service-level
  `max_concurrency` is 2; `overlap_policy: all` lets another tick claim a
  different ready issue while the first run is active. Each run works in its
  own git worktree, and the target repo's `make test-ci` stack is
  namespaced per checkout (`swc-test-<hash>`) and publishes no host ports, which
  is what makes concurrent suites safe. Raise the queue limit only if the Mac
  has the RAM for that many Docker test stacks and coding-agent processes.
- **Clarification and review are not serialised** with implementation, and do not
  need to be. A long build no longer blocks a question being asked.
- **The Mac must be awake.** A polling scheduler does nothing while asleep.
- **The clarifier can be wrong.** It decides whether a human is needed, and a
  premature `agent:ready-to-implement` produces a confident pull request built on
  a guess. Its brief is posted on the issue before the implementer starts, so
  that judgement is reviewable — and relabelling to `agent:todo` re-runs it.
