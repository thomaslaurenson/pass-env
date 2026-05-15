SHELL := /bin/bash

EXTENSION_DIR ?= /usr/lib/password-store/extensions
MAN_DIR       ?= /usr/share/man
BASHCOMP_DIR  ?= /etc/bash_completion.d
ZSHCOMP_DIR   ?= /usr/local/share/zsh/site-functions

BATS_VERSION ?= v1.13.0
TAG          ?= $(shell git describe --tags --abbrev=0 2>/dev/null)

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

# LINT
.PHONY: lint
lint: ## Run shellcheck and bash -n on all scripts
	@printf 'shellcheck  src/env.bash ... '
	@shellcheck -s bash src/env.bash \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'shellcheck  contrib/pass-env-init.sh ... '
	@shellcheck -s bash contrib/pass-env-init.sh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'shellcheck  scripts/install.sh ... '
	@shellcheck -s bash scripts/install.sh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'shellcheck  contrib/pass-env-uninstall.sh ... '
	@shellcheck -s bash contrib/pass-env-uninstall.sh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'bash -n     src/env.bash ... '
	@bash -n src/env.bash \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'bash -n     scripts/install.sh ... '
	@bash -n scripts/install.sh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'bash -n     contrib/pass-env-uninstall.sh ... '
	@bash -n contrib/pass-env-uninstall.sh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'bash source contrib/pass-env-init.sh ... '
	@bash -c 'source contrib/pass-env-init.sh' \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'zsh  source contrib/pass-env-init.sh ... '
	@zsh -c 'source contrib/pass-env-init.sh' \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }

# TEST
.PHONY: test
test: ## Run bats test suite and zsh integration test
	test/extern/bats/bin/bats test/env_bash.bats test/pass_env_init_sh.bats
	@printf 'zsh integration  contrib/pass-env-init.sh ... '
	@zsh test/zsh_integration.zsh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }

.PHONY: check_version
check_version: ## Verify versions in src/env.bash, man page, and CHANGELOG.md are consistent
	@src="$$(grep -oP 'VERSION="\K[0-9]+\.[0-9]+\.[0-9]+' src/env.bash)"; \
	man="$$(grep -oP '"Version \K[0-9]+\.[0-9]+\.[0-9]+' man/pass-env.1)"; \
	log="$$(grep -m1 '^## ' CHANGELOG.md | awk '{print $$2}')"; \
	ok=1; \
	if [[ "$$man" != "$$src" ]]; then \
	  printf 'check_version: man page (%s) != src/env.bash (%s)\n' "$$man" "$$src" >&2; ok=0; \
	fi; \
	if [[ "$$log" != "$$src" ]]; then \
	  printf 'check_version: CHANGELOG.md (%s) != src/env.bash (%s)\n' "$$log" "$$src" >&2; ok=0; \
	fi; \
	[[ "$$ok" -eq 1 ]]

.PHONY: ci
ci: lint check_version test ## Run all CI checks locally

# GET
.PHONY: get_version
get_version: ## Print the project version from src/env.bash
	@grep -oP 'VERSION="\K[0-9]+\.[0-9]+\.[0-9]+' src/env.bash

.PHONY: get_changelog_entry
get_changelog_entry: ## Print release notes for TAG to stdout (override with TAG=v1.0.0)
	@tag="$(TAG)"; tag="$${tag#v}"; \
	if [[ -z "$$tag" ]]; then \
	  printf 'get_changelog_entry: TAG is empty; pass TAG=v1.0.0 or create a git tag\n' >&2; \
	  exit 1; \
	fi; \
	notes="$$(awk -v tag="$$tag" ' \
	  /^## / { if (found) exit; if (index($$0,"## "tag" ")==1 || $$0=="## "tag) found=1; next } \
	  found { lines[n++]=$$0 } \
	  END { \
	    s=0; while (s<n && lines[s]~/^[[:space:]]*$$/) s++; \
	    e=n-1; while (e>=s && lines[e]~/^[[:space:]]*$$/) e--; \
	    for (i=s;i<=e;i++) print lines[i] \
	  }' CHANGELOG.md)"; \
	if [[ -z "$$notes" ]]; then \
	  printf 'get_changelog_entry: no CHANGELOG entry for %s\n' "$$tag" >&2; \
	  exit 1; \
	fi; \
	printf '%s\n' "$$notes"

.PHONY: check_version_tag
check_version_tag: ## Verify src/env.bash VERSION matches TAG (e.g. make check_version_tag TAG=v1.0.0)
	@src="$$(grep -oP 'VERSION="\K[0-9]+\.[0-9]+\.[0-9]+' src/env.bash)"; \
	tag="$(TAG)"; tag="$${tag#v}"; \
	if [[ "$$src" != "$$tag" ]]; then \
	  printf 'check_version_tag: src/env.bash (%s) does not match tag (%s)\n' "$$src" "$(TAG)" >&2; \
	  exit 1; \
	fi

# TASKS
.PHONY: bump_bats
bump_bats: ## Pin bats submodule to BATS_VERSION (default: v1.13.0)
	@printf 'Pinning bats submodule to %s\n' '$(BATS_VERSION)'
	@cd test/extern/bats \
	  && git fetch --tags \
	  && git checkout '$(BATS_VERSION)'
	@git add test/extern/bats
	@printf 'Submodule staged at %s; commit when ready:\n' '$(BATS_VERSION)'
	@printf '  git commit -m "Bump bats to %s"\n' '$(BATS_VERSION)'
