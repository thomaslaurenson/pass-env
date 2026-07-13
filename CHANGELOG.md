# Changelog

## 0.3.0 - 2026-07-02

### Added

- `pass env run` accepts `{{VAR}}` placeholders in the command's arguments,
  substituted from the loaded entries after decryption. This makes an entry's
  variables usable as command *arguments*, which a bare `$VAR` cannot do (the
  calling shell expands it before `pass` runs, when the entry is not yet
  loaded, so it collapses to an empty string). `{{VAR}}` is inert to bash and
  zsh, so it needs no quoting:
  `pass env run api.env -- myapp --model {{SPARK_MODEL}}`.
  Only names supplied by the named entries or by a `VAR=VALUE` assignment are
  substituted; all other `{{...}}` text is left as written. Substitution uses
  parameter expansion only — never `eval` — and the result is not re-parsed or
  re-split, so a hostile store value cannot inject code
- `pass env run --no-expand` disables `{{VAR}}` substitution
- A leading `VAR=VALUE` assignment before COMMAND sets that variable for the
  command and overrides the entries, matching normal shell precedence
- `pass env set` output now includes a `# pass-env entry: NAME` marker per
  entry, so `passenv` tracks interactively (fzf) selected entries under their
  real names, including multi-select
- `passenv unset` restores variables to their pre-load values (previous value
  re-exported, or unset if the variable did not exist before loading);
  rollback on partial `passenv set` failure restores likewise
- Install script writes an `install-manifest.txt`; the uninstaller removes
  exactly the files listed in it (mirrored-path removal kept as fallback)
- Expanded dangerous-variable denylist: `HOME`, `SHELL`, `FPATH`, `ZDOTDIR`,
  `CDPATH`, `TMPDIR`, `GCONV_PATH`, `LOCPATH`, `TERMINFO`, pager/editor
  variables, command-executing `GIT_*` variables, `PYTHONSTARTUP`,
  `PYTHONHOME`, `PERL5OPT`, `RUBYOPT`, `NODE_PATH`, and Java options
  variables

### Fixed

- `pass env run ENTRY -- VAR=value COMMAND ...` now honors a leading
  `VAR=value` assignment before the command (e.g.
  `run api.env -- PASS=secret openai ...`). Previously the bare `exec` treated
  the assignment as the program name and failed with
  `exec: VAR=value: not found`
- Removed `--entry` from bash and zsh completions; the flag never existed and
  selecting it produced an error
- Install confirmation prompt reads from `/dev/tty`, fixing `curl | bash`
  installs run without `--yes`
- Replaced `mapfile` in the installer with a portable loop (macOS default
  `/bin/bash` 3.2 lacks `mapfile`)
- RC files created by the installer under `sudo` are now chowned to the
  invoking user instead of being left root-owned
- Pressing ESC in the fzf picker now prints "No entry selected." instead of
  exiting silently
- Traversal check now rejects only `..` path components rather than any `..`
  substring, so names like `a..b.env` work
- All extension functions and globals are namespaced (`_pass_env_*` /
  `PASSENV_*`); extensions are sourced into the pass process and previously
  shadowed pass's own `die()`

## 0.2.5 - 2026-06-30

### Added

- Blacklist of known bad keys potentially used for code injection
- Install script now errors when no SHA hashing tool available
- Install and uninstall scripts now refuse to install under root

### Fixed

- Removed potential command injection on bash completion helper
- Resolution of user's home directory when executed using sudo
- Improved symlink contaminated checks for store directory lookup
- Buffer fix for output on failed parse entry
- Repetitive code for store entry iterator
- Release workflow direct interpolation

## 0.2.4 - 2026-06-11

### Fixed

- General tidy and proof read

## 0.2.3 - 2026-05-15

### Fixed

- Fix export of env vars with special characters in run subcommand

### Updated

- Many style changes to bash codebase
- Makefile restructured to follow project conventions

## 0.2.2 - 2026-05-11

### Added

- Better error messages in pass env extension
- zsh integration test locally and in actions

### Fixed

- Removed eval for exporting vars
- Removed `PASS_CMD` usage
- Uninstaller script sentinel string detection

### Updated

- Man page

## 0.2.1 - 2026-04-08

### Added

- Tests for fzf integration using custom mock

### Fixed

- Bug in pass env run command not loading fzf list of entries

## 0.2.0 - 2026-04-06

### Added

- Dry-run mode and confirmation prompt for the install script
- Rollback when loading multiple entries partially fails
- Timeouts for all network calls in the install script
- Bash 4+ version guard in the shell loader
- Manual verification instructions to install script help
- macOS runner added to CI lint and test workflows

### Changed

- CRLF line endings are stripped from decrypted values
- Symlinked store entries are now included in listings
- Shell traps are preserved across interactive unset operations
- Sudo escalation is gated on system install mode only

### Fixed

- Fixed shell injection vulnerability in tracker entry removal
- Blocked path traversal outside the password store
- Secret values no longer leak into error messages
- fzf query handling when the search term contains spaces
- Release notes extraction no longer matches partial version numbers
- Checksum grep uses fixed-string matching

## 0.1.2 - 2026-03-19

### Added

- Added bash/zsh completion for passenv
- Added missing subcommands to pass env and passenv completion

### Changed

- Moved uninstall script to be included in install process

### Fixed

- `tmp_dir` error on install script
- Ensured same output format with arrows used everywhere

## 0.1.1 - 2026-03-15

### Added

- Install directly from a local repository, if running from repo clone
- Auto-detect whether `PASSWORD_STORE_ENABLE_EXTENSIONS=true` is required
- Added SHA-256 checksum verification

### Changed

- Install script now does a system install by default
- Always attempts removal of both user and system installs

### Fixed

- Fixed zsh completion directory location

## 0.1.0 - 2026-03-13

### Added

- Initial release
- Subcommands: `run`, `list`, `set` and `unset`
