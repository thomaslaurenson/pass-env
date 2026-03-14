SHELL := /bin/bash

EXTENSION_DIR ?= /usr/lib/password-store/extensions
MAN_DIR       ?= /usr/share/man
BASHCOMP_DIR  ?= /etc/bash_completion.d
ZSHCOMP_DIR   ?= /usr/local/share/zsh/site-functions

BATS_VERSION  ?= v1.13.0

.PHONY: install uninstall lint test bump-bats

install:
	@sudo install -v -d "$(MAN_DIR)/man1"
	@sudo install -v -m 0644 man/pass-env.1 "$(MAN_DIR)/man1/pass-env.1"
	@sudo install -v -d "$(EXTENSION_DIR)/"
	@sudo install -v -m0755 src/env.bash "$(EXTENSION_DIR)/env.bash"
	@sudo install -v -d "$(BASHCOMP_DIR)/"
	@sudo install -v -m 644 completion/pass-env.bash.completion "$(BASHCOMP_DIR)/pass-env"
	@sudo install -v -d "$(ZSHCOMP_DIR)/"
	@sudo install -v -m 644 completion/_pass-env "$(ZSHCOMP_DIR)/_pass-env"

uninstall:
	@rm -f "$(EXTENSION_DIR)/env.bash"
	@rm -f "$(MAN_DIR)/man1/pass-env.1"
	@rm -f "$(BASHCOMP_DIR)/pass-env"
	@rm -f "$(ZSHCOMP_DIR)/_pass-env"

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
	@printf 'shellcheck  scripts/uninstall.sh ... '
	@shellcheck -s bash scripts/uninstall.sh \
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
	@printf 'bash -n     scripts/uninstall.sh ... '
	@bash -n scripts/uninstall.sh \
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
