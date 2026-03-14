#!/usr/bin/env bash

# pass-env installer
#
# Usage (release channel — curl to bash):
#   curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/download/vX.Y.Z/install.sh | bash
#   curl -fsSL https://github.com/thomaslaurenson/pass-env/releases/download/vX.Y.Z/install.sh | bash -s -- --system
#
# Usage (local clone):
#   bash scripts/install.sh [OPTIONS]

set -euo pipefail

# VERSION is baked in at release time by the release workflow (e.g. via sed).
# The placeholder "v0.0.0" triggers an automatic latest-release lookup when
# running an un-baked copy of the script.
VERSION="v0.0.0"
REPO="thomaslaurenson/pass-env"
BASE_URL="https://github.com/${REPO}/releases"

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
step()  { printf "  ${CYAN}→${NC} %s\n" "$1"; }

# User-settable options; populated by parse_args().
INSTALL_TYPE="user"    # user | system
NO_COMPLETION=false
NO_MAN=false
NO_INIT=false
TAG=""

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
pass-env install script

USAGE:
  bash install.sh [OPTIONS]

OPTIONS:
  -h, --help          Show this message
  --tag TAG           Install a specific release tag (e.g. v1.2.3)
  --user              User-local install, no sudo required (default)
  --system            System-wide install, may require sudo
  --no-completion     Skip shell completion installation
  --no-man            Skip man page installation
  --no-init           Skip pass-env-init.sh shell integration

EXAMPLES:
  # Latest release, user install (default)
  bash install.sh

  # Pin to a specific version
  bash install.sh --tag v1.2.3

  # System-wide install
  bash install.sh --system

  # Minimal install: extension only
  bash install.sh --no-completion --no-man --no-init
EOF
}

# Parse command-line arguments and set global option variables.
#
# Arguments:
#   $@ - Command-line arguments forwarded from main
# Globals:
#   TAG, INSTALL_TYPE, NO_COMPLETION, NO_MAN, NO_INIT - updated
# Returns:
#   0 on success
#   exits 1 for unknown options
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)       show_help; exit 0 ;;
      --tag)           TAG="$2"; shift 2 ;;
      --user)          INSTALL_TYPE="user";   shift ;;
      --system)        INSTALL_TYPE="system"; shift ;;
      --no-completion) NO_COMPLETION=true;    shift ;;
      --no-man)        NO_MAN=true;           shift ;;
      --no-init)       NO_INIT=true;          shift ;;
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
# Populates EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR, and
# INIT_SCRIPT_DIR. On macOS system installs, Homebrew paths are preferred
# when brew is available.
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
    # System install — use Homebrew paths on macOS where available.
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

# Create a directory, using sudo when the parent is not user-writable.
#
# Arguments:
#   $1 - Directory path to create
# Returns:
#   0 on success
maybe_mkdir() {
  local dir="$1"
  mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir"
}

# Install a file to a destination path, using sudo when the destination
# directory is not user-writable.
#
# Arguments:
#   $1 - File permission mode (e.g. 0644, 0755)
#   $2 - Source file path
#   $3 - Destination file path (full path including filename)
# Returns:
#   0 on success
maybe_install() {
  local mode="$1"
  local src="$2"
  local dest="$3"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  if [[ -w "$dest_dir" ]]; then
    install -m "$mode" "$src" "$dest"
  else
    sudo install -m "$mode" "$src" "$dest"
  fi
}

# Resolve the release version to install.
#
# Applies the following priority: --tag flag > baked-in VERSION > latest GitHub
# release. The "v0.0.0" placeholder triggers an API lookup; any other value
# (set by the release workflow via sed) is used as-is.
#
# Globals:
#   TAG     - read; overrides VERSION when non-empty
#   VERSION - updated with the resolved version tag
#   REPO    - read for the GitHub API URL
# Returns:
#   0 on success
#   exits 1 if the version cannot be determined
resolve_version() {
  if [[ -n "$TAG" ]]; then
    VERSION="${TAG#v}"
    VERSION="v${VERSION}"
    return
  fi

  # If the placeholder is still present, query the GitHub API for the latest
  # published release tag.
  if [[ "$VERSION" == "v0.0.0" ]]; then
    info "Fetching latest release version..."
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
      VERSION="$(curl -fsSL "$api_url" \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    elif command -v wget &>/dev/null; then
      VERSION="$(wget -qO- "$api_url" \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    else
      error "curl or wget is required"
    fi
    [[ -z "$VERSION" ]] && error "Could not determine the latest release version"
  fi
}

