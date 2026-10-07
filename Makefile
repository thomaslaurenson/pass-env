SHELL := /bin/bash

TAG          ?=
BATS_VERSION ?= v1.13.0

# Lint inputs. shellcheck reads the dialect from a shebang, so only the files
# without one name it explicitly. shellcheck has no zsh dialect at all
# ("Unknown shell: zsh"), which is why the zsh files get zsh -n instead.
SHELLCHECK_FILES   := src/env.bash \
                      scripts/install.sh \
                      contrib/pass-env-uninstall.sh \
                      test/helpers/mock_pass \
                      test/helpers/mock_fzf
SHELLCHECK_SOURCED := contrib/pass-env-init.sh \
                      completion/pass-env.bash.completion
BASH_SYNTAX_FILES  := src/env.bash \
                      scripts/install.sh \
                      contrib/pass-env-uninstall.sh \
                      completion/pass-env.bash.completion
ZSH_SYNTAX_FILES   := completion/_pass-env \
                      test/zsh_integration.zsh

##@ BUILD
.PHONY: help
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^##@ / {printf "\n%s\n", substr($$0, 5)} \
		/^[a-zA-Z_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: dist
dist: ## Build the release artefacts for TAG into dist/ (tarball, baked install.sh, checksums.txt)
	@tag="$(TAG)"; \
	if [[ -z "$$tag" ]]; then \
	  printf 'dist: TAG is empty; pass TAG=v1.0.0\n' >&2; \
	  exit 1; \
	fi; \
	rm -rf dist && mkdir -p dist; \
	git archive --prefix="pass-env-$$tag/" HEAD | gzip > "dist/pass-env-$$tag.tar.gz"; \
	sed "s/^VERSION=.*/VERSION=\"$$tag\"/" scripts/install.sh > dist/install.sh; \
	chmod 0755 dist/install.sh; \
	if command -v sha256sum >/dev/null 2>&1; then sum="sha256sum"; else sum="shasum -a 256"; fi; \
	(cd dist && $$sum "pass-env-$$tag.tar.gz" install.sh > checksums.txt); \
	ls -1 dist

##@ TEST
.PHONY: test
test: ## Run bats test suite and zsh integration test
	@# Directory, not a file list, so a new .bats file is picked up automatically.
	@# Never add -r: it would descend into test/extern/bats and run the vendored
	@# bats project's own suite as though it were ours.
	test/extern/bats/bin/bats test/
	@printf 'zsh integration  contrib/pass-env-init.sh ... '
	@zsh test/zsh_integration.zsh \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }

##@ LINT
.PHONY: lint
lint: ## Run shellcheck and syntax checks on every shipped script
	@for f in $(SHELLCHECK_FILES); do \
	  printf 'shellcheck   %-38s ' "$$f"; \
	  shellcheck "$$f" && printf 'ok\n' || { printf 'fail\n'; exit 1; }; \
	done
	@for f in $(SHELLCHECK_SOURCED); do \
	  printf 'shellcheck   %-38s ' "$$f"; \
	  shellcheck -s bash "$$f" && printf 'ok\n' || { printf 'fail\n'; exit 1; }; \
	done
	@for f in $(BASH_SYNTAX_FILES); do \
	  printf 'bash -n      %-38s ' "$$f"; \
	  bash -n "$$f" && printf 'ok\n' || { printf 'fail\n'; exit 1; }; \
	done
	@for f in $(ZSH_SYNTAX_FILES); do \
	  printf 'zsh -n       %-38s ' "$$f"; \
	  zsh -n "$$f" && printf 'ok\n' || { printf 'fail\n'; exit 1; }; \
	done
	@printf 'bash source  %-38s ' 'contrib/pass-env-init.sh'
	@bash -c 'source contrib/pass-env-init.sh' \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }
	@printf 'zsh source   %-38s ' 'contrib/pass-env-init.sh'
	@zsh -c 'source contrib/pass-env-init.sh' \
	  && printf 'ok\n' \
	  || { printf 'fail\n'; exit 1; }

.PHONY: check_version
check_version: ## Verify versions in src/env.bash, man page, and CHANGELOG.md are consistent
	@src="$$($(MAKE) -s get_version)" || exit 1; \
	man="$$(sed -n 's/.*"Version \([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' man/pass-env.1)"; \
	log="$$(grep -m1 '^## ' CHANGELOG.md | awk '{print $$2}')"; \
	ok=1; \
	if [[ "$$man" != "$$src" ]]; then \
	  printf 'check_version: man page (%s) != src/env.bash (%s)\n' "$$man" "$$src" >&2; ok=0; \
	fi; \
	if [[ "$$log" != "$$src" ]]; then \
	  printf 'check_version: CHANGELOG.md (%s) != src/env.bash (%s)\n' "$$log" "$$src" >&2; ok=0; \
	fi; \
	[[ "$$ok" -eq 1 ]]

.PHONY: check_version_tag
check_version_tag: ## Verify src/env.bash VERSION matches TAG (TAG=v1.0.0)
	@tag="$(TAG)"; tag="$${tag#v}"; \
	if [[ -z "$$tag" ]]; then \
	  printf 'check_version_tag: TAG is empty; pass TAG=v1.0.0\n' >&2; \
	  exit 1; \
	fi; \
	src="$$($(MAKE) -s get_version)" || exit 1; \
	if [[ "$$src" != "$$tag" ]]; then \
	  printf 'check_version_tag: src/env.bash (%s) does not match tag (%s)\n' \
	    "$$src" "$(TAG)" >&2; \
	  exit 1; \
	fi

.PHONY: bump_bats
bump_bats: ## Pin bats submodule to BATS_VERSION (default: v1.13.0)
	@printf 'Pinning bats submodule to %s\n' '$(BATS_VERSION)'
	@cd test/extern/bats \
	  && git fetch --tags \
	  && git checkout '$(BATS_VERSION)'
	@git add test/extern/bats
	@printf 'Submodule staged at %s; commit when ready:\n' '$(BATS_VERSION)'
	@printf '  git commit -m "Bump bats to %s"\n' '$(BATS_VERSION)'

##@ GET
.PHONY: get_version
get_version: ## Print the version embedded in src/env.bash (fails if absent)
	@v="$$(sed -n 's/^readonly PASSENV_VERSION="\(.*\)"$$/\1/p' src/env.bash)"; \
	  test -n "$$v" && printf '%s\n' "$$v"

.PHONY: get_changelog
get_changelog: ## Print release notes for TAG to stdout (TAG=v1.0.0)
	@tag="$(TAG)"; tag="$${tag#v}"; \
	if [[ -z "$$tag" ]]; then \
	  printf 'get_changelog: TAG is empty; pass TAG=v1.0.0\n' >&2; \
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
	  printf 'get_changelog: no CHANGELOG entry for %s\n' "$$tag" >&2; \
	  exit 1; \
	fi; \
	printf '%s\n' "$$notes"

##@ CI
.PHONY: ci
ci: lint check_version test ## Run all CI checks locally

.PHONY: clean
clean: ## Remove release artefacts
	rm -rf dist
