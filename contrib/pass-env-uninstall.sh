#!/usr/bin/env bash

# pass-env uninstaller
#
# Removes all files laid down by install.sh and strips the pass-env
# source block from ~/.bashrc / ~/.zshrc.
#
# Installed by install.sh to INIT_SCRIPT_DIR (e.g. ~/.local/share/pass-env/
# for user installs or /usr/local/share/pass-env/ for system installs).
#
# Usage:
#   bash /path/to/pass-env-uninstall.sh

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Print one tagged status line.
#
# Every line this script prints carries a leading uppercase tag in a fixed
# column, so a run can be read straight down its left edge. Anything a trailing
# marker used to convey, such as why a path was kept, belongs in the message
# instead: a tag per reason grows a vocabulary nobody can scan. Mirrors the
# helper of the same name in scripts/install.sh.
#
# Arguments:
#   $1 - Colour escape for the tag
#   $2 - Tag text, without brackets
#   $3 - Message text
status() {
  printf '%b[%s]%b%*s%s\n' "$1" "$2" "$NC" "$(( 9 - ${#2} ))" "" "$3"
}

# Print an info message to stdout.
#
# Arguments:
#   $1 - Message text
info()    { status "$GREEN"  INFO    "$1"; }

# Print a warning to stdout.
#
# Arguments:
#   $1 - Message text
warn()    { status "$YELLOW" WARN    "$1"; }

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $1 - Message text
# Returns:
#   exits 1
error()   { status "$RED"    ERROR   "$1" >&2; exit 1; }

# Print a line recording something removed from disk.
#
# Arguments:
#   $1 - Path that was removed
removed() { status "$RED"    REMOVED "$1"; }

# Print a line recording something left in place.
#
# Arguments:
#   $1 - Path or description
#   $2 - Short reason, shown in brackets after the path
kept()    { status "$YELLOW" KEPT    "$1 ($2)"; }

# Print a line recording something that needed no action.
#
# Arguments:
#   $1 - Path or description
#   $2 - Short reason, shown in brackets after the path
skipped() { status "$GREEN"  SKIPPED "$1 ($2)"; }

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

# Report whether a path lies inside one of the resolved install directories.
#
# Arguments:
#   $1 - Absolute path to test
# Globals:
#   EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, INIT_SCRIPT_DIR - read
# Returns:
#   0 when the path is under one of the directories, 1 otherwise
in_install_dirs() {
  local path="$1" dir
  for dir in "$EXTENSION_DIR" "$MAN_DIR" "$BASH_COMP_DIR" "$ZSH_COMP_DIR" "$INIT_SCRIPT_DIR"; do
    [[ -n "$dir" && "$path" == "${dir}/"* ]] && return 0
  done
  return 1
}

# Remove a file. Skips silently when the target does not exist.
#
# sudo is used only when the caller allows it and the parent directory is not
# user-writable. The caller decides per path rather than this function,
# because one of the inputs is the install manifest: for a user install it
# sits in the user's home, where anything running as that user can edit it,
# and a path it names must never become a root-level rm.
#
# Arguments:
#   $1 - File path to remove
#   $2 - "sudo" to permit escalation for this path, anything else to forbid it
# Outputs:
#   stdout: [SKIPPED] when absent, [REMOVED] when deleted, [KEPT] when the
#           directory is not writable and escalation is not permitted
# Returns:
#   0 always
maybe_rm() {
  local target="$1" policy="${2:-}"
  if [[ ! -e "$target" ]]; then
    skipped "$target" "not present"
    return 0
  fi
  if [[ -w "$(dirname "$target")" ]]; then
    rm -f "$target"
  elif [[ "$policy" == "sudo" ]]; then
    sudo rm -f "$target"
  else
    kept "$target" "not writable; remove it with sudo yourself"
    return 0
  fi
  removed "$target"
}

