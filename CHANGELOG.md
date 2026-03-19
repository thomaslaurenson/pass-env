# Changelog

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
