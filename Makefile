SHELL := /bin/bash

EXTENSION_DIR ?= /usr/lib/password-store/extensions
MAN_DIR ?= /usr/share/man
BASHCOMP_DIR ?= /etc/bash_completion.d
ZSHCOMP_DIR ?= /usr/local/share/zsh/site-functions

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
	shellcheck -s bash src/env.bash
