.DEFAULT_GOAL := help
.PHONY: help up down restart logs ps open worker validate health trigger labels clean

# Host-side dagu CLI reads this project rather than ~/.config/dagu.
export DAGU_HOME := $(CURDIR)

COORDINATOR := 127.0.0.1:50055
POLLER      := dags/sweatcharge-poller.yaml
IMPLEMENTER := dags/agent-implement-issue.yaml
HEALTHCHECK := dags/worker-health-check.yaml

REPO      ?= cuongkane/sweatcharge
WORKSPACE ?= /Users/lexuancuong/CUONG/SWC
SKILL     ?= implement-sweatcharge-feature

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

## -- Dagu in Docker (scheduler + web UI + coordinator) --

up: ## Start dagu
	docker compose up -d
	@echo "Web UI: http://localhost:8525    Now run 'make worker' in another pane."

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

## -- Host worker (runs every step) --

worker: ## Run the host worker in the FOREGROUND; keep this pane open
	@echo "Host worker -> $(COORDINATOR). Ctrl-C to stop."
	dagu worker --worker.coordinators=$(COORDINATOR) --worker.labels host=true

## -- Authoring and manual runs --

validate: ## Validate every DAG definition
	dagu validate $(POLLER)
	dagu validate $(IMPLEMENTER)
	dagu validate $(HEALTHCHECK)

health: ## Prove the host worker is reachable, tooled and logged in
	@docker compose exec -T dagu dagu enqueue worker-health-check
	@echo "Enqueued. Watch the 'make worker' pane, or http://localhost:8525"

trigger: ## Implement one issue now, bypassing the poll: make trigger ISSUE=42
	@test -n "$(ISSUE)" || { echo "usage: make trigger ISSUE=<number>"; exit 1; }
	@# Runs locally on this Mac (which has the full toolchain) rather than being
	@# dispatched to the worker, and skips the agent:in-progress mutex.
	dagu start $(IMPLEMENTER) -- \
		REPO=$(REPO) WORKSPACE=$(WORKSPACE) SKILL=$(SKILL) ISSUE_NUMBER=$(ISSUE)

labels: ## Create the agent:* labels on $(REPO) (idempotent)
	@gh label create "agent:todo"        --repo $(REPO) --color 0E8A16 --force \
		--description "Queued for the implementation agent"
	@gh label create "agent:in-progress" --repo $(REPO) --color FBCA04 --force \
		--description "Agent is currently implementing this"
	@gh label create "agent:done"        --repo $(REPO) --color 5319E7 --force \
		--description "Agent opened a draft PR"
	@gh label create "agent:needs-input" --repo $(REPO) --color D93F0B --force \
		--description "Agent stopped on a blocking question"
	@gh label create "agent:failed"      --repo $(REPO) --color B60205 --force \
		--description "Agent run failed; see the run log"

clean: ## Delete run history and logs (keeps DAG definitions)
	rm -rf data logs && mkdir -p data logs
