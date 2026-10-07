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

### Inspect Before Running

Download the installer into an empty directory under the name `checksums.txt` lists it by, verify its checksum against the published release (this protects against accidental transport corruption, not against a compromised release), inspect the script, then run it:

```sh
BASE_URL="https://github.com/thomaslaurenson/pass-env/releases/latest/download"
cd "$(mktemp -d)"
curl -fsSL --proto '=https' -O "$BASE_URL/install.sh" -O "$BASE_URL/checksums.txt"

sha256sum --check --ignore-missing checksums.txt

less install.sh

bash install.sh
```

On macOS, replace the `sha256sum` line with `shasum -a 256 --check --ignore-missing checksums.txt`.

### Quick Install

For a system wide install (needs `sudo`):

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash -s -- --yes
```

For a user-local install with no `sudo`, pass the `--user` argument:

```sh
curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/latest/download/install.sh | bash -s -- --user
```

> **Note:** When piped directly to bash, the installer runs without giving you a chance to inspect its contents first. The installer performs an automatic checksum verification against the published release (protecting against transport corruption). Download and review the script manually if you want to inspect it before running.

There are a selection of other install options, including:

- `--yes`: Skip confirmation
- `--no-completion`: Do not install bash/zsh shell completion
- `--no-man`: Do not install manual page
- `--no-init`: Do not install shell initialization helper scripts
- `--no-uninstall`: Do not install pass env uninstaller
- `--dry-run`: Show what operations would be done
- `--skip-checksum`: Skip tarball checksum verification

## Pass Entry Example

- Key value pairs, like a normal `.env` file
- Always has `.env` extension

```sh
$ pass show env/test.env 
USERNAME=admin
PASSWORD=!d+f$bn1df213
```

> **Note:** Values cannot span multiple lines. Newlines within values are not supported. Each line must be a complete `KEY=VALUE` pair.

> **Note:** Values are taken literally, unlike in a dotenv library. Quotes, backslashes and `$` are part of the value, so `PASSWORD="abc"` sets the variable to `"abc"` with the quotes included.

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

To use an entry's variables as *arguments* to the command, write `{{VAR}}`:

```sh
pass env run api/openai.env -- openai responses create --model {{SPARK_MODEL}}
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

When multiple entries define the same variable, later entries override earlier ones.

Use `unset` subcommand to remove vars from a single entry. Variables are restored to their pre-load state: the previous value is re-exported, or the variable is unset if it did not exist before loading:

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

## Passing Variables to Commands

### Using entry variables as command arguments

A variable that lives *inside* an entry cannot be referenced as `$VAR` on a `run` command line:

```sh
# WRONG: your shell expands $SPARK_MODEL to "" before pass ever runs
pass env run api/openai.env -- openai responses create --model $SPARK_MODEL --input "what is a cat?"
# -> openai sees: --model --input "what is a cat?"
```

This is shell expansion order, not a pass-env quirk: the substitution happens at the call site, before the entry has been loaded. Write `{{VAR}}` instead. It is inert to both bash and zsh (brace expansion needs a comma or a `..` range), so it survives your shell unquoted and is substituted once the entry is loaded:

```sh
pass env run api/openai.env -- openai responses create --model {{SPARK_MODEL}} --input "what is a cat?"
```

Only names supplied by the named entries (or by a `VAR=VALUE` assignment, see below) are substituted. Any other `{{...}}` text, a Handlebars or Jinja template, is left exactly as written. If you need to be certain nothing is touched, pass `--no-expand`:

```sh
pass env run --no-expand api/openai.env -- render-template '{{SPARK_MODEL}}'
```

Substitution uses parameter expansion only, never `eval`, and the result is never re-parsed or re-split. A value containing spaces or shell metacharacters arrives as a single inert argument, not as executable code.

### Setting variables for the command

A leading `VAR=VALUE` before the command sets that variable for the command, overriding the entry, exactly as in a normal shell:

```sh
pass env run api/openai.env -- LOG_LEVEL=debug myapp
```

These come from you rather than from the store, so the denylist that guards entry content does not apply to them, a shell would not second-guess them either. They can also be referenced as `{{VAR}}` placeholders.

Alternatively, load the entry into your shell for as long as you need it, and use the variables normally:

```sh
passenv set api/openai.env
openai responses create --model $SPARK_MODEL --input "what is a cat?"
passenv unset api/openai.env
```

See `man pass-env` for full documentation.

## Security Notes

