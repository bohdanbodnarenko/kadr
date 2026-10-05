# Kadr — the commands, in one place.
#
# CI runs these targets rather than its own copies, which is the point: the command that
# passes on a machine in a data centre is the command that ran on yours. Before this, the
# build line lived in ci.yml, in CLAUDE.md and in whatever anybody had in their shell
# history, and the package list lived in a hand-written CI matrix that had quietly lost a
# package.
#
# The gates in Scripts/ are called, never reimplemented. This is a front door, not a
# second implementation.

SHELL := /bin/bash
# Without this a failing command in the middle of a recipe is ignored and the target
# "succeeds" — which is the one thing a build tool must never do.
# NOTE: GNU Make 3.81, the one macOS ships, ignores .SHELLFLAGS. Any recipe that pipes a
# command whose failure matters must say `set -o pipefail;` itself (see test-app).
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

WORKSPACE := Kadr.xcworkspace
SCHEME := Kadr
EDITOR_SCHEME := KadrEditor
DERIVED := build
APP := $(DERIVED)/Build/Products/Release/$(SCHEME).app
ARCHIVE := $(DERIVED)/$(SCHEME).xcarchive
INSTALL_DIR := /Applications

# Discovered rather than listed. A package added to Packages/ is tested by everything here
# and by CI from the moment it exists, with nobody having to remember a second list.
PACKAGES := $(sort $(notdir $(wildcard Packages/*)))

# Signing is off for plain builds so a fresh checkout compiles without a developer
# account; `release` and `install` sign properly.
# Build identity (docs/17 T-REL-5). The build number is the commit count, so it only ever
# grows along main — which is what Sparkle compares — and the SHA names the exact source a
# tester's report came from. Every build target stamps both; the project's own values
# (1 and "unknown") are only what an Xcode-button build gets.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
STAMP := CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) KADR_GIT_COMMIT=$(GIT_COMMIT)

# Lint tools are pinned: an unpinned `brew install` in CI meant a new SwiftLint rule could
# turn main red with no change in the repository (docs/18 X-7). `make lint-tools` puts the
# pinned binaries in build/tools, which `lint` prefers over whatever is on PATH.
SWIFTLINT_VERSION := 0.65.1
SWIFTFORMAT_VERSION := 0.63.0
TOOLS := $(DERIVED)/tools
export PATH := $(CURDIR)/$(TOOLS):$(PATH)

UNSIGNED := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""

.PHONY: help build build-editor release install uninstall run test test-packages test-package \
        test-app test-editor test-app-build test-app-run dmg lint lint-tools format format-fix check check-layering \
        check-size size-gate perf packages packages-json all clean

help: ## Show the available commands
	@printf 'Kadr — make <target>\n\n'
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN { FS = ":.*?## " } { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }'
	@printf '\nPackages: $(words $(PACKAGES)) found under Packages/\n'

# MARK: - Building

build: ## Build the agent app (Debug, unsigned)
	@xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet $(STAMP) $(UNSIGNED)

build-editor: ## Build the editor app (Debug, unsigned)
	@xcodebuild build -workspace $(WORKSPACE) -scheme $(EDITOR_SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet $(STAMP) $(UNSIGNED)

release: ## Build the agent app signed, for installing
	@xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet $(STAMP)
	@codesign --verify --deep --strict $(APP)
	@printf 'Built and verified %s\n' '$(APP)'

install: release ## Build and install into /Applications
	@if pgrep -x $(SCHEME) >/dev/null; then \
		printf 'Quitting the running Kadr first\n'; \
		osascript -e 'quit app "$(SCHEME)"' || true; \
		sleep 1; \
	fi
	@rm -rf "$(INSTALL_DIR)/$(SCHEME).app"
	@cp -R $(APP) "$(INSTALL_DIR)/"
	@printf 'Installed %s\n' '$(INSTALL_DIR)/$(SCHEME).app'
	@printf 'Kadr is a menu-bar app — look for its icon rather than a Dock icon.\n'
	@printf 'First launch needs Screen Recording in System Settings, then a restart of the app.\n'

uninstall: ## Remove the installed app
	@if pgrep -x $(SCHEME) >/dev/null; then osascript -e 'quit app "$(SCHEME)"' || true; sleep 1; fi
	@rm -rf "$(INSTALL_DIR)/$(SCHEME).app"
	@printf 'Removed %s\n' '$(INSTALL_DIR)/$(SCHEME).app'

run: install ## Install and launch
	@open "$(INSTALL_DIR)/$(SCHEME).app"

# The distributable: archive, export with Developer ID, notarize, DMG, appcast. One
# definition, like every other command here (docs/17 T-REL-3). Needs the owner's
# certificate, notary profile and Sparkle key — Scripts/release.sh says which is missing.
dmg: ## Notarized DMG and appcast entry (VERSION=0.9.0 [CHANNEL=beta])
	@test -n "$(VERSION)" || { printf 'Set VERSION, e.g. make dmg VERSION=0.9.0 CHANNEL=beta\n' >&2; exit 2; }
	@Scripts/release.sh --version $(VERSION) --build $(BUILD_NUMBER) $(if $(CHANNEL),--channel $(CHANNEL))

# MARK: - Testing

test: test-packages test-app test-editor ## Run every test

test-packages: ## Run every package's tests
	@for package in $(PACKAGES); do \
		printf '\n== %s ==\n' "$$package"; \
		( cd Packages/$$package && swift test ) || exit 1; \
	done

# One package, for CI's matrix: `make test-package PACKAGE=Shared`.
test-package: ## Run one package's tests (PACKAGE=Shared)
	@test -n "$(PACKAGE)" || { printf 'Set PACKAGE, e.g. make test-package PACKAGE=Shared\n' >&2; exit 2; }
	@cd Packages/$(PACKAGE) && swift test

# Not `-quiet`: it suppresses the test summary, which is the entire output anybody wants
# from a test run. The build targets keep it; this one cannot.
# The filter is braced so only *its* empty-match status is forgiven: under pipefail the
# exit status is xcodebuild's, so a failing test or a runner that crashes at bootstrap
# fails the target. An unbraced `|| true` once kept CI green for a week in which no app
# test ran at all (docs/17 T-REL-7). `set -o pipefail` is spelled out because macOS's
# GNU Make 3.81 ignores .SHELLFLAGS (it arrived in 3.82), so the flag above never
# reached this recipe.
test-app: ## Run the agent app's tests
	@set -o pipefail; xcodebuild test -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		-only-testing:KadrTests $(STAMP) $(UNSIGNED) \
		| { grep -E '✔|✘|Test run|error:' || true; }

# The agent's tests built once and run elsewhere: CI builds on the newest macOS and runs
# the same bundle on macOS 14, the deployment target, whose runners cannot build with the
# current SDK (docs/18 X-7).
test-app-build: ## Build the agent app's tests without running them
	@xcodebuild build-for-testing -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet $(STAMP) $(UNSIGNED)

test-app-run: ## Run tests built by test-app-build (on this or another Mac)
	@set -o pipefail; xcodebuild test-without-building -xctestrun "$$(ls $(DERIVED)/Build/Products/*.xctestrun | head -1)" \
		-destination 'platform=macOS' -only-testing:KadrTests \
		| { grep -E '✔|✘|Test run|error:' || true; }

# Same shape as test-app, hosted in the editor: save, rebind, open routing and the menus
# are seams no package test reaches (docs/18 X-6).
test-editor: ## Run the editor app's tests
	@set -o pipefail; xcodebuild test -workspace $(WORKSPACE) -scheme $(EDITOR_SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		-only-testing:KadrEditorTests $(STAMP) $(UNSIGNED) \
		| { grep -E '✔|✘|Test run|error:' || true; }

# MARK: - Static checks

lint: ## SwiftLint and SwiftFormat, both read-only
	@[ "$$(swiftlint version)" = "$(SWIFTLINT_VERSION)" ] || \
		printf 'warning: SwiftLint %s, pinned %s (make lint-tools)\n' "$$(swiftlint version)" "$(SWIFTLINT_VERSION)" >&2
	@[ "$$(swiftformat --version)" = "$(SWIFTFORMAT_VERSION)" ] || \
		printf 'warning: SwiftFormat %s, pinned %s (make lint-tools)\n' "$$(swiftformat --version)" "$(SWIFTFORMAT_VERSION)" >&2
	@swiftlint lint --strict
	@swiftformat --lint .

lint-tools: ## Download the pinned SwiftLint and SwiftFormat into build/tools
	@mkdir -p $(TOOLS)
	@curl -fsSL -o $(TOOLS)/swiftlint.zip \
		https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip
	@unzip -oq $(TOOLS)/swiftlint.zip swiftlint -d $(TOOLS)
	@curl -fsSL -o $(TOOLS)/swiftformat.zip \
		https://github.com/nicklockwood/SwiftFormat/releases/download/$(SWIFTFORMAT_VERSION)/swiftformat.zip
	@unzip -oq $(TOOLS)/swiftformat.zip swiftformat -d $(TOOLS)
	@rm -f $(TOOLS)/*.zip
	@swiftlint version && swiftformat --version

format: format-fix ## Rewrite sources with SwiftFormat

format-fix:
	@swiftformat .

check: check-layering check-size ## The architecture and size gates

check-layering: ## Layering, zero-network and agent-linkage (docs/04 §11)
	@Scripts/check-layering.sh

check-size: ## App bundle size against the PRD §8 budget (advisory on a build product)
	@Scripts/check-size.sh

# The budget is about the DMG somebody downloads, and only an archive produces those
# bytes: a `xcodebuild build` product carries local symbols an archive strips and is
# compiled per-file rather than whole-module, which measured 16 MB against a 15 MB
# budget for a release that ships at 12.9 MB.
size-gate: ## The real size budget: archive the app and measure the DMG it ships as
	@xcodebuild archive -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration Release \
		-archivePath $(ARCHIVE) -quiet $(UNSIGNED)
	@Scripts/check-size.sh $(ARCHIVE)

# Separate from `check` because it runs the app and waits half a minute; `all` leaves it
# out for the same reason, and CI runs it on its own.
perf: build ## Measure the idle budgets (PRD §8) — takes ~30s
	@Scripts/check-perf.sh --idle-seconds 30

# MARK: - Everything

all: lint test check ## What CI runs, in one command

# MARK: - Plumbing

packages: ## List the packages
	@printf '%s\n' $(PACKAGES)

# The CI matrix, built from the filesystem so it cannot fall behind.
packages-json:
	@printf '%s\n' $(PACKAGES) | jq -R . | jq -sc .

clean: ## Remove build products
	@rm -rf $(DERIVED)
	@for package in $(PACKAGES); do ( cd Packages/$$package && swift package clean ); done
	@printf 'Cleaned\n'
