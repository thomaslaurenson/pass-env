SHELL := /bin/bash

EXTENSION_DIR ?= /usr/lib/password-store/extensions
MAN_DIR       ?= /usr/share/man
BASHCOMP_DIR  ?= /etc/bash_completion.d
ZSHCOMP_DIR   ?= /usr/local/share/zsh/site-functions

BATS_VERSION  ?= v1.13.0

.PHONY: lint test bump-bats release

lint:
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

bump-bats:
	@printf 'Pinning bats submodule to %s\n' '$(BATS_VERSION)'
	@cd test/extern/bats \
	  && git fetch --tags \
	  && git checkout '$(BATS_VERSION)'
	@git add test/extern/bats
	@printf 'Submodule staged at %s — commit when ready:\n' '$(BATS_VERSION)'
	@printf '  git commit -m "Bump bats to %s"\n' '$(BATS_VERSION)'

test:
	test/extern/bats/bin/bats test/env_bash.bats test/pass_env_init_sh.bats

release:
	$(eval TAG := v$(shell sed -n 's/^VERSION="\(.*\)"/\1/p' src/env.bash))
	@[ -n "$(TAG)" ] || { printf 'release: could not read VERSION from src/env.bash\n'; exit 1; }
	@printf 'Tagging release %s\n' '$(TAG)'
	@git diff --quiet && git diff --cached --quiet \
	  || { printf 'release: working tree is dirty — commit or stash first\n'; exit 1; }
	git tag -a '$(TAG)' -m 'Release $(TAG)'
	git push origin '$(TAG)'
