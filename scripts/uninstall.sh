#!/usr/bin/env bash

# pass-env uninstaller
#
# Removes all files laid down by install.sh and strips the pass-env-init
# source block from ~/.bashrc / ~/.zshrc.
#
# Usage:
#   bash scripts/uninstall.sh [OPTIONS]
#
# OPTIONS:
#   --user              Remove user-local install (default)
#   --system            Remove system-wide install
#   -h, --help          Show this message

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

# Print a sub-step line to stdout.
#
# Arguments:
#   $1 - Message text
step()  { printf "  ${CYAN}-${NC} %s\n" "$1"; }

# Installation path variables; populated by resolve_paths().
EXTENSION_DIR=""
MAN_DIR=""
BASH_COMP_DIR=""
ZSH_COMP_DIR=""
INIT_SCRIPT_DIR=""

# Print usage information to stdout.
#
# Outputs:
#   stdout: usage text covering all flags and examples
# Returns:
#   0 always
show_help() {
  cat <<EOF
pass-env uninstall script

USAGE:
  bash uninstall.sh [OPTIONS]

OPTIONS:
  -h, --help    Show this message

EXAMPLES:
  bash uninstall.sh
EOF
}

# Parse command-line arguments.
#
# Arguments:
#   $@ - Command-line arguments forwarded from main
# Returns:
#   0 on success
#   exits 1 for unknown options
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_help; exit 0 ;;
      *) error "Unknown option: $1. Run with --help for usage." ;;
    esac
  done
}

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
# Mirror of install.sh — must stay in sync with that file. Populates
# EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, and INIT_SCRIPT_DIR.
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
# Uses sudo when the parent directory is not user-writable.
# Silent when the directory is absent or non-empty.
#
# Arguments:
#   $1 - Directory path to remove
# Outputs:
#   stdout: red [removed] line when the directory is deleted
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
  fi
}

# Run sed -i in a portable way across Linux and macOS.
#
# macOS sed requires an explicit (possibly empty) backup suffix with -i;
# GNU sed does not accept one when given as a separate argument.
#
# Arguments:
#   $1 - sed expression
#   $2 - File to edit in place
# Returns:
#   exit status of sed
portable_sed_inplace() {
  local expr="$1"
  local file="$2"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

# Sentinel strings used to locate the injected RC block.
RC_SENTINEL_BEGIN="# pass-env-init BEGIN"
RC_SENTINEL_END="# pass-env-init END"

# Remove the pass-env-init source block from a shell RC file.
#
# Deletes every line from the BEGIN sentinel through the END sentinel,
# inclusive. The blank line that precedes the block is left behind as a
# harmless empty line. Skips silently when the sentinel is absent.
#
# Arguments:
#   $1 - Path to the RC file (e.g. ~/.bashrc)
# Globals:
#   RC_SENTINEL_BEGIN, RC_SENTINEL_END - read for sentinel strings
# Outputs:
#   stdout: green [skipped] when absent; red [removed] when stripped
# Returns:
#   0 always
strip_rc_block() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 0

  if ! grep -qF "$RC_SENTINEL_BEGIN" "$rc_file"; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[skipped]${NC}\n" "$rc_file"
    return 0
  fi

  portable_sed_inplace "/^${RC_SENTINEL_BEGIN}/,/^${RC_SENTINEL_END}/d" "$rc_file"
  printf "  ${RED}-${NC} %s  ${RED}[removed]${NC}\n" "$rc_file"
}

# Main entry point. Resolves paths for both user and system installs and
# removes all installed components from each location.
#
# Arguments:
#   $@ - Command-line arguments
# Returns:
#   0 on success
#   exits 1 on any error
main() {
  parse_args "$@"

  local os
  os="$(detect_os)"

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

  info "pass-env uninstalled."
  warn "Restart your shell to deactivate shell integration."
}

main "$@"
