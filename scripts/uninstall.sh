#!/usr/bin/env bash

# pass-env uninstaller
#
# Removes all files laid down by install.sh and strips the pass-env
# source block from ~/.bashrc / ~/.zshrc.
#
# Usage:
#   bash scripts/uninstall.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Print an info message to stdout.
#
# Arguments:
#   $1 - Message text
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }

# Print a warning to stdout.
#
# Arguments:
#   $1 - Message text
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $1 - Message text
# Returns:
#   exits 1
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; exit 1; }

# Detected OS; set in main() and reused by portable_sed_inplace.
_OS=""

# Installation path variables; populated by resolve_paths().
EXTENSION_DIR=""
MAN_DIR=""
BASH_COMP_DIR=""
ZSH_COMP_DIR=""
INIT_SCRIPT_DIR=""

# Detect the current operating system.
#
# Outputs:
#   stdout: "linux" or "darwin"
# Returns:
#   0 on success
#   exits 1 for unsupported operating systems
detect_os() {
  case "$(uname -s)" in
    Linux*)  printf 'linux'  ;;
    Darwin*) printf 'darwin' ;;
    *)       error "Unsupported operating system: $(uname -s)" ;;
  esac
}

# Return the Homebrew prefix, or an empty string when brew is not installed.
#
# Outputs:
#   stdout: absolute brew prefix path, or empty string
# Returns:
#   0 always
brew_prefix() {
  if command -v brew &>/dev/null; then brew --prefix; else printf ''; fi
}

# Set installation path variables based on OS and install type.
#
# WARNING: This function is a mirror of resolve_paths() in install.sh.
# Any change to install paths in either file must be reflected in the other.
# Populates EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, and INIT_SCRIPT_DIR.
#
# Arguments:
#   $1 - OS string: "linux" or "darwin"
#   $2 - Install type: "user" or "system"
# Globals:
#   EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, INIT_SCRIPT_DIR - set
#   PASSWORD_STORE_DIR - read for user installs
# Returns:
#   0 always
resolve_paths() {
  local os="$1"
  local install_type="$2"

  if [[ "$install_type" == "user" ]]; then
    EXTENSION_DIR="${PASSWORD_STORE_DIR:-$HOME/.password-store}/.extensions"
    MAN_DIR="$HOME/.local/share/man"
    BASH_COMP_DIR="$HOME/.local/share/bash-completion/completions"
    ZSH_COMP_DIR="$HOME/.local/share/zsh/site-functions"
    INIT_SCRIPT_DIR="$HOME/.local/share/pass-env"
  else
    if [[ "$os" == "darwin" ]]; then
      local prefix
      prefix="$(brew_prefix)"
      if [[ -n "$prefix" ]]; then
        EXTENSION_DIR="${prefix}/lib/password-store/extensions"
        MAN_DIR="${prefix}/share/man"
        BASH_COMP_DIR="${prefix}/etc/bash_completion.d"
        ZSH_COMP_DIR="${prefix}/share/zsh/site-functions"
      else
        EXTENSION_DIR="/usr/local/lib/password-store/extensions"
        MAN_DIR="/usr/local/share/man"
        BASH_COMP_DIR="/usr/local/etc/bash_completion.d"
        ZSH_COMP_DIR="/usr/local/share/zsh/site-functions"
      fi
      INIT_SCRIPT_DIR="/usr/local/share/pass-env"
    else
      EXTENSION_DIR="/usr/lib/password-store/extensions"
      MAN_DIR="/usr/share/man"
      BASH_COMP_DIR="/etc/bash_completion.d"
      ZSH_COMP_DIR="/usr/local/share/zsh/site-functions"
      INIT_SCRIPT_DIR="/usr/local/share/pass-env"
    fi
  fi
}

# Remove a file, using sudo when the parent directory is not user-writable.
# Skips silently when the target does not exist.
#
# Arguments:
#   $1 - File path to remove
# Outputs:
#   stdout: green [skipped] line when absent; red [removed] line when deleted
# Returns:
#   0 always
maybe_rm() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[skipped]${NC}\n" "$target"
    return 0
  fi
  if [[ -w "$(dirname "$target")" ]]; then
    rm -f "$target"
  else
    sudo rm -f "$target"
  fi
  printf "  ${RED}-${NC} %s  ${RED}[removed]${NC}\n" "$target"
}

