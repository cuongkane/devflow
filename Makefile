.DEFAULT_GOAL := help
.PHONY: help up down restart logs ps open worker validate health state \
        clarify implement phase verify respond close labels labels-prune clean

# Host-side dagu CLI reads this project rather than ~/.config/dagu.
export DAGU_HOME := $(CURDIR)

include project.env

REPO      ?= $(PROJECT_REPO)

# Every label in the state machine, in lifecycle order. `state` walks this list.
STATES := agent:todo agent:clarifying agent:revising agent:ready-to-implement \
          agent:implementing agent:reviewing agent:responding agent:finished agent:failed

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## -- Dagu in Docker (scheduler + web UI + coordinator) --

up: ## Start dagu and its worker
	@GH_TOKEN="$$(gh auth token)" docker compose up -d --build
	@echo "Web UI: http://localhost:8525"

down: ## Stop dagu
	docker compose down

restart: ## Restart dagu
	docker compose restart

logs: ## Follow dagu container logs
	docker compose logs -f

ps: ## Show container status
	docker compose ps

open: ## Open the web UI
	open http://localhost:8525

## -- Worker --

worker: ## Follow worker logs
	docker compose logs -f worker

## -- Authoring and inspection --

validate: ## Validate every DAG definition
	@for f in dags/*.yaml; do printf '%s: ' "$$f"; dagu validate "$$f" >/dev/null 2>&1 \
		&& echo ok || { echo FAILED; dagu validate "$$f"; exit 1; }; done

health: ## Prove the host worker is reachable, tooled and logged in
	@docker compose exec -T dagu dagu enqueue check-health
	@echo "Enqueued. Run 'make worker' to follow logs, or open http://localhost:8525"

state: ## Show every open issue, grouped by its agent:* state
	@for s in $(STATES); do \
		out=$$(gh issue list --repo $(REPO) --label "$$s" --state open --limit 100 \
			--json number,title --jq '.[] | "    #\(.number) \(.title)"'); \
		[ -z "$$out" ] || { printf '\033[36m%s\033[0m\n%s\n' "$$s" "$$out"; }; \
	done
	@bare=$$(gh issue list --repo $(REPO) --state open --limit 200 --json number,labels \
		--jq '[.[] | select([.labels[].name] | any(startswith("agent:")) | not) | "#\(.number)"] | join(", ")'); \
	[ -z "$$bare" ] || printf '\033[31munlabelled (no poller will see these)\033[0m\n    %s\n' "$$bare"

## -- Manual runs --
#
# `dagu start` runs a DAG locally on this Mac, which already has the toolchain;
# only the queue dispatches to the worker. That is why `health` uses
# `dagu enqueue` and everything below uses `dagu start`.
#
# Supplying ISSUE_NUMBER bypasses queue selection, but the DAG still performs
# the normal atomic label claim before doing work.

clarify: ## Clarify one issue now: make clarify ISSUE=42
	@test -n "$(ISSUE)" || { echo "usage: make clarify ISSUE=<number>"; exit 1; }
	dagu start dags/clarify-task.yaml -- ISSUE_NUMBER=$(ISSUE)

implement: ## Implement one issue now: make implement ISSUE=42
	@test -n "$(ISSUE)" || { echo "usage: make implement ISSUE=<number>"; exit 1; }
	dagu start dags/implement-clarified-task.yaml -- ISSUE_NUMBER=$(ISSUE)

phase: ## Re-run one implementation phase: make phase ISSUE=42 PHASE=review
	@test -n "$(ISSUE)" -a -n "$(PHASE)" \
		|| { echo "usage: make phase ISSUE=<number> PHASE=<explore|propose|code|fix-verify|review|resolve-review|sync|pr-body>"; exit 1; }
	@test -f /tmp/dagu-agent/$(ISSUE)/implement/state.json \
		|| { echo "no run directory for issue $(ISSUE): run 'make implement ISSUE=$(ISSUE)' first"; exit 1; }
	scripts/implement/run-phase.sh "$(PHASE)" /tmp/dagu-agent/$(ISSUE)/implement \
		"$(PROJECT_REPO)" "$(PROJECT_WORKSPACE)" "$(IMPLEMENT_SKILL)" \
		"$(or $(TIER),deep)" "$(or $(BUDGET),3)"

verify: ## Verify one issue, fixing until green: make verify ISSUE=42 [ATTEMPTS=3]
	@test -n "$(ISSUE)" || { echo "usage: make verify ISSUE=<number> [ATTEMPTS=n]"; exit 1; }
	@test -f /tmp/dagu-agent/$(ISSUE)/implement/state.json \
		|| { echo "no run directory for issue $(ISSUE): run 'make implement ISSUE=$(ISSUE)' first"; exit 1; }
	scripts/implement/verify-until-green.sh /tmp/dagu-agent/$(ISSUE)/implement \
		"$(PROJECT_REPO)" "$(PROJECT_WORKSPACE)" "$(IMPLEMENT_SKILL)" \
		"$(or $(ATTEMPTS),3)" deep 2 manual

respond: ## Resolve the current review state now: make respond ISSUE=42
	@test -n "$(ISSUE)" || { echo "usage: make respond ISSUE=<number>"; exit 1; }
	dagu start dags/resolve-code-review.yaml -- ISSUE_NUMBER=$(ISSUE)

close: ## Resolve a merged review now (alias of respond): make close ISSUE=42
	@$(MAKE) respond ISSUE=$(ISSUE)

## -- Repository setup --

labels: ## Create the agent:* labels on $(REPO) (idempotent)
	@gh label create "agent:todo"               --repo $(REPO) --color 0E8A16 --force \
		--description "Queued for the clarifier"
	@gh label create "agent:clarifying"         --repo $(REPO) --color FBCA04 --force \
		--description "The clarifier is reading this"
	@gh label create "agent:revising"           --repo $(REPO) --color D93F0B --force \
		--description "Waiting on you: answer the questions, then relabel agent:todo"
	@gh label create "agent:ready-to-implement" --repo $(REPO) --color 1D76DB --force \
		--description "Clarified. Queued for the implementer"
	@gh label create "agent:implementing"       --repo $(REPO) --color FBCA04 --force \
		--description "The implementer is building this"
	@gh label create "agent:reviewing"          --repo $(REPO) --color 5319E7 --force \
		--description "Pull request open and awaiting review"
	@gh label create "agent:responding"         --repo $(REPO) --color FBCA04 --force \
		--description "The responder is addressing review feedback"
	@gh label create "agent:finished"           --repo $(REPO) --color CFD3D7 --force \
		--description "Pull request merged and the worktree reclaimed"
	@gh label create "agent:failed"             --repo $(REPO) --color B60205 --force \
		--description "A run broke; the comment says where"

labels-prune: ## Delete the labels retired in the agent-per-phase refactor
	@echo "This removes agent:in-progress, agent:done and agent:needs-input from $(REPO),"
	@echo "including from any issue still carrying them. Ctrl-C within 5s to abort."
	@sleep 5
	@for l in agent:in-progress agent:done agent:needs-input; do \
		gh label delete "$$l" --repo $(REPO) --yes 2>/dev/null && echo "deleted $$l" \
			|| echo "$$l not present"; \
	done

clean: ## Delete run history and logs (keeps DAG definitions)
	rm -rf data logs && mkdir -p data logs