# Download the release tarball for a given version.
#
# Uses curl when available, falling back to wget. The tarball URL is formed as:
# BASE_URL/download/<version>/pass-env-<version>.tar.gz
#
# Arguments:
#   $1 - Version tag (e.g. v1.2.3)
#   $2 - Destination file path for the downloaded tarball
# Globals:
#   BASE_URL - read for the download URL prefix
# Returns:
#   0 on success
#   exits 1 if the download fails or neither curl nor wget is available
download_tarball() {
  local version="$1"
  local dest="$2"
  local url="${BASE_URL}/download/${version}/pass-env-${version}.tar.gz"

  info "Downloading pass-env ${version}..."
  step "$url"

  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest" || error "Download failed: $url"
  elif command -v wget &>/dev/null; then
    wget -qO "$dest" "$url" || error "Download failed: $url"
  else
    error "curl or wget is required"
  fi
}

# Detect which shells to configure based on the running shell and RC files.
#
# Returns a space-separated list of shell names ("bash", "zsh", or both). When
# the current shell is bash, zsh is also included if ~/.zshrc already exists,
# and vice versa. Falls back to checking PATH when the calling shell is unknown.
#
# Globals:
#   SHELL - read to identify the current shell
#   HOME  - read to locate RC files
# Outputs:
#   stdout: space-separated shell list, e.g. "bash zsh" or "bash"
# Returns:
#   0 always
detect_shells() {
  local shells=""
  local current_shell
  current_shell="$(basename "${SHELL:-}")"

  case "$current_shell" in
    bash)
      shells="bash"
      [[ -f "${HOME}/.zshrc" ]] && shells="bash zsh"
      ;;
    zsh)
      shells="zsh"
      [[ -f "${HOME}/.bashrc" ]] && shells="bash zsh"
      ;;
    *)
      command -v bash &>/dev/null && shells="${shells} bash"
      command -v zsh  &>/dev/null && shells="${shells} zsh"
      shells="${shells# }"
      ;;
  esac

  printf '%s' "$shells"
}

# Sentinel strings used to bracket the injected RC block.
RC_SENTINEL_BEGIN="# pass-env-init BEGIN"
RC_SENTINEL_END="# pass-env-init END"

# Append a guarded source block for pass-env-init.sh to a shell RC file.
#
# The block is wrapped in BEGIN/END sentinel comments so the uninstaller can
# find and remove it. The operation is idempotent: if the sentinel is already
# present the file is left unchanged.
#
# Arguments:
#   $1 - Path to the RC file (e.g. ~/.bashrc)
#   $2 - Absolute path to pass-env-init.sh for the source line
# Globals:
#   RC_SENTINEL_BEGIN, RC_SENTINEL_END - read for sentinel strings
# Outputs:
#   stdout: status message via step()
# Returns:
#   0 always
inject_rc() {
  local rc_file="$1"
  local init_script_path="$2"

  [[ -f "$rc_file" ]] || touch "$rc_file"

  if grep -qF "$RC_SENTINEL_BEGIN" "$rc_file"; then
    step "$(basename "$rc_file"): pass-env-init already present — skipping"
    return 0
  fi

  cat >> "$rc_file" <<EOF

${RC_SENTINEL_BEGIN}
# Added by pass-env installer. Remove this block, or run uninstall.sh, to undo.
[[ -f "${init_script_path}" ]] && source "${init_script_path}"
${RC_SENTINEL_END}
EOF
  step "Injected source line into ${rc_file}"
}

