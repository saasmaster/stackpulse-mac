# StackPulse — developer command surface.
# (These same scripts are what the app's future Command Center will discover.)

.DEFAULT_GOAL := help
SHELL := /bin/bash
APP_DIR := apps/StackPulseMac

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

.PHONY: build
build: ## Build the whole workspace (Rust) in debug
	cargo build --workspace

.PHONY: test
test: ## Run all Rust tests
	cargo test --workspace

.PHONY: test-swift
test-swift: core ## Run the Swift app tests (needs the core static lib)
	cd apps/StackPulseMac && swift test

.PHONY: test-all
test-all: test test-swift ## Every test: Rust workspace + Swift app

.PHONY: cli
cli: ## Build + run the CLI snapshot against local logs
	cargo run -p stackpulse-cli --quiet -- snapshot

.PHONY: core
core: ## Build the release core artifacts (static lib + CLI)
	./scripts/build-core.sh release

.PHONY: app
app: ## Build the macOS app (release)
	./scripts/build-app.sh

.PHONY: package
package: app ## Assemble a runnable StackPulse.app (ad-hoc signed, local use)
	./scripts/package-app.sh

.PHONY: run
run: ## Build + launch the menu-bar app
	./scripts/build-app.sh && "$(APP_DIR)/.build/release/StackPulseApp"

.PHONY: dump
dump: ## Build + print the snapshot JSON via the app (headless)
	./scripts/build-app.sh && "$(APP_DIR)/.build/release/StackPulseApp" --dump

.PHONY: fmt
fmt: ## Format Rust code
	cargo fmt --all

.PHONY: lint
lint: ## Clippy (fail on warnings)
	cargo clippy --workspace --all-targets -- -D warnings

.PHONY: smoke
smoke: ## Portability smoke test for the shared core
	./scripts/smoke-portability.sh

.PHONY: clean
clean: ## Remove build artifacts
	cargo clean
	rm -rf $(APP_DIR)/.build dist
