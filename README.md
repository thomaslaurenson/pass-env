# pass-env

A [pass](https://www.passwordstore.org/) extension that decrypts `.env` files from the password store and exports their contents as environment variables.

## Requirements

- `pass`
- `gnupg` (usually bundled with pass)
- `fzf` (optional, for interactive selection)

```sh
# Debian-based
sudo apt install -y pass fzf
# Red Hat-based
sudo dnf install -y pass fzf
# macOS
brew install pass fzf
```

## Installation

### Verified Install (Recommended)

Download the installer and its published checksum, verify the hash, inspect the script, then run it:

```sh
BASE_URL="https://github.com/thomaslaurenson/pass-env/releases/latest/download"
curl -fsSL "$BASE_URL/install.sh" -o /tmp/pass-env-install.sh
curl -fsSL "$BASE_URL/checksums.txt" -o /tmp/pass-env-checksums.txt

sha256sum --check --ignore-missing /tmp/pass-env-checksums.txt

less /tmp/pass-env-install.sh

bash /tmp/pass-env-install.sh
```

### Quick Install

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash
```

For a user-local install with no `sudo`, pass the `--user` argument:

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash -s -- --user
```

> **Note:** When piped directly to bash, the installer runs without giving you a chance to verify its contents. Use the recommended path in the section above if you require pre-execution integrity checking.

There are a selection of other install options, including:

- `--no-completion`: Do not install bash/zsh shell completion
- `--no-man`: Do not install manual page
- `--no-init`: Do not install shell initialization helps
- `--no-uninstall`: Do not install pass env uninstaller

## Two Ways to Use `pass-env`

`pass env` is the raw pass extension. It emits `export KEY=VALUE` lines to stdout — but because a subprocess cannot modify its parent's environment, those lines must be `eval`'d by the caller to have any effect in the current shell.

`passenv` is the shell function from `contrib/pass-env-init.sh` that handles the `eval` for you and tracks loaded entries in `_PASSENV_TRACKER`. It is installed and sourced into your RC files by default. **Use `passenv` for all interactive shell work.**

The one exception where the raw extension is sufficient without shell integration is `pass env run`: it injects decrypted variables into a subprocess environment directly, so no `eval` is required and nothing leaks into the calling shell.

1. Use `set` subcommand to export to current shell

```sh
# set one entry
$ passenv set api/openai.env
passenv: loaded api/openai.env → OPENAI_API_KEY

# set multiple entries
$ passenv set api/openai.env db/prod.env
passenv: loaded api/openai.env → OPENAI_API_KEY
passenv: loaded db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

2. List all entries that `set` in the current shell

```sh
$ passenv loaded
passenv: api/openai.env → OPENAI_API_KEY
passenv: db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

3. Use `unset` subcommand to remove a single entry's vars

```sh
# unset one entry
$ passenv unset api/openai.env
passenv: unset api/openai.env → OPENAI_API_KEY

# unset multiple entries
$ passenv unset api/openai.env db/prod.env
passenv: unset api/openai.env → OPENAI_API_KEY
passenv: unset db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

4. Use `run` subcommand to load env vars and spawn process in subshell

```sh
# run a command with one entry's vars injected; nothing leaks into the shell
passenv run api/openai.env -- myapp

# run a command with multiple entries; all vars are available to the subprocess
passenv run api/openai.env db/prod.env -- myapp

# Use native pass env extension without shell initialization to run
pass env run api/openai.env db/prod.env -- myapp
```

See `man pass-env` for full documentation.

## Testing

### Requirements

- `bats` (provided as a submodule)

### Execute Tests

```bash
git submodule update --init
test/extern/bats/bin/bats test/env_bash.bats test/pass_env_init_sh.bats
# OR
make test
```
