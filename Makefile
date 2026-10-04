.DEFAULT_GOAL := help

# Latest release tag, used as the baseline for breaking-change checks.
LAST_TAG := $(shell git describe --tags --abbrev=0 2>/dev/null)

.PHONY: help check lint format build breaking

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

check: format lint build breaking ## Everything CI runs

format: ## Fail if any proto is not formatted (fix with: buf format -w)
	buf format -d --exit-code

lint: ## Lint protos with buf STANDARD rules
	buf lint

build: ## Compile all protos
	buf build -o /dev/null

breaking: ## Check for breaking changes against the latest tag
	@if [ -n "$(LAST_TAG)" ]; then buf breaking --against '.git#tag=$(LAST_TAG)'; else echo "no tag yet, skipping"; fi