# Remove a directory only when it exists and is empty.
#
# Uses sudo when the parent directory is not user-writable. Prints
# [kept — not empty] when the directory exists but has other contents
# (e.g. extensions installed by other tools).
#
# Arguments:
#   $1 - Directory path to remove
# Outputs:
#   stdout: red [dir removed] when deleted; yellow [kept — not empty] when skipped
# Returns:
#   0 always
maybe_rmdir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  if [[ -z "$(ls -A "$dir")" ]]; then
    if [[ -w "$(dirname "$dir")" ]]; then
      rmdir "$dir"
    else
      sudo rmdir "$dir"
    fi
    printf "  ${RED}-${NC} %s  ${RED}[dir removed]${NC}\n" "$dir"
  else
    printf "  ${YELLOW}-${NC} %s  ${YELLOW}[kept — not empty]${NC}\n" "$dir"
  fi
}

# Run sed -i in a portable way across Linux and macOS.
#
# macOS sed requires an explicit (possibly empty) backup suffix with -i;
# GNU sed does not accept one when given as a separate argument.
# Uses the pre-detected $_OS global rather than re-invoking uname.
#
# Arguments:
#   $1 - sed expression
#   $2 - File to edit in place
# Globals:
#   _OS - read; "darwin" selects the macOS form
# Returns:
#   exit status of sed
portable_sed_inplace() {
  local expr="$1"
  local file="$2"
  if [[ "$_OS" == "darwin" ]]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

# Sentinel strings used to locate the injected RC block.
RC_SENTINEL_BEGIN="# pass-env-init BEGIN"
RC_SENTINEL_END="# pass-env-init END"

# Sentinel strings used to locate the injected extensions export block.
EXT_SENTINEL_BEGIN="# pass-env-extensions BEGIN"
EXT_SENTINEL_END="# pass-env-extensions END"

# Remove a guarded block from a shell RC file.
#
# Deletes every line from the BEGIN sentinel through the END sentinel,
# inclusive. Prints a distinct message for three outcomes: file absent,
# sentinel not found (block was never installed), and block removed.
#
# Arguments:
#   $1 - Path to the RC file (e.g. ~/.bashrc)
#   $2 - Begin sentinel string (default: RC_SENTINEL_BEGIN)
#   $3 - End sentinel string (default: RC_SENTINEL_END)
# Outputs:
#   stdout: green [file not found] when RC file absent
#           green [not installed] when file present but sentinel absent
#           red   [removed] when block is stripped
# Returns:
#   0 always
strip_rc_block() {
  local rc_file="$1"
  local sentinel_begin="${2:-$RC_SENTINEL_BEGIN}"
  local sentinel_end="${3:-$RC_SENTINEL_END}"

  if [[ ! -f "$rc_file" ]]; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[file not found]${NC}\n" "$rc_file"
    return 0
  fi

  if ! grep -qF "$sentinel_begin" "$rc_file"; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[not installed]${NC}\n" "$rc_file"
    return 0
  fi

  portable_sed_inplace "/^${sentinel_begin}/,/^${sentinel_end}/d" "$rc_file"
  printf "  ${RED}-${NC} %s  ${RED}[removed]${NC}\n" "$rc_file"
}

# Main entry point. Resolves paths for both user and system installs and
# removes all installed components from each location.
#
# Returns:
#   0 on success
#   exits 1 on any error
main() {
  [[ $# -gt 0 ]] && error "This script takes no arguments. Run with no flags."

  _OS="$(detect_os)"
  local os="$_OS"

  info "Uninstalling pass-env"

  for install_type in user system; do
    resolve_paths "$os" "$install_type"
    maybe_rm "${EXTENSION_DIR}/env.bash"
    maybe_rmdir "$EXTENSION_DIR"
    maybe_rm "${MAN_DIR}/man1/pass-env.1"
    maybe_rm "${BASH_COMP_DIR}/pass-env"
    maybe_rm "${ZSH_COMP_DIR}/_pass-env"
    maybe_rm "${INIT_SCRIPT_DIR}/pass-env-init.sh"
    maybe_rmdir "$INIT_SCRIPT_DIR"
  done

  strip_rc_block "${HOME}/.bashrc"
  strip_rc_block "${HOME}/.zshrc"
  strip_rc_block "${HOME}/.bashrc" "$EXT_SENTINEL_BEGIN" "$EXT_SENTINEL_END"
  strip_rc_block "${HOME}/.zshrc"  "$EXT_SENTINEL_BEGIN" "$EXT_SENTINEL_END"

  info "pass-env uninstalled."
  warn "Restart your shell to deactivate shell integration."
}

main "$@"
