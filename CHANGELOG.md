# Changelog

## 0.3.1 - 2026-08-14

### Fixed

- Reject shell metacharacters in entry names to prevent command injection

## 0.3.0 - 2026-07-02

### Added

- Expand {{VAR}} placeholders in run command arguments
- Add --no-expand to disable placeholder substitution
- Support a leading VAR=VALUE assignment before the command
- Emit a per-entry marker in set output so passenv tracks selected entries by name
- Restore variables to their pre-load values on passenv unset
- Write an install manifest and remove exactly the listed files on uninstall
- Expand the dangerous-variable denylist

### Fixed

- Remove the nonexistent --entry flag from bash and zsh completions
- Read the install confirmation prompt so curl-piped installs work without --yes
- Replace mapfile in the installer with a portable loop for bash 3.2
- Chown installer-created RC files to the invoking user under sudo
- Print "No entry selected" when the fzf picker is cancelled with ESC
- Reject only .. path components in the traversal check so names like a..b.env keep working

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
