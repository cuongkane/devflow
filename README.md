# DAGU — GitHub issue → autonomous implementation → draft PR

File an issue, label it `agent:todo`, and a Claude Code agent picks it up,
implements it, and opens a **draft** pull request. You review and merge.

## Start it

```bash
make up        # dagu scheduler + web UI + coordinator, in Docker
make worker    # host worker — FOREGROUND, keep this pane open (tmux)
make health    # prove the worker is reachable, tooled and logged in
```

Web UI: <http://localhost:8525>

Both are required. The container holds the schedule and history; the worker does
all the work. With the container alone, the schedule fires and nothing happens.

## Why two processes

The dagu container carries no tooling on purpose, and a Linux container cannot
read the macOS keychain — so a containerised `claude` would need an
`ANTHROPIC_API_KEY` and bill per token instead of using your subscription.

```
┌─ Docker ──────────────────┐          ┌─ macOS host (login session) ─┐
│ dagu start-all            │          │ dagu worker                  │
│  • scheduler (cron)       │◀─ gRPC ──│  --worker.labels host=true   │
│  • web UI      :8525      │  :50055  │                              │
│  • coordinator :50055     │          │  claude (keychain auth), gh, │
│                           │          │  git, jq, make, docker, repos│
└───────────────────────────┘          └──────────────────────────────┘
```

Both DAGs set `worker_selector: {host: "true"}` at DAG level, so every step runs
on the worker. Workers need no DAGs directory and no shared volume — the
coordinator ships task definitions over gRPC and the worker streams logs back.

## Labels are the state machine

| Label | Meaning |
|---|---|
| `agent:todo` | Queued. The poller picks the **oldest** one every 10 min. |
| `agent:in-progress` | Being worked on. Also the **mutex** — while any issue holds this, the poller starts nothing new. |
| `agent:done` | Draft PR opened; the URL is commented on the issue. |
| `agent:needs-input` | The agent hit a blocking question, posted as a comment. Answer it, then relabel `agent:todo`. |
| `agent:failed` | The run broke. The comment points at the working files. |

Because the label is the mutex, a scheduler restart cannot lose track, and you
can fix a stuck run from the GitHub UI.

## Files

```
compose.yaml                      dagu container
Makefile                          every command you need
dags/sweatcharge-poller.yaml      schedule + per-repo config
dags/agent-implement-issue.yaml   repo-agnostic implementer
dags/worker-health-check.yaml     host worker health check
prompts/implement-issue.md        the headless prompt
data/  logs/                      runtime state (gitignored)
```

DAG discovery is **not recursive** — `dags/` must stay flat.

## Adding another repository

`agent-implement-issue` takes `REPO`, `WORKSPACE`, `SKILL` and `ISSUE_NUMBER`, so
a second repo is one new poller file with different `consts`, plus
`make labels REPO=owner/name`. Point `SKILL` at whichever Claude Code skill
implements that codebase.

## Manual runs

```bash
make trigger ISSUE=42     # implement one issue now, bypassing the poll and the mutex
```

`dagu start` runs a DAG **locally**; only the queue dispatches to the worker.
That is why `make health` uses `dagu enqueue` while `make trigger` uses
`dagu start` — the latter runs on this Mac, which already has the toolchain.

## When nothing is happening

1. `make health` — fails on the exact broken step.
2. Is `make worker` still running? It does not survive a reboot or a closed pane.
3. Is an issue stuck on `agent:in-progress`? That blocks every poll (see below).
4. `make logs`, or the run history at <http://localhost:8525>.

`claude_auth` failing with `Not logged in` means the worker is outside your login
session and cannot reach the keychain. Run it from a normal terminal — a
LaunchDaemon will never work; a LaunchAgent can.

## Unsticking a killed run

A run killed mid-flight leaves the issue pinned to `agent:in-progress`, which
blocks every later poll, and an orphaned git worktree:

```bash
gh issue edit <N> --repo cuongkane/sweatcharge \
  --remove-label agent:in-progress --add-label agent:todo

git -C /Users/lexuancuong/CUONG/SWC worktree list
git -C /Users/lexuancuong/CUONG/SWC worktree remove ../SWC-worktrees/<slug>
```

Working files from the run are kept at `/tmp/dagu-agent/<issue-number>/`
(`brief.md`, `prompt.md`, `claude-output.json`, `result.json`).

## Known constraints

- **The agent runs with `--permission-mode bypassPermissions`** — unrestricted
  shell as you, which is what makes it unattended. The containment is that it
  only opens a *draft* PR and the skill forbids merging. `--max-budget-usd 15`
  caps spend, not blast radius.
- **One issue at a time.** `make test-ci` uses fixed Compose project and port
  names, so parallel runs would collide.
- **The Mac must be awake.** A polling scheduler does nothing while asleep.