# Print a pre-install summary of resolved paths and options.
#
# Arguments:
#   $1 - Resolved version string (e.g. v1.2.3)
#   $2 - OS string (e.g. linux, darwin)
# Globals:
#   INSTALL_TYPE, EXTENSION_DIR, MAN_DIR, BASH_COMP_DIR, ZSH_COMP_DIR,
#   INIT_SCRIPT_DIR, NO_MAN, NO_COMPLETION, NO_INIT - read
# Outputs:
#   stdout: formatted summary table
# Returns:
#   0 always
show_summary() {
  local version="$1"
  local os="$2"
  printf '\n'
  printf '  %-24s %s\n' "pass-env version:"  "$version"
  printf '  %-24s %s\n' "Install type:"      "$INSTALL_TYPE"
  printf '  %-24s %s\n' "OS:"                "$os"
  printf '  %-24s %s\n' "Extension dir:"     "$EXTENSION_DIR"
  [[ "$NO_MAN" == false ]]        && printf '  %-24s %s\n' "Man dir:"         "${MAN_DIR}/man1"
  [[ "$NO_COMPLETION" == false ]] && printf '  %-24s %s\n' "Bash completion:" "$BASH_COMP_DIR"
  [[ "$NO_COMPLETION" == false ]] && printf '  %-24s %s\n' "Zsh completion:"  "$ZSH_COMP_DIR"
  [[ "$NO_INIT" == false ]]       && printf '  %-24s %s\n' "Init script dir:" "$INIT_SCRIPT_DIR"
  printf '\n'
}

# Main entry point. Parses arguments, resolves version and paths, downloads
# the release tarball, and installs all requested components.
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

  resolve_version
  resolve_paths "$os" "$INSTALL_TYPE"
  show_summary "$VERSION" "$os"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  local tarball="${tmp_dir}/pass-env-${VERSION}.tar.gz"
  download_tarball "$VERSION" "$tarball"

  info "Extracting archive..."
  tar -xzf "$tarball" -C "$tmp_dir"

  local src_dir
  src_dir="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [[ -d "$src_dir" ]] || error "Could not locate extracted source directory"

  # 1. Install the pass extension.
  info "Installing pass extension..."
  maybe_mkdir "$EXTENSION_DIR"
  maybe_install 0755 "${src_dir}/src/env.bash" "${EXTENSION_DIR}/env.bash"
  step "env.bash  →  ${EXTENSION_DIR}/env.bash"

  # 2. Install the man page.
  if [[ "$NO_MAN" == false ]]; then
    info "Installing man page..."
    maybe_mkdir "${MAN_DIR}/man1"
    maybe_install 0644 "${src_dir}/man/pass-env.1" "${MAN_DIR}/man1/pass-env.1"
    step "pass-env.1  →  ${MAN_DIR}/man1/pass-env.1"
  fi

  # 3. Install shell completion.
  if [[ "$NO_COMPLETION" == false ]]; then
    info "Installing shell completion..."
    local shells
    shells="$(detect_shells)"

    if [[ "$shells" == *"bash"* ]]; then
      maybe_mkdir "$BASH_COMP_DIR"
      maybe_install 0644 \
        "${src_dir}/completion/pass-env.bash.completion" \
        "${BASH_COMP_DIR}/pass-env"
      step "bash completion  →  ${BASH_COMP_DIR}/pass-env"
    fi

    if [[ "$shells" == *"zsh"* ]]; then
      maybe_mkdir "$ZSH_COMP_DIR"
      maybe_install 0644 \
        "${src_dir}/completion/_pass-env" \
        "${ZSH_COMP_DIR}/_pass-env"
      step "zsh completion  →  ${ZSH_COMP_DIR}/_pass-env"
    fi
  fi

  # 4. Install shell integration (pass-env-init.sh).
  if [[ "$NO_INIT" == false ]]; then
    info "Installing shell integration..."
    maybe_mkdir "$INIT_SCRIPT_DIR"
    maybe_install 0644 \
      "${src_dir}/contrib/pass-env-init.sh" \
      "${INIT_SCRIPT_DIR}/pass-env-init.sh"
    step "pass-env-init.sh  →  ${INIT_SCRIPT_DIR}/pass-env-init.sh"

    info "Injecting source line into shell RC file(s)..."
    local shells
    shells="$(detect_shells)"
    local init_path="${INIT_SCRIPT_DIR}/pass-env-init.sh"

    [[ "$shells" == *"bash"* ]] && inject_rc "${HOME}/.bashrc" "$init_path"
    [[ "$shells" == *"zsh"* ]]  && inject_rc "${HOME}/.zshrc"  "$init_path"
  fi

  printf '\n'
  info "pass-env ${VERSION} installed successfully!"

  if [[ "$NO_INIT" == false ]]; then
    printf '\n'
    warn "Restart your shell (or source the relevant RC file) to activate shell integration."
  fi
}

main "$@"
