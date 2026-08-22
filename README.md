# DAGU — four task DAGs, one GitHub issue, one merged pull request

File an issue and label it `agent:todo`. Four task DAGs move it the rest of the
way: clarify requirements, implement the result — through one of two pipelines,
depending on what the work turns out to be — then resolve review feedback or tidy
up after the merge.

Four scheduled DAGs own the lifecycle. Each DAG polls, claims and processes its
own work directly; there are no dispatcher or child-agent DAGs. The **issue label
is the interface between phases** — a phase claims work by taking a label and
hands it on by setting a different one.

**Implementation forks in two.** Clarification sizes the work as well as
clarifying it, and promotes the issue to one of two ready labels. A `major` task —
one that introduces new product meaning — gets the full pipeline: explore, write
an OpenSpec proposal, implement, test, verify, review, sync the specs, archive,
verify again, ship. A `minor` task — a defect fix, a copy or layout correction, a
missing guard — gets code, tests, verify, ship. Nine agent phases against three.
The fork exists because writing a specification before writing code is right for a
feature and pure waste for a wrong label on a card. See
[The two implementation flows](#the-two-implementation-flows).

The coding-agent CLI is selected once in `agent.yaml`:

```yaml
agent: codex
```

Change it to `agent: claude` or `agent: opencode` to switch every AI-backed
stage, then restart the worker. All three CLIs are installed in the worker image
and use the host credentials mounted by Compose — except Claude Code, whose
macOS login lives in the Keychain and which therefore carries its own token; see
[Credential mounts](#credential-mounts).

The same file maps three **model tiers** — `fast`, `standard`, `deep` — to a
concrete model for each agent. A DAG step asks for a tier, never a model, so
switching the agent above leaves every step valid:

```yaml
model_claude_deep: opus
model_codex_deep: gpt-5.6-sol
effort_codex_deep: high          # codex also uses reasoning effort
model_opencode_deep: deepseek/deepseek-v4-pro   # `provider/model`
variant_opencode_deep: default   # its depth axis is `--variant`
```

Leave `default` in place for claude if you want its CLI-configured model. Pin
the codex tiers to the intended GPT-5.6 model and **pin the opencode tiers to a
real model**. Left to itself opencode picks one, and the model it picks may be
reachable only through a route with no tool-calling endpoints — which fails every
phase on its first turn with `No endpoints found that support tool use`. The
provider prefix decides this: `deepseek/…` is the DeepSeek API direct and
supports tools, `openrouter/deepseek/…` is the same model through a route that
does not. `opencode models` lists what the current login can reach.

Only Claude Code enforces the per-phase spend cap the DAGs pass in; codex and
opencode have no such flag, so for those two the cap is recorded in the run log
and in the usage table but nothing holds the run to it.

## Setup on a new machine

Order matters: credentials land before `make up` reads them.

### Prerequisites (host)

```bash
brew install gh dagu   # gh for the token and issue/label ops; dagu for `make validate`
gh auth login          # host GitHub token, read by `make up`
```

Docker (Desktop or `brew` + colima) with the Compose plugin must already be
running.

### 1. Point it at the target repository

Copy `.env.example` to `.env` and fill in the four absolute paths for this
machine — this repository's own path, the target repository, the worktrees
directory it creates worktrees under, and the dotfiles checkout:

```ini
DAGU_ROOT=/absolute/path/to/DAGU
PROJECT_WORKSPACE=/absolute/path/to/target/repo
PROJECT_WORKTREES_DIR=/absolute/path/to/target/repo-worktrees
DOTFILES_DIR=/absolute/path/to/dotfiles
```

`.env` is gitignored, read automatically by `docker compose`, and exported by
the Makefile for host-side `dagu` commands — `compose.yaml` and the DAG
definitions under `dags/` need no per-host edits.

Then edit `project.env`:

```ini
PROJECT_REPO=owner/repo
PROJECT_WORKSPACE=/absolute/path/to/target/repo
```

`PROJECT_WORKSPACE` is repeated here because `project.env` is a plain dotenv
file with no variable expansion of its own — keep the two values identical.

### 2. Coding-agent credential

Choose the agent in `agent.yaml` (`agent: opencode` etc.), then authenticate that
CLI **on the host** so its credential file rides the existing mount:

- **opencode**: `opencode auth login -p openrouter` writes
  `~/.local/share/opencode/auth.json` (mounted). The
  `~/.config/opencode/opencode.jsonc` provider pins for discounted OpenRouter
  routing ride the `:ro` config mount; copy that file over too.
- **codex**: `codex login` writes `~/.codex/auth.json` (mounted).
- **claude**: the macOS login lives in the Keychain, invisible to Linux, so
  generate a separate token and store it where `run-agent.sh` looks:

  ```bash
  claude setup-token          # in your own terminal, not inside a Claude session
  scripts/set-agent-token.sh  # paste the token (hidden input) → .secrets/claude-oauth-token
  ```

### 3. Model tiers

Set the three tiers in `agent.yaml` (fast/standard/deep). For opencode, keep the
`openrouter/` prefix and confirm each model reports tool support with
`opencode models --verbose` — every phase is nothing but tool calls.

### 4. Start and verify

```bash
make up        # build and start dagu + worker in Docker
make labels    # create the agent:* labels on the repo
make health    # prove the worker is reachable, tooled and logged in
```

`make health` fails on the exact broken step, each of which checks one thing:
`tools` (the binaries), `github_auth`, and `agent_auth`.

Caveats:

- `make up` reads `gh auth token`, so `gh` must be authenticated first; the
  worker materializes it into a Linux-local `gh` config at startup.
- `~/.config/opencode` is mounted read-only; provider pins ride it live, no
  restart. `auth.json` mounts are writable because tokens refresh in place.
- `~/.ssh` is mounted read-only — the host needs the target repo's SSH access
  before the first run.

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
   │                clear enough, and sized                you answer and
   │                          │                          relabel agent:todo
   │            ┌─────────────┴─────────────┐                    │
   │            ▼                           ▼                    │
   │  agent:major-task:        agent:minor-task:                 │
   └─ ready-to-implement       ready-to-implement ◀──────────────┘
                │                           │
     major poller, :00/:10       minor poller, :05/:15
     9 agent phases              3 agent phases
                └─────────────┬─────────────┘
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
| `agent:major-task:ready-to-implement` | queue | Clarified, and it needs a specification. The major implementer takes the oldest every 10 min. |
| `agent:minor-task:ready-to-implement` | queue | Clarified, and its requirements are already settled. The minor implementer takes the oldest every 10 min, offset by 5. |
| `agent:implementing` | either implementer | Being built. Both flows claim into this one label, so nothing downstream can tell them apart. |
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

`scripts/relabel.sh` performs the claim and refuses if the issue is not in the state
it expected. That is a check-then-act, not a compare-and-swap — GitHub has no
conditional label write. The gap is closed by there being exactly one poller per
label, and `overlap_policy: skip` on each poller so it never runs concurrently
with itself. The guard exists for the cases that do happen: you relabelling by
hand mid-poll, or a stale dispatch landing after the state moved on.

**This is why the two implementation queues are separate labels rather than one
label plus a size field.** The label *is* the lock, so two pollers watching one
label would read it at the same instant, both see the issue, and both claim it —
the exact race the design has no mutex to arbitrate. Disjoint labels mean each
implementer is the only poller on its own queue, and the invariant above holds
unchanged. They converge again immediately: both claim into `agent:implementing`,
so every step after the claim is shared.

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
this?" cannot be answered from the author, so `scripts/pr-triage.jq` answers it from
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
┌─ dagu service ────────────┐          ┌─ worker service ───────────────┐
│ dagu start-all            │          │ dagu worker                    │
│  • scheduler (cron)       │◀─ gRPC ──│  --worker.labels host=true     │
│  • web UI      :8525      │          │  codex/claude/opencode, gh,    │
│  • coordinator :50055     │          │  git, jq, make, docker, repos  │
└───────────────────────────┘          └────────────────────────────────┘
```

All three task DAGs set `worker_selector: {host: "true"}`, at DAG level, so
every step runs on the worker. The coordinator ships task definitions over gRPC
and the worker streams logs back. The project mount exists for scripts, prompts,
and configuration referenced by absolute path within those definitions.

### Credential mounts

Compose forwards the existing host login rather than copying secrets into the
image. `make up` reads the GitHub token from the macOS Keychain through
`gh auth token` and injects it into the worker runtime; Codex and opencode use
their mounted credential files (`~/.codex/auth.json` and
`~/.local/share/opencode/auth.json`). For opencode that file holds only what was
added with `opencode auth login`; a provider authenticated by an environment
variable (DeepSeek's `DEEPSEEK_API_KEY`, say) never reaches the worker. Claude
Code is the exception: on macOS it
keeps its login in the Keychain, so there is no file to mount and the worker
carries a separate `claude setup-token` token written by
`scripts/set-agent-token.sh`, revocable on its own.

At startup the worker writes the GitHub token into its
own Linux-local GitHub CLI configuration because Dagu steps do not inherit every
worker environment variable. Agent configuration, skills, Git config, and SSH
keys are read-only. Anyone able to control a workflow can still execute commands
with those credentials, so keep the web UI bound to localhost and treat the
worker as trusted local infrastructure.

## Files

```
compose.yaml                             dagu container
service.yaml                             named queue concurrency limits
Makefile                                 every command you need
agent.yaml                               global coding-agent selection
project.env                              shared repository, workspace and skill defaults

dags/clarify-task.yaml                   poll -> claim -> clarify + size -> report
dags/implement-clarified-task.yaml       the major flow: nine agent phases
dags/implement-minor-clarified-task.yaml the minor flow: code, tests, verify, ship
dags/resolve-code-review.yaml            poll -> triage -> respond | finish
dags/check-health.yaml                   host worker health check

prompts/clarify-issue.md                 the headless prompts, each with its own
prompts/respond-review.md                result.json exit contract
prompts/implement/_preamble.md           shared by every implementation phase
prompts/implement/{explore,propose,      one per phase of the major flow
  code,tests,fix-verify,review,
  resolve-review,sync,pr-body}.md
prompts/implement/minor/{code,tests}.md  the minor flow's own, where sharing the
                                         major prompt would be wrong
prompts/implement/_minor.md              appended instead, for a shared phase with
                                         no minor variant of its own
prompts/standards/                       the engineering practices and testing
  engineering-practices.md               standards, owned here and pasted into
  testing-standards.md                   the prompts of the phases held to them

scripts/standards.sh                     print the standards appendix for a prompt
scripts/relabel.sh                       guarded claim: swap FROM -> TO
scripts/set-state.sh                     unguarded report: force exactly one state
scripts/pick-oldest.sh                   read a queue label, pick the oldest issue
scripts/triage-issue.sh                  issue -> pull request -> decision
scripts/pr-state.sh                      GraphQL dump of one pull request
scripts/pr-triage.jq                     the respond/close/idle decision
scripts/review-digest.jq                 outstanding feedback, as markdown

scripts/implement/state.sh               the run's shared state.json, read and write
scripts/implement/claim-ready-issue.sh   take the oldest issue off one ready queue
scripts/implement/fetch-issue-brief.sh   derive slug, branch, worktree, change name,
                                         and record which flow claimed it
scripts/implement/announce-start.sh      say on the issue that work has begun
scripts/implement/create-worktree.sh     git worktree add, deterministically
scripts/implement/install-frontend-deps.sh
                                         yarn install in the worktree, flock'd,
                                         before any agent needs node_modules
scripts/implement/write-conventions.sh   every CLAUDE.md/AGENTS.md, concatenated once
scripts/implement/build-prompt.sh        preamble + the phase prompt for this flow
                                         + standards, placeholders filled
scripts/implement/write-diff.sh          the branch diff, for the phases that judge it
scripts/implement/run-phase.sh           prompt -> agent at a model tier -> contract
scripts/implement/check-phase-result.sh  enforce one phase's exit contract
scripts/implement/run-verification.sh    the target repo's own test/lint/build set
scripts/implement/run-ci-until-passing.sh
                                         run it, fix what fails, repeat
scripts/implement/resolve-review-comments.sh
                                         act on review/review-comments.md
scripts/implement/summarize-run.sh       tokens and duration, phase by phase
scripts/implement/finalize-openspec-change.sh
                                         sync the specs, then archive the change
scripts/implement/archive-change.sh      openspec archive --yes, then validate
scripts/implement/ship-code.sh           assemble a minimal PR body, then open the PR
scripts/implement/open-pull-request.sh   verify origin, commit, push, gh pr create
scripts/implement/report-and-recover.sh  report the outcome, then never leave the
                                         issue on agent:implementing
scripts/implement/report-outcome.sh      comment the outcome, name the failed phase
scripts/implement/recover-stranded-label.sh
                                         the fallback when reporting itself failed

run-agent.sh                             configured agent + tier + live streaming
render-agent-stream.jq                   shared Claude/Codex/opencode renderer

data/  logs/                             runtime state (gitignored)
```

DAG discovery is **not recursive** — `dags/` must stay flat.

## The two implementation flows

Clarification decides which. Its agent answers two questions rather than one — is
this implementable unattended, and does building it need a written specification —
and the second answer picks the label, and so the pipeline.

Sizing lives there because that is the only phase that has read the requirements
and not yet spent anything on the implementation. Asking later would mean either
an extra agent run whose entire purpose is to discover that a change is cheap, or
you applying a label by hand. Asking there costs nothing: the clarifier has
already read the repository in order to write the brief.

**`minor` is the answer only when the requirements are already settled** — when
implementing the issue introduces no new product meaning, because it makes the
code do what the brief, or an existing specification, already says it should. No
API contract change, no migration, no authorization or tenancy change, no
monetary logic, no new or redefined requirement, and confined to a handful of
files. A wrong label, a missing null guard, an off-by-one, copy text, a wrong
default.

**`major` is the answer to everything else, and to everything uncertain.** The
asymmetry is deliberate and it is stated in the clarifier's prompt: `major` on a
small fix wastes an exploration and a proposal, while `minor` on a real feature
reaches a pull request with no specification behind it, no automated review, and
the main specs silently describing a product that no longer exists. Every
malformed or missing `size` — an older clarifier, a misspelling — routes to
`major` for the same reason.

## The implementation phases

Implementation used to be a single agent step: one prompt, a two-hour timeout,
one $15 budget, and nothing in the run view to say whether it was exploring,
writing code, or stuck. A run that died reported one undifferentiated failure and
the next attempt started from nothing.

It is now the skill's own phases, one step each. The two flows are two DAGs over
one set of scripts:

| Step | Kind | major | minor |
|---|---|---|---|
| `claim_ready_issue` | shell | ✓ | ✓ |
| `fetch_issue_brief` | shell | ✓ | ✓ |
| `announce_start_on_issue` | shell | ✓ | ✓ |
| `create_feature_worktree` | shell | ✓ | ✓ |
| `install_frontend_dependencies` | shell | ✓ | ✓ |
| `explore_codebase_context` | agent | fast $1, 15m | — |
| `write_openspec_proposal` | agent | standard $2, 15m | — |
| `write_implementation_code` | agent | **deep** $5, 60m | standard $2, 40m |
| `write_tests_until_passing` | agent | **deep** $4, 60m | standard $2, 40m |
| `run_ci_until_passing` | shell + agent | standard $2 × 2, 2h | standard $2 × 2, 2h |
| `review_code` | agent | **deep** $3, 30m | — |
| `resolve_review_comment` | agent | **deep** $3, 60m | — |
| `finalize_openspec_change` | agent + shell | fast $1, 25m | — |
| `run_ci_before_ship` | shell + agent | standard $2 × 1, 2h | — |
| `ship_code` | shell | ✓ | ✓ |
| `summarize_run_usage` | shell | ✓ | ✓ |
| `report_run_outcome` | shell | ✓ | ✓ |

Nine agent phases against three, and the two expensive ones drop a model tier. A
change whose requirements are already settled does not need the model that
designs.

**Two DAGs, not one DAG with a branch.** `dags/implement-clarified-task.yaml` and
`dags/implement-minor-clarified-task.yaml` are separate files, and the reason is
the claim: the label is the lock, so a single DAG branching internally would still
need one poller per queue. Given that, two flat DAGs read better than one with six
conditionally-skipped steps — each is a linear list of what actually runs. The
cost is the shared head and tail written twice; that is bounded because both call
the same scripts in `scripts/implement/`, so the duplication is which steps in
what order, not what any of them do.

**`minor` runs the verification suite once, and that once is authoritative.** The
major flow runs it twice — early, so a deep review is not spent on a diff that
does not compile, and again after the spec sync, when every commit the branch will
ever have finally exists. On the minor flow nothing happens between the suite and
the push: no review to resolve, no specs to sync, no archive. So one run, and it
is both the gate and the verdict on the exact tree that ships.

**`minor` has no automated review, and its pull request says so.** There is no
`review_code` and no `resolve_review_comment`. `ship-code.sh` writes that into the
body in plain words, because a reviewer who assumes the pipeline already read the
diff reads it less carefully than one who knows they are first. Two things
compensate, both in the prompts: the `tests` phase is told it is the last phase
that will read the code and asked to read the whole diff once as a reviewer would
before reporting `done`, and the `code` phase is told to change nothing the brief
did not ask for, because every unrequested line spends a human's attention.

**Shared phases, different prompts.** `code`, `tests` and `fix-verify` run on both
flows, and they cannot be given the same instructions: a minor run has no
`explore.md`, no OpenSpec change, no `tasks.md` and no delta specs, so a prompt
that opens by telling the phase to read them is wrong. `build-prompt.sh` prefers
`prompts/implement/minor/<phase>.md` when one exists — `code` and `tests` have
purpose-written ones — and otherwise appends `prompts/implement/_minor.md`, a
short correction, to the major prompt. `fix-verify` is the one that takes the
correction. The alternative was patching every shared prompt with an addendum,
which produced prompts that spent a page arguing with themselves about which files
exist.

Which flow a run is on is read from `size` in `state.json`, written by
`fetch_issue_brief` from an argument the DAG passes. Nothing infers it from the
DAG it is running under, because the scripts are shared and `make phase` can
re-run any of them by hand.

**On the major flow the second suite run is the verdict**, and `run_ci_before_ship`
sits after the spec sync because that is the only point where every commit the
branch will ever have already exists. It used to be the tail of
`resolve_review_comment`, which ran it one sync too early — the frontend
production build the pull request claimed was not built from the tree that was
pushed.

The steps are one line each because their bodies live in `scripts/implement/` and
their prompts in `prompts/implement/`. The DAGs only say what order things happen
in; changing what a phase *does* means editing a script or a prompt, and it
changes both flows at once.

**The standards live here, not in a skill.** `prompts/standards/` holds the
engineering practices and testing standards, and `scripts/standards.sh` pastes
them onto the end of the prompts of the phases they govern: practices for `code`,
testing standards for `tests`, both for `review`, `resolve-review`, `fix-verify`
and the review-response agent. Every phase used to be told to "read the skill and
hold its standards", so each one spent a `SKILL.md`, four reference files and half
a dozen tool calls per run to obtain two pages of text that never change — and
the review responder reached across two skills to get the same two files. A phase
now starts already holding them. The coding-agent skills are still named where
their *workflow* is what is wanted; they are no longer read for standards.

**Phases hand off through files, not through a session.** Each is a separate
one-shot agent process with no memory of the last one. Everything durable is on
disk: `state.json`, the worktree, and — on the major flow — the OpenSpec change
directory. That is what lets a single phase be re-run on its own against a run
directory that already exists:

```bash
make phase ISSUE=42 PHASE=review     # re-run just the review, keeping everything else
make verify ISSUE=42                 # re-run the checks, fixing until they pass
make verify ISSUE=42 ATTEMPTS=1      # run the checks once and report, no model
```

**Identity is decided in shell, before any agent runs.** `fetch_issue_brief`
derives the slug, branch (`feature/42-<slug>`), worktree path and OpenSpec change
name from the issue and writes them to `state.json`. Previously the agent invented
all four inside the opaque step, so nothing outside it could address them — which
is precisely why the work could not be split. Each phase also stamps its name on
`state.json`, so when a run is killed the report says which phase it died in and
what survives on disk.

**`node_modules` is installed in shell, before any agent runs.** A git worktree
shares the repository but not ignored files, so it never has
`sweatcharge_fe/node_modules` however complete your own checkout is. Nothing used
to install it: `run-verification.sh` went straight to `yarn lint`, and a phase
that wanted a focused frontend test found nothing there either. So the first
phase needing the frontend improvised the install inside its own budget — on
issue #158 the `tests` phase spent six minutes on a cold `yarn install` and
reported `failed` without ever running the tests it had just written.

`install_frontend_dependencies` is that install, as its own step: the cost is wall
clock rather than model spend, and a failure says *the install broke* rather than
*the tests phase broke*. It runs unconditionally — which files a run will touch is
not known that early — and it is idempotent, so re-running a phase by hand against
an existing worktree costs one `test -f`. `run-verification.sh` calls the same
script again before the frontend checks, which covers `make verify` against a run
directory whose worktree was cleaned in between.

Two things make it survivable rather than merely correct. The Yarn Berry global
cache is on a **named volume** (`yarn-cache` in `compose.yaml`); it used to live on
the container's writable layer, so `make up --build` discarded it and the next
frontend run re-fetched the whole Angular tree. And the install holds an `flock`,
because `sweatcharge_fe` leaves `enableGlobalCache` at its default — every
worktree's install writes the one `~/.yarn/berry/cache`, and `service.yaml` allows
four runs at once in a single container. Two cold installs fetching the same
package concurrently is how yarn produces `YN0001: While persisting <cache entry>`.

**Deterministic phases have no model behind them.** The worktree, the dependency
install, the verification commands, the archive, the push and the pull request are
exact, checkable operations. `run-verification.sh` runs the target repository's own
`make test-ci-migrations`, `make test-ci` and — only when `sweatcharge_fe/`
changed — `yarn lint`, `yarn test:unit` and `yarn build`. Running them from shell
turns the skill's rule that a frontend build must come from the *final* source
state into a second step in the graph rather than a promise an agent has to keep
two hours into a run.

**Verification is one step that loops.** `run_ci_until_passing` runs the suite; if it
fails it runs the `fix-verify` phase and runs the suite again, up to three
attempts, and only its own exit status ends the run. It replaces an unrolled
run → fix → rerun chain gated on `verify.status` files, which allowed exactly one
fix and spent three lines of the run view saying so. The verdict stays in shell on
every attempt — the agent reacts to a failing suite, it never declares the suite
passed. Failed attempts are kept as `verify.<stage>-<n>.summary.log` so a long fight is
readable afterwards, and the fix prompt is told to read the previous one.

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
make clarify         ISSUE=42
make implement       ISSUE=42   # the major flow
make implement-minor ISSUE=42   # the minor flow
make respond         ISSUE=42
make close           ISSUE=42
```

The two implement targets claim from different labels, so the one you run has to
match the label clarification applied — `make state` shows which. Running the
wrong one is safe rather than destructive: the guarded claim finds the issue is
not on the queue it expected, prints what it is actually carrying, and stops
without touching it.

Implementation can also be resumed one phase at a time, against the run directory
a previous attempt left behind. This is the point of the file-based handoff — it
was impossible while implementation was a single step:

```bash
make phase  ISSUE=42 PHASE=review          # tier defaults to deep
make phase  ISSUE=42 PHASE=code TIER=deep BUDGET=7
make verify ISSUE=42                       # the test/lint/build suite, fixing until green
make verify ISSUE=42 ATTEMPTS=1            # the suite once, no fix agent
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

### codex: "failed to install system skills: Read-only file system (os error 30)"

Expected, and not the cause of whatever else went wrong in that run. `compose.yaml`
mounts `~/.codex/skills` and `~/.codex/plugins` read-only on purpose — they are
configuration, not state — and codex tries to remove and reinstall its system
skills directory on every invocation. It logs the error at `ERROR` level, three
times, and carries on. Ignore it and read further down the log.

`codex_models_manager: failed to refresh available models: timeout waiting for
child process to exit` is separate and also non-fatal: codex could not reach the
model list. It matters only if the tier you asked for then resolves to nothing, in
which case `agent.yaml` should pin the model explicitly rather than leaving it
`default`.

### opencode: "Unexpected server error. Check server logs for details."

An opencode phase that dies on its first turn with this message — no tokens, no
tool calls, about a second — is failing because the `provider/model` named in
`agent.yaml` is not reachable from the worker. The message is opaque on purpose:
the worker's `opencode.log` stays empty and the JSONL carries only
`{"type":"error","error":{"name":"UnknownError","data":{"message":"Unexpected
server error..."}}}`.

`make health` does **not** catch this: its `agent_auth` step runs `opencode run`
with no `--model`, so it proves a login works but not that the configured model
does. The fast diagnosis is a reachability check, host vs worker:

```bash
opencode models | grep -E '^(deepseek|openrouter)/'   # host
docker exec dagu-worker-1 opencode models | grep -E '^(deepseek|openrouter)/'
docker exec dagu-worker-1 opencode auth list
```

If the model from `agent.yaml` appears on the host but not in the worker, that is
the failure. `opencode auth list` shows why: providers logged in with
`opencode auth login` sit in `auth.json` (which is mounted), while a provider
authenticated only through an environment variable — DeepSeek's
`DEEPSEEK_API_KEY` is the usual case — exists only on the host. Dagu steps do not
inherit worker environment variables, so adding the key to `compose.yaml` does
not fix it.

The fix is to put the login in `auth.json` so it rides the existing mount:

```bash
opencode auth login -p deepseek
# or add {"deepseek":{"type":"api","key":"..."}} to ~/.local/share/opencode/auth.json by hand
```

No worker restart is needed — the `auth.json` bind mount is live. Confirm with

```bash
printf 'Reply with exactly OK' | docker exec -i dagu-worker-1 \
  opencode run --format json --auto --model deepseek/deepseek-v4-pro
```

A working model streams tokens and ends `OK`; a broken one returns the
`UnknownError` JSON at once. Any `provider/model` in `agent.yaml` must be a
provider present in `auth.json`, not one that only an environment variable
provides.

## Unsticking a killed run

Each agent DAG has a failure handler that moves a working label to `agent:failed`
if the run dies, so a stuck issue should be rare. If one is genuinely pinned to
`agent:clarifying`, `agent:implementing` or `agent:responding` with no run behind
it, move it back by hand — the label is the only state there is:

```bash
gh issue edit <N> --repo cuongkane/sweatcharge \
  --remove-label agent:implementing \
  --add-label agent:major-task:ready-to-implement
```

Use `agent:minor-task:ready-to-implement` instead to send it back to the short
flow. Either is a valid re-queue for a stranded issue — the label picks the
pipeline, so this is also how you overrule a sizing decision you disagree with
without re-running clarification.

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

The dispatcher selects the provider-specific JSONL mode (`--json` for Codex,
`--output-format stream-json` for Claude, `--format json` for opencode). The raw
event stream is teed to `agent-stream.jsonl` for debugging; stderr stays a
separate pane, because a non-JSON warning mixed into stdout would abort the `jq`
renderer.

opencode has no session-start event — every event carries the session id and
none announces it — so its session line is printed after the stream instead of
before it. Feed that id to `opencode export <session-id>` to re-read a finished
phase.

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
  (1 explore, 2 propose, 5 code, 4 tests, 3 review, 3 resolve-review, 1 sync)
  totalling 19 when nothing has to be fixed. The two fix loops are on
  top of that at 2 per attempt — up to 4 in `run_ci_until_passing` and 2 in
  `run_ci_before_ship` — so 26 is the worst case.
  Splitting implementation into phases means several fresh agents re-read the
  repository instead of one accumulating context, so expect the first runs to
  cost more than the old single $15 step until the tiers and budgets are tuned.
- **Input, not output, is what the pipeline spends.** A phase re-sends its whole
  context to the model on every step it takes, so a command that prints 100 KB is
  charged again on each of the steps that follow it. Issue #116 ran to 20.7M
  input tokens against 142k output. What holds it down is shell doing the reading
  — `write-conventions.sh` and `write-diff.sh` produce files the phases are
  pointed at, `run-verification.sh` writes a 1 KB summary beside its 300 KB log —
  and `rtk`, installed in the worker image, filtering whatever the agent runs
  itself. `summarize_run_usage` is how a regression in any of that gets noticed:
  it prints tokens, duration and command count per phase, and the same table is
  folded into the issue comment.
  The fix loop also reuses one agent session across its attempts: the first
  attempt's session id is passed back into the next, so it does not pay again to
  re-read the diff, conventions and standards it already loaded. That is the one
  place a session is continued — every phase boundary still starts fresh, so a
  single phase stays re-runnable on its own and the review keeps fresh eyes.
- **Several implementations at a time.** Each `implement-clarified-task` run
  claims one issue and exposes its full processing sequence as top-level DAG
  steps. Scheduled runs use the `implementation` queue, whose service-level
  `max_concurrency` is 4; `overlap_policy: all` lets another tick claim a
  different ready issue while the first run is active. Each run works in its
  own git worktree, and the target repo's `make test-ci` stack is
  namespaced per checkout (`swc-test-<hash>`) and publishes no host ports, which
  is what makes concurrent suites safe. Raise the queue limit only if the Mac
  has the RAM for that many Docker test stacks and coding-agent processes.
- **Clarification and review are not serialised** with implementation, and do not
  need to be. A long build no longer blocks a question being asked.
- **The Mac must be awake.** A polling scheduler does nothing while asleep.
- **The clarifier can be wrong, and now it makes two calls rather than one.** It
  decides whether a human is needed, and a premature promotion produces a
  confident pull request built on a guess. It also decides the size, and a feature
  mislabelled `agent:minor-task:ready-to-implement` is built with no proposal, no
  automated review and the main specs left describing the old behaviour. Both
  judgements are reviewable before anything is built: the brief is posted on the
  issue and the size is visible as a label. Relabelling to `agent:todo` re-runs
  the clarifier; relabelling to the other ready label overrules just the size. A
  minor run's pull request also says in its body that nothing reviewed it, which
  is the last place the mistake can be caught cheaply.
