# Developer shortcuts. Run `make` (or `make help`) for the categorized list.
# Every target wraps a command documented in AGENTS.md; nothing here is the
# only way to do it.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CARGO        ?= cargo
BIN          := target/release/ai-memory
# macOS avoids re-reading the Keychain in every test process.
TEST_ENV     := $(if $(filter Darwin,$(shell uname -s)),SSL_CERT_FILE=/etc/ssl/cert.pem,)

# Local deployment (macOS launchd). Override on the command line if yours differ.
INSTALL_DIR  ?= $(HOME)/Applications/ai-memory
SERVICE      ?= co.akitaonrails.ai-memory
SERVER_URL   ?= http://127.0.0.1:49374
DATA_DIR     ?= $(HOME)/Library/Application Support/ai-memory
BACKUP_DIR   ?= $(HOME)/Library/Application Support/ai-memory-backups
LOG_FILE     ?= $(HOME)/Library/Logs/ai-memory.log
ERR_LOG_FILE ?= $(HOME)/Library/Logs/ai-memory.err.log

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
		/^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
		/^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Build

.PHONY: build
build: ## Debug build of the workspace
	$(CARGO) build --workspace

.PHONY: release
release: ## Release build of the ai-memory binary
	$(CARGO) build --release --bin ai-memory

.PHONY: css
css: ## Regenerate the web UI stylesheet (downloads the pinned Tailwind CLI)
	TAILWIND_BUILD=1 $(CARGO) build -p ai-memory-web

##@ Test

.PHONY: test
test: ## Everyday tier: every shipped crate (cargo t)
	$(TEST_ENV) $(CARGO) t

.PHONY: test-full
test-full: ## Full tier: whole workspace incl. slow tests (cargo tf)
	$(TEST_ENV) $(CARGO) tf

.PHONY: test-crate
test-crate: ## One crate: make test-crate CRATE=ai-memory-store
	@test -n "$(CRATE)" || { echo "usage: make test-crate CRATE=<crate>" >&2; exit 2; }
	$(TEST_ENV) $(CARGO) t -p $(CRATE)

.PHONY: test-filter
test-filter: ## One topic: make test-filter FILTER=handoff
	@test -n "$(FILTER)" || { echo "usage: make test-filter FILTER=<regex>" >&2; exit 2; }
	$(TEST_ENV) $(CARGO) t -E 'test(/$(FILTER)/)'

.PHONY: test-shell
test-shell: ## Hook shell library tests
	bash tests/hooks/test_lib.sh

.PHONY: test-importer
test-importer: ## Companion importer (not a root workspace member)
	$(CARGO) test --manifest-path companions/ai-memory-importer/Cargo.toml

.PHONY: test-macos
test-macos: ## macOS menu bar companion (Swift)
	swift test --package-path companions/ai-memory-macos

##@ Quality gates

.PHONY: fmt
fmt: ## Format all crates
	$(CARGO) fmt --all

.PHONY: fmt-check
fmt-check: ## Check formatting without writing
	$(CARGO) fmt --all -- --check

.PHONY: lint
lint: ## Clippy with warnings as errors
	$(CARGO) clippy --workspace --all-targets -- -D warnings

.PHONY: deny
deny: ## Dependency policy (needs cargo-deny)
	$(CARGO) deny check

.PHONY: check
check: fmt-check ## Pre-handoff gate: fmt, whitespace, clippy, full tests
	git diff --check
	$(MAKE) lint
	$(MAKE) test-full

##@ Local deployment (macOS launchd)

.PHONY: backup
backup: ## Online snapshot of wiki/, db/ and config.toml into BACKUP_DIR
	@mkdir -p "$(BACKUP_DIR)"
	ai-memory backup --to "$(BACKUP_DIR)/ai-memory-$$(date +%Y%m%d-%H%M%S).tar.gz"

.PHONY: deploy
deploy: release backup ## Build, back up data, swap the binary, restart the service
	@test -d "$(INSTALL_DIR)" || { echo "INSTALL_DIR $(INSTALL_DIR) does not exist" >&2; exit 1; }
	@if [ -f "$(INSTALL_DIR)/ai-memory" ]; then \
		cp -p "$(INSTALL_DIR)/ai-memory" "$(INSTALL_DIR)/ai-memory.prev"; \
		echo "previous binary kept at $(INSTALL_DIR)/ai-memory.prev"; \
	fi
	install -m 0755 "$(BIN)" "$(INSTALL_DIR)/ai-memory.new"
	mv -f "$(INSTALL_DIR)/ai-memory.new" "$(INSTALL_DIR)/ai-memory"
	$(MAKE) restart
	$(MAKE) status

.PHONY: rollback
rollback: ## Restore the binary saved by the last deploy and restart
	@test -f "$(INSTALL_DIR)/ai-memory.prev" || { echo "no $(INSTALL_DIR)/ai-memory.prev" >&2; exit 1; }
	cp -p "$(INSTALL_DIR)/ai-memory.prev" "$(INSTALL_DIR)/ai-memory"
	$(MAKE) restart

.PHONY: restart
restart: ## Restart the launchd service and wait for health
	launchctl kickstart -k "gui/$$(id -u)/$(SERVICE)"
	@for _ in $$(seq 1 50); do curl -sf "$(SERVER_URL)/healthz" >/dev/null && exit 0; sleep 0.2; done; \
		echo "server did not become healthy; see $(ERR_LOG_FILE)" >&2; exit 1

.PHONY: status
status: ## Installed version, service state and health
	@"$(INSTALL_DIR)/ai-memory" --version
	@launchctl print "gui/$$(id -u)/$(SERVICE)" | awk '/state =|pid =/ {$$1=$$1; print}'
	@curl -sf "$(SERVER_URL)/healthz" >/dev/null && echo "health: ok" || echo "health: FAILED"

.PHONY: logs
logs: ## Follow the service logs
	tail -n 50 -f "$(LOG_FILE)" "$(ERR_LOG_FILE)"
