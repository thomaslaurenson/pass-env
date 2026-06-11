# pass-env

![Build Status](https://img.shields.io/github/actions/workflow/status/thomaslaurenson/pass-env/tag.yml?style=flat&logo=github) ![Test Status](https://img.shields.io/github/actions/workflow/status/thomaslaurenson/pass-env/tag.yml?style=flat&label=test&logo=github)

![Release Version](https://img.shields.io/github/v/release/thomaslaurenson/pass-env?style=flat&logo=github) ![Release downloads](https://img.shields.io/github/downloads/thomaslaurenson/pass-env/total?label=downloads&logo=github)

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

For a system wide install (needs `sudo`):

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash -s -- --yes
```

For a user-local install with no `sudo`, pass the `--user` argument:

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash -s -- --user
```

> **Note:** When piped directly to bash, the installer runs without giving you a chance to verify its contents. Use the recommended path in the section above if you require pre-execution integrity checking.

There are a selection of other install options, including:

- `--yes`: Skip confirmation
- `--no-completion`: Do not install bash/zsh shell completion
- `--no-man`: Do not install manual page
- `--no-init`: Do not install shell initialization helper scripts
- `--no-uninstall`: Do not install pass env uninstaller
- `--dry-run`: Show what operations would be done

## Pass Entry Example

- Key value pairs, like a normal `.env` file
- Always has `.env` extension

```sh
$ pass show env/test.env 
USERNAME=admin
PASSWORD=!d+f$bn
```

> **Note:** Values cannot span multiple lines. Newlines within values are not supported. Each line must be a complete `KEY=VALUE` pair.

## Two Ways to Use `pass-env`

### Raw pass env extension

`pass env` (with a space) is the raw pass extension. It emits `export KEY=VALUE` lines to stdout, which makes it useful when "piping to another command". Rule of thumb: **Use `pass env run` for non-interative shell work.**

Export OpenStack creds from openstack.env and run "openstack" command in subshell:

```sh
pass env run openstack.env -- openstack server list
```

Export OpenStack and Tenable creds and run custom Python script in subshell:

```sh
pass env run openstack.env tenable.env -- python3 check_vulns.py
```

### Passenv wrapper

In Linux a subprocess cannot modify its parent's environment, so the raw `pass env` extension is limited when performing interative work. For example, setting (exporting) variables in the current shell and persisting them. Therefore, the `passenv` wrapper is provided to execute `pass env` and `eval` to persist in current shell. `passenv` is the shell function from `contrib/pass-env-init.sh` that handles the `eval` for you and tracks loaded entries in `_PASSENV_TRACKER`. It is installed and sourced into your RC files by default. Rule of thumb: **Use `passenv` for all interactive shell work.**.

Use `set` subcommand to export to current shell:

```sh
passenv set openstack.env
passenv: loaded openstack.env → OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
```

Use `set` subcommand to export two sets of variables to the current shell:

```sh
passenv set openstack.env db/prod.env
passenv: loaded openstack.env → OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
passenv: loaded db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

List all entries that `set` in the current shell:

```sh
passenv loaded
passenv: loaded openstack.env → OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
passenv: db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

Use `unset` subcommand to remove vars from a single entry:

```sh
passenv unset openstack.env
passenv: unset openstack.env → OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
```

Use `unset` subcommand to remove vars from multiple entries:

```sh
passenv unset openstack.env db/prod.env
passenv: unset openstack.env → OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
passenv: unset db/prod.env → DB_HOST DB_PORT DB_NAME DB_PASS
```

See `man pass-env` for full documentation.

## Security Notes

### Eval Trust Boundary

`passenv set` and `eval "$(pass env set ...)"` execute the decrypted entry content as shell code. If an attacker can write to an entry in your password store, via a compromised GPG key, a shared store, or a symlink attack - they can execute arbitrary commands in your shell the next time you load that entry.

The security of `passenv set` is bounded by the security of your GPG key and password store. It is not stronger than that.

If you need to run a single command with secrets and want to avoid the eval trust boundary entirely, use `pass env run`, it never evals entry content into a shell.

### Session-Local Tracker

`_PASSENV_TRACKER` is session-local and reset on shell exit. Variables loaded with `passenv set` reflect the state of the store at the time of loading. If an entry is updated in the store, existing shells will not see the change until `passenv set` is run again in that shell. Multiple shells loading the same entry each maintain independent copies of the variables.

### Memory Residency

Decrypted pass entry content is held as a bash variable during parsing. Bash provides no mechanism to zero memory on `unset`. On Linux, the decrypted values remain in the process's virtual memory until reclaimed and are readable by same-user processes via `/proc/<pid>/mem`.

For workloads where this matters, use `pass env run` to inject secrets into a subprocess rather than loading them into the shell with `passenv set`. Secrets are never stored in shell variables when using the `run` subcommand.

### Environment Visibility

Variables loaded with `passenv set` are visible in the process environment of any child process spawned from that shell. If you need to scope secrets to a single command, use `pass env run` instead.

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