# Remove a directory only when it exists and is empty.
#
# Uses sudo when the parent directory is not user-writable. Prints
# [kept, not empty] when the directory exists but has other contents
# (e.g. extensions installed by other tools).
#
# Arguments:
#   $1 - Directory path to remove
# Outputs:
#   stdout: red [dir removed] when deleted; yellow [kept, not empty] when skipped
# Returns:
#   0 always
maybe_rmdir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  local removed=false
  if rmdir "$dir" 2>/dev/null; then
    removed=true
  elif [[ ! -w "$(dirname "$dir")" ]] && sudo rmdir "$dir" 2>/dev/null; then
    removed=true
  fi

  if [[ "$removed" == true ]]; then
    removed "$dir"
  else
    kept "$dir" "not empty"
  fi
}

# Rewrite a file in place through a temporary copy.
#
# The final write is a truncating redirection onto the original path, which
# follows a symlink and keeps the file's inode, owner and mode. sed -i would
# instead replace a symlinked ~/.bashrc with a plain file and leave the
# dotfiles target it pointed at untouched.
#
# Arguments:
#   $1 - sed expression
#   $2 - File to edit in place
# Returns:
#   0 on success, 1 when sed fails (the file is left unchanged)
rewrite_in_place() {
  local expr="$1"
  local file="$2"
  local tmp
  tmp="$(mktemp)" || return 1
  if ! sed "$expr" "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Remove every file listed in an install manifest, then the manifest itself.
#
# install.sh writes INIT_SCRIPT_DIR/install-manifest.txt with one absolute
# path per line for every file it installed. Removing from the manifest means
# the uninstaller deletes exactly what was installed, even if install paths
# change between versions. resolve_paths() removal below remains as a
# fallback for installs performed before the manifest existed.
#
# The manifest is data the uninstaller did not write, so it never decides on
# its own that a path may be removed as root. A user manifest never
# escalates; a system manifest escalates only for a path inside one of the
# system install directories resolved by the caller.
#
# Arguments:
#   $1 - Path to the manifest file
#   $2 - Install type the manifest belongs to: "user" or "system"
# Globals:
#   EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, INIT_SCRIPT_DIR - read
# Outputs:
#   stdout: [REMOVED]/[SKIPPED]/[KEPT] line per file
# Returns:
#   0 always (missing manifest is not an error)
remove_from_manifest() {
  local manifest="$1"
  local install_type="$2"
  [[ -f "$manifest" ]] || return 0
  info "Removing files listed in ${manifest}"
  local path policy
  while IFS= read -r path; do
    # Only absolute paths; ignore blank or malformed lines defensively.
    [[ -n "$path" && "$path" == /* ]] || continue
    policy=""
    if [[ "$install_type" == "system" ]] && in_install_dirs "$path"; then
      policy="sudo"
    fi
    maybe_rm "$path" "$policy"
  done < "$manifest"
  policy=""
  [[ "$install_type" == "system" ]] && policy="sudo"
  maybe_rm "$manifest" "$policy"
}

# Sentinel strings used to locate the injected RC block
readonly RC_SENTINEL_BEGIN="# pass-env-init BEGIN"
readonly RC_SENTINEL_END="# pass-env-init END"

# Sentinel strings used to locate the injected extensions export block
readonly EXT_SENTINEL_BEGIN="# pass-env-extensions BEGIN"
readonly EXT_SENTINEL_END="# pass-env-extensions END"

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
#   $4 - Optional human-readable label appended to the output line
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
  local label="${4:-}"
  local display
  display="$rc_file${label:+ (${label})}"

  if [[ ! -f "$rc_file" ]]; then
    skipped "$rc_file" "${label:+${label}, }file not found"
    return 0
  fi

  if ! grep -qF "$sentinel_begin" "$rc_file"; then
    skipped "$rc_file" "${label:+${label}, }not installed"
    return 0
  fi

  if ! grep -qF "$sentinel_end" "$rc_file"; then
    printf 'passenv: END sentinel missing in %s, manual cleanup required\n' "$rc_file" >&2
    return 1
  fi

  rewrite_in_place "/^${sentinel_begin}/,/^${sentinel_end}/d" "$rc_file" \
    || error "Failed to edit ${rc_file}"
  removed "$display"
}

# Print the home directory of a local user account.
#
# Consults the account database rather than expanding ~user through eval,
# which would hand the username to the shell as code. The name is checked
# against the portable username character set first for the same reason.
# Mirrors the helper of the same name in scripts/install.sh.
#
# Arguments:
#   $1 - Username
# Outputs:
#   stdout: absolute home directory path, or nothing when it cannot be found
# Returns:
#   0 when a home directory was printed
#   1 otherwise
user_home() {
  local user="$1" home=""
  [[ "${user}" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if command -v getent &>/dev/null; then
    home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)"
  elif command -v dscl &>/dev/null; then
    home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null \
      | awk '{print $2}')"
  else
    home="$(awk -F: -v u="${user}" '$1 == u {print $6}' /etc/passwd 2>/dev/null)"
  fi
  [[ -n "${home}" ]] || return 1
  printf '%s' "${home}"
}

# Main entry point. Resolves paths for both user and system installs and
# removes all installed components from each location.
#
# Returns:
#   0 on success
#   exits 1 on any error
main() {
  [[ $# -gt 0 ]] && error "This script takes no arguments. Run with no flags."

  # When run under sudo, HOME is typically /root (due to env_reset/always_set_home).
  # Resolve the invoking user's home so RC file cleanup targets the right files.
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    sudo_home="$(user_home "${SUDO_USER}")" || sudo_home=""
    if [[ -n "${sudo_home}" ]]; then
      warn "Running under sudo as user ${SUDO_USER}; using ${sudo_home} for shell integration cleanup."
      HOME="${sudo_home}"
    else
      error "Cannot determine home directory for user ${SUDO_USER}.
  Run without sudo: bash $0"
    fi
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    warn "Running as root. Shell integration will be removed from /root's RC files."
  fi

  local os
  os="$(detect_os)"

  info "Uninstalling pass-env"

  # Manifest-driven removal first (exact list written by install.sh), then
  # the mirrored-path fallback below (idempotent; already-removed files are
  # reported as [SKIPPED]). Only the system paths, which this script resolves
  # itself, may be removed with sudo.
  local install_type policy
  for install_type in user system; do
    resolve_paths "$os" "$install_type"
    remove_from_manifest "${INIT_SCRIPT_DIR}/install-manifest.txt" "$install_type"
  done

  for install_type in user system; do
    resolve_paths "$os" "$install_type"
    policy=""
    [[ "$install_type" == "system" ]] && policy="sudo"
    maybe_rm "${EXTENSION_DIR}/env.bash" "$policy"
    maybe_rmdir "$EXTENSION_DIR"
    maybe_rm "${MAN_DIR}/man1/pass-env.1" "$policy"
    maybe_rm "${BASH_COMP_DIR}/pass-env" "$policy"
    maybe_rm "${ZSH_COMP_DIR}/_pass-env" "$policy"
    maybe_rm "${INIT_SCRIPT_DIR}/pass-env-init.sh" "$policy"
    maybe_rm "${INIT_SCRIPT_DIR}/pass-env-uninstall.sh" "$policy"
    maybe_rmdir "$INIT_SCRIPT_DIR"
  done

  strip_rc_block "${HOME}/.bashrc" "$RC_SENTINEL_BEGIN"  "$RC_SENTINEL_END"  "init block"
  strip_rc_block "${HOME}/.zshrc"  "$RC_SENTINEL_BEGIN"  "$RC_SENTINEL_END"  "init block"
  strip_rc_block "${HOME}/.bashrc" "$EXT_SENTINEL_BEGIN" "$EXT_SENTINEL_END" "extensions block"
  strip_rc_block "${HOME}/.zshrc"  "$EXT_SENTINEL_BEGIN" "$EXT_SENTINEL_END" "extensions block"

  info "pass-env uninstalled."
  warn "Restart your shell to deactivate shell integration."
}

# Sourced by the test suite to reach the functions; run as a script otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