### Trust Boundary

The security of `passenv` is bounded by the integrity of your password store. Entries are encrypted to your public key, which is public, so anyone who can write to the store (a shared or git-synced store, a symlink attack, or any process running as you) can forge an entry that you will decrypt without needing your private key. Such an entry can inject arbitrary environment variables or execute commands when you load it.

### Store-Local Extensions

A user install (`--user`, or any install outside the system extension directory) sets `PASSWORD_STORE_ENABLE_EXTENSIONS=true` in your shell RC file so that pass can find the extension. That setting also makes pass load any extension it finds in `.extensions/` inside the password store, ahead of the system copy, with no signature check unless `PASSWORD_STORE_SIGNING_KEY` is set. On a shared or git-synced store this means a store writer gets code execution on your next `pass env` call without touching an entry. If your store is shared, prefer a system install, or set `PASSWORD_STORE_SIGNING_KEY` so pass verifies `.extensions` and `.gpg-id` before using them.

Both `passenv set` and `pass env run` are affected by a compromised store. The `set` subcommand evaluates entry content as shell code, while `run` exports variables directly into a subprocess, a malicious entry can still set dangerous variables like `PATH` or `LD_PRELOAD` to hijack the spawned process.

`pass env run` avoids `eval` and scopes variables to a subshell (nothing leaks into the calling shell), but it does not protect against a hostile store. Its advantage is cleanup and isolation, not immunity to tampered entries.

To reduce risk, `passenv` refuses to set well-known dangerous environment variables (e.g. `PATH`, `HOME`, `LD_PRELOAD`, `PROMPT_COMMAND`, `BASH_ENV`, `FPATH`, `PYTHONSTARTUP`, `GIT_SSH_COMMAND`) from entries. This is defense-in-depth and not a substitute for store integrity.

The denylist applies to entry *content*, which is untrusted. It deliberately does not apply to a `VAR=VALUE` assignment you type before the command (`pass env run e.env -- PATH=/custom myapp`): that comes from you, not the store, and a shell would not second-guess it either.

### Argument Placeholder Substitution

`{{VAR}}` placeholders in a command's arguments are substituted with parameter expansion only. There is no `eval`, and the substituted result is never re-parsed or re-split into words. A hostile entry value such as `; rm -rf ~` therefore arrives at the command as one inert argument string rather than as executable code.

Substitution is limited to variable names actually supplied by the named entries or by a `VAR=VALUE` assignment, so unrelated `{{...}}` text passes through untouched. Use `--no-expand` to disable substitution entirely.

### Session-Local Tracker

`_PASSENV_TRACKER` is session-local and reset on shell exit. Variables loaded with `passenv set` reflect the state of the store at the time of loading. If an entry is updated in the store, existing shells will not see the change until `passenv set` is run again in that shell. Multiple shells loading the same entry each maintain independent copies of the variables.

### Memory Residency

Decrypted pass entry content is held as a bash variable during parsing. Bash provides no mechanism to zero memory on `unset`. On Linux, the decrypted values remain in the process's virtual memory until reclaimed and are readable by same-user processes via `/proc/<pid>/mem`. Parsing reads the content through a pipe rather than a herestring, so it is never backed by a temporary file, which bash before 5.1 would otherwise create for every herestring.

For workloads where this matters, use `pass env run` to inject secrets into a subprocess rather than loading them into the shell with `passenv set`. Secrets are never stored in shell variables when using the `run` subcommand.

### Environment Visibility

Variables loaded with `passenv set` are visible in the process environment of any child process spawned from that shell. `pass env run` narrows that to the command and whatever it spawns in turn: the variables are still in the environment of every descendant of that command, and readable from `/proc/<pid>/environ` by any process running as you while they live. Use `run` to keep secrets out of the shell, not as isolation between the command and its own children.

### Umask

pass sets `umask 077` for its own files before it loads extensions, and a command started by `pass env run` would inherit that and create every file private. `passenv run` forwards your shell's umask to the command through `PASSENV_UMASK`. When calling `pass env run` directly, set `PASSENV_UMASK` yourself, or set `PASSWORD_STORE_UMASK`, which pass honours for everything it runs.

### Reporting

Report a vulnerability privately through GitHub's advisory form; see `SECURITY.md`.

## Testing

### Requirements

- `bats` (provided as a submodule)

### Execute Tests

```bash
git submodule update --init
test/extern/bats/bin/bats test/
# OR
make test
```
