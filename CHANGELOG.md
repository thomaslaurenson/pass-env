# Changelog

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
