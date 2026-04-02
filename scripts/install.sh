#!/usr/bin/env bash

# pass-env installer

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
step()  { printf "  ${CYAN} - ${NC} %s\n" "$1"; }

# Print a green [added] line for an installed file path.
#
# Arguments:
#   $1 - Destination file path
added() { printf "  ${GREEN}-${NC} %s  ${GREEN}[added]${NC}\n" "$1"; }

# Exit with an error if pass is not installed.
#
# Returns:
#   0 if pass is found
#   exits 1 if pass is not found
check_pass_installed() {
  command -v pass &>/dev/null || \
    error "pass is not installed or not in PATH. Install pass before running this script."
}

# User-settable options; populated by parse_args().
INSTALL_TYPE="system"  # user | system
NO_COMPLETION=false
NO_MAN=false
NO_INIT=false
NO_UNINSTALL=false
TAG=""

# Populated by detect_local_source(); non-empty means install from this path
# instead of downloading a release tarball.
LOCAL_SRC=""

# Set to true by detect_needs_enable_extensions() when PASSWORD_STORE_ENABLE_EXTENSIONS
# must be exported for the installed extension to be visible to pass.
NEEDS_ENABLE_EXTENSIONS=false

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
  --user              User-local install, no sudo required
  --system            System-wide install, may require sudo (default)
  --no-completion     Skip shell completion installation
  --no-man            Skip man page installation
  --no-init           Skip pass-env-init.sh shell integration
  --no-uninstall      Skip uninstall script installation

EXAMPLES:
  # Latest release, system install (default)
  bash install.sh

  # Pin to a specific version
  bash install.sh --tag v1.2.3

  # System-wide install
  bash install.sh --system

  # Minimal install: extension only
  bash install.sh --no-completion --no-man --no-init

SECURITY:
  When this script is piped directly from curl, it runs without giving you a
  chance to verify its contents first. For security-conscious installs:

    curl -fsSL .../install.sh -o /tmp/pass-env-install.sh
    curl -fsSL .../checksums.txt -o /tmp/pass-env-checksums.txt
    sha256sum --check --ignore-missing /tmp/pass-env-checksums.txt
    less /tmp/pass-env-install.sh
    bash /tmp/pass-env-install.sh
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
      --tag)           [[ $# -ge 2 ]] || error "--tag requires a version argument (e.g. --tag v1.2.3)"
                         TAG="$2"; shift 2 ;;
      --user)          INSTALL_TYPE="user";   shift ;;
      --system)        INSTALL_TYPE="system"; shift ;;
      --no-completion) NO_COMPLETION=true;    shift ;;
      --no-man)        NO_MAN=true;           shift ;;
      --no-init)       NO_INIT=true;          shift ;;
      --no-uninstall)  NO_UNINSTALL=true;     shift ;;
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

# Detect whether the script is being run from a local repository clone.
#
# If src/env.bash is found relative to this script's location, LOCAL_SRC is
# set to the repository root so the installer can skip the download step.
# When piped from curl, BASH_SOURCE[0] is empty or '/dev/stdin', so local-source
# detection is skipped to avoid silently installing from an arbitrary parent
# directory in the current working directory.
#
# Globals:
#   LOCAL_SRC - set to absolute repo root path, or left empty
# Returns:
#   0 always
detect_local_source() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || "$src" == "/dev/stdin" || "$src" == "bash" ]]; then
    return 0
  fi

  local script_dir
  script_dir="$(cd "$(dirname "$src")" && pwd)"
  local candidate="${script_dir}/.."
  if [[ -f "${candidate}/src/env.bash" ]]; then
    LOCAL_SRC="$(cd "$candidate" && pwd)"
  fi
}

# Determine whether PASSWORD_STORE_ENABLE_EXTENSIONS=true must be set.
#
# Reads the SYSTEM_EXTENSION_DIR value compiled into the pass binary. If
# EXTENSION_DIR matches that path, pass loads the extension unconditionally
# and the env var is not required. In all other cases (user dir, Homebrew
# prefix, custom dir) it is required.
#
# Globals:
#   EXTENSION_DIR           - read; compared against the compiled-in system dir
#   NEEDS_ENABLE_EXTENSIONS - set to true when the env var is required
# Returns:
#   0 always
detect_needs_enable_extensions() {
  local pass_bin sys_ext_dir
  pass_bin="$(command -v pass 2>/dev/null)" || return 0
  sys_ext_dir="$(grep -m1 '^SYSTEM_EXTENSION_DIR=' "$pass_bin" \
    | sed -E 's/SYSTEM_EXTENSION_DIR="?([^"]*).*/\1/')" || true
  if [[ -z "$sys_ext_dir" || "$EXTENSION_DIR" != "$sys_ext_dir" ]]; then
    NEEDS_ENABLE_EXTENSIONS=true
  fi
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

# Return the best system zsh site-functions directory on Linux.
#
# Probes known distribution paths in preference order and returns the first
# one that already exists on disk. Falls back to /usr/local/share/zsh/site-functions
# when none of the candidates are present yet.
#
# Outputs:
#   stdout: absolute path to the zsh site-functions directory
# Returns:
#   0 always
detect_zsh_comp_dir() {
  local candidates=(
    "/usr/share/zsh/site-functions"        # Fedora, Arch, openSUSE
    "/usr/share/zsh/vendor-completions"    # Debian, Ubuntu
    "/usr/local/share/zsh/site-functions"  # fallback
  )
  for dir in "${candidates[@]}"; do
    [[ -d "$dir" ]] && printf '%s' "$dir" && return
  done
  printf '%s' "${candidates[2]}"
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
      ZSH_COMP_DIR="$(detect_zsh_comp_dir)"
      INIT_SCRIPT_DIR="/usr/local/share/pass-env"
    fi
  fi
}

# Create a directory, using sudo only for system installs.
#
# For user installs, a non-writable directory is an error rather than a
# reason to silently escalate to sudo.
#
# Arguments:
#   $1 - Directory path to create
# Globals:
#   INSTALL_TYPE - read; sudo is only attempted when INSTALL_TYPE=="system"
# Returns:
#   0 on success
maybe_mkdir() {
  local dir="$1"
  if mkdir -p "$dir" 2>/dev/null; then
    return 0
  fi
  if [[ "$INSTALL_TYPE" == "system" ]]; then
    sudo mkdir -p "$dir" || error "Failed to create directory: $dir"
  else
    error "Failed to create directory: $dir (check permissions, or use --system for a system install)"
  fi
}

# Install a file to a destination path, using sudo only for system installs.
#
# For user installs, a non-writable destination directory is an error rather
# than a reason to silently escalate to sudo.
#
# Arguments:
#   $1 - File permission mode (e.g. 0644, 0755)
#   $2 - Source file path
#   $3 - Destination file path (full path including filename)
# Globals:
#   INSTALL_TYPE - read; sudo is only attempted when INSTALL_TYPE=="system"
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
  elif [[ "$INSTALL_TYPE" == "system" ]]; then
    sudo install -m "$mode" "$src" "$dest"
  else
    error "Cannot write to $dest_dir (check permissions, or use --system for a system install)"
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

  # When running from a local clone, read VERSION directly from src/env.bash.
  if [[ -n "$LOCAL_SRC" ]]; then
    local raw
    raw="$(grep '^VERSION=' "${LOCAL_SRC}/src/env.bash" | sed -E 's/VERSION="(.*)"/\1/')"
    [[ -z "$raw" ]] && error "Could not read VERSION from ${LOCAL_SRC}/src/env.bash"
    VERSION="v${raw}"
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

# Download and verify the SHA-256 checksum of a release tarball.
#
# Downloads checksums.txt from the same release, locates the entry for the
# tarball filename, and compares it against the local file. Skips verification
# with a warning when neither sha256sum nor shasum is available.
#
# Arguments:
#   $1 - Version tag (e.g. v1.2.3)
#   $2 - Local path to the downloaded tarball
# Globals:
#   BASE_URL - read for the download URL prefix
# Returns:
#   0 on success
#   exits 1 if the hash does not match or checksums.txt cannot be downloaded
verify_checksum() {
  local version="$1"
  local tarball="$2"
  local tarball_name
  tarball_name="$(basename "$tarball")"

  local sum_cmd=""
  if command -v sha256sum &>/dev/null; then
    sum_cmd="sha256sum"
  elif command -v shasum &>/dev/null; then
    sum_cmd="shasum -a 256"
  else
    warn "sha256sum/shasum not found; skipping checksum verification."
    return 0
  fi

  info "Verifying checksum..."
  local checksums_url="${BASE_URL}/download/${version}/checksums.txt"
  local checksums_file="${tarball%/*}/checksums.txt"

  if command -v curl &>/dev/null; then
    curl -fsSL "$checksums_url" -o "$checksums_file" \
      || error "Failed to download checksums.txt: $checksums_url"
  elif command -v wget &>/dev/null; then
    wget -qO "$checksums_file" "$checksums_url" \
      || error "Failed to download checksums.txt: $checksums_url"
  else
    error "curl or wget is required"
  fi

  local expected_hash
  expected_hash="$(grep " ${tarball_name}$" "$checksums_file" | awk '{print $1}')"
  [[ -n "$expected_hash" ]] \
    || error "No checksum entry found for ${tarball_name} in checksums.txt"

  local actual_hash
  actual_hash="$(${sum_cmd} "$tarball" | awk '{print $1}')"

  if [[ "$actual_hash" != "$expected_hash" ]]; then
    error "Checksum mismatch for ${tarball_name}:
  expected: ${expected_hash}
  actual:   ${actual_hash}"
  fi
  step "SHA-256 OK"
}

# Verify that all expected source files are present in a directory.
#
# Called after extracting a release tarball or pointing at a local clone to
# catch incomplete downloads or wrong tarball structures early, before any
# files are installed.
#
# Arguments:
#   $1 - Source directory root to check
# Returns:
#   0 if all required files are present
#   exits 1 if any expected file is missing
validate_src_dir() {
  local dir="$1"
  local required=(
    "src/env.bash"
    "man/pass-env.1"
    "completion/pass-env.bash.completion"
    "completion/_pass-env"
    "contrib/pass-env-init.sh"
    "contrib/pass-env-uninstall.sh"
  )
  for rel in "${required[@]}"; do
    [[ -f "${dir}/${rel}" ]] \
      || error "Expected file not found in source: ${dir}/${rel}"
  done
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

# Sentinel strings used to bracket the injected PASSWORD_STORE_ENABLE_EXTENSIONS block.
EXT_SENTINEL_BEGIN="# pass-env-extensions BEGIN"
EXT_SENTINEL_END="# pass-env-extensions END"

# Append a guarded source block for pass-env-init.sh to a shell RC file.
#
# The block is wrapped in BEGIN/END sentinel comments so the uninstaller can
# find and remove it. The operation is idempotent: if the sentinel is already
# present the file is left unchanged. If the RC file does not exist it is
# created with an info message.
#
# Arguments:
#   $1 - Path to the RC file (e.g. ~/.bashrc)
#   $2 - Absolute path to pass-env-init.sh for the source line
# Globals:
#   RC_SENTINEL_BEGIN, RC_SENTINEL_END - read for sentinel strings
# Outputs:
#   stdout: info message if file is created; [skipped] or [added] line
# Returns:
#   0 always
inject_rc() {
  local rc_file="$1"
  local init_script_path="$2"

  if [[ ! -f "$rc_file" ]]; then
    info "Creating ${rc_file}"
    touch "$rc_file"
  fi

  if grep -qF "$RC_SENTINEL_BEGIN" "$rc_file"; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[skipped]${NC}\n" "$rc_file"
    return 0
  fi

  cat >> "$rc_file" <<EOF

${RC_SENTINEL_BEGIN}
# Added by pass-env installer. Remove this block, or run uninstall.sh, to undo.
[[ -f "${init_script_path}" ]] && source "${init_script_path}"
${RC_SENTINEL_END}
EOF
  printf "  ${GREEN}-${NC} %s  ${GREEN}[added]${NC}\n" "$rc_file"
}

# Append a guarded export block for PASSWORD_STORE_ENABLE_EXTENSIONS to a
# shell RC file.
#
# Uses its own sentinel pair so it can be managed independently of the
# pass-env-init block. Idempotent: skips if the sentinel is already present.
# If the RC file does not exist it is created with an info message.
#
# Arguments:
#   $1 - Path to the RC file (e.g. ~/.bashrc)
# Globals:
#   EXT_SENTINEL_BEGIN, EXT_SENTINEL_END - read for sentinel strings
# Outputs:
#   stdout: info message if file is created; green [added] or [skipped] line
# Returns:
#   0 always
inject_extensions_rc() {
  local rc_file="$1"

  if [[ ! -f "$rc_file" ]]; then
    info "Creating ${rc_file}"
    touch "$rc_file"
  fi

  if grep -qF "$EXT_SENTINEL_BEGIN" "$rc_file"; then
    printf "  ${GREEN}-${NC} %s  ${GREEN}[skipped]${NC}\n" "$rc_file"
    return 0
  fi

  cat >> "$rc_file" <<EOF

${EXT_SENTINEL_BEGIN}
# Added by pass-env installer. Required for pass to load user-dir extensions.
export PASSWORD_STORE_ENABLE_EXTENSIONS=true
${EXT_SENTINEL_END}
EOF
  printf "  ${GREEN}-${NC} %s  ${GREEN}[added]${NC}\n" "$rc_file"
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
  info "$(printf '%-24s %s' "pass-env version:"  "$version")"
  info "$(printf '%-24s %s' "Install type:"      "$INSTALL_TYPE")"
  info "$(printf '%-24s %s' "OS:"                "$os")"
  info "$(printf '%-24s %s' "Extension dir:"     "$EXTENSION_DIR")"
  [[ "$NO_MAN" == false ]]        && info "$(printf '%-24s %s' "Man dir:"           "${MAN_DIR}/man1")"
  [[ "$NO_COMPLETION" == false ]] && info "$(printf '%-24s %s' "Bash completion:"   "$BASH_COMP_DIR")"
  [[ "$NO_COMPLETION" == false ]] && info "$(printf '%-24s %s' "Zsh completion:"    "$ZSH_COMP_DIR")"
  [[ "$NO_INIT" == false ]]       && info "$(printf '%-24s %s' "Init script dir:"   "$INIT_SCRIPT_DIR")"
  [[ "$NO_UNINSTALL" == false ]]  && info "$(printf '%-24s %s' "Uninstall script:"  "${INIT_SCRIPT_DIR}/pass-env-uninstall.sh")"
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

  check_pass_installed

  local os
  os="$(detect_os)"

  detect_local_source
  resolve_version
  [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || error "Invalid version format: ${VERSION}"
  resolve_paths "$os" "$INSTALL_TYPE"
  detect_needs_enable_extensions
  show_summary "$VERSION" "$os"

  local src_dir

  if [[ -n "$LOCAL_SRC" ]]; then
    info "Installing from local source: ${LOCAL_SRC}"
    src_dir="$LOCAL_SRC"
  else
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' EXIT INT TERM

    local tarball="${tmp_dir}/pass-env-${VERSION}.tar.gz"
    download_tarball "$VERSION" "$tarball"
    verify_checksum  "$VERSION" "$tarball"

    info "Extracting archive..."
    tar -xzf "$tarball" -C "$tmp_dir" || error "Failed to extract archive"

    # Assert the tarball contained exactly one top-level directory.
    # head -1 would silently pick the first if there were multiple, masking a
    # malformed or unexpected tarball structure.
    local -a extracted_dirs
    mapfile -t extracted_dirs < <(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d)
    [[ ${#extracted_dirs[@]} -eq 1 ]] \
      || error "Expected exactly 1 top-level directory in archive, found ${#extracted_dirs[@]}"
    src_dir="${extracted_dirs[0]}"
  fi

  validate_src_dir "$src_dir"

  # Detect shells once; reused for completions, init, and extensions steps.
  local shells
  shells="$(detect_shells)"
  if [[ -z "$shells" ]]; then
    warn "Could not detect a supported shell; skipping completion and shell integration."
  fi

  # 1. Install the pass extension.
  maybe_mkdir "$EXTENSION_DIR"
  maybe_install 0755 "${src_dir}/src/env.bash" "${EXTENSION_DIR}/env.bash"
  added "${EXTENSION_DIR}/env.bash"

  # 2. Install the man page.
  if [[ "$NO_MAN" == false ]]; then
    maybe_mkdir "${MAN_DIR}/man1"
    maybe_install 0644 "${src_dir}/man/pass-env.1" "${MAN_DIR}/man1/pass-env.1"
    added "${MAN_DIR}/man1/pass-env.1"
  fi

  # 3. Install shell completion.
  if [[ "$NO_COMPLETION" == false ]]; then
    if [[ "$shells" == *"bash"* ]]; then
      maybe_mkdir "$BASH_COMP_DIR"
      maybe_install 0644 \
        "${src_dir}/completion/pass-env.bash.completion" \
        "${BASH_COMP_DIR}/pass-env"
      added "${BASH_COMP_DIR}/pass-env"
    fi

    if [[ "$shells" == *"zsh"* ]]; then
      maybe_mkdir "$ZSH_COMP_DIR"
      maybe_install 0644 \
        "${src_dir}/completion/_pass-env" \
        "${ZSH_COMP_DIR}/_pass-env"
      added "${ZSH_COMP_DIR}/_pass-env"
    fi
  fi

  # 4. Install shell integration (pass-env-init.sh) and uninstall script.
  # Create INIT_SCRIPT_DIR when either component will be installed.
  if [[ "$NO_INIT" == false || "$NO_UNINSTALL" == false ]]; then
    maybe_mkdir "$INIT_SCRIPT_DIR"
  fi

  if [[ "$NO_INIT" == false ]]; then
    maybe_install 0644 \
      "${src_dir}/contrib/pass-env-init.sh" \
      "${INIT_SCRIPT_DIR}/pass-env-init.sh"
    added "${INIT_SCRIPT_DIR}/pass-env-init.sh"

    local init_path="${INIT_SCRIPT_DIR}/pass-env-init.sh"

    [[ "$shells" == *"bash"* ]] && inject_rc "${HOME}/.bashrc" "$init_path"
    [[ "$shells" == *"zsh"* ]]  && inject_rc "${HOME}/.zshrc"  "$init_path"
  fi

  # 5. Install the uninstall script.
  if [[ "$NO_UNINSTALL" == false ]]; then
    maybe_install 0755 \
      "${src_dir}/contrib/pass-env-uninstall.sh" \
      "${INIT_SCRIPT_DIR}/pass-env-uninstall.sh"
    added "${INIT_SCRIPT_DIR}/pass-env-uninstall.sh"
  fi

  # 6. Inject PASSWORD_STORE_ENABLE_EXTENSIONS into RC file(s) if required.
  if [[ "$NEEDS_ENABLE_EXTENSIONS" == true ]]; then
    if [[ "$NO_INIT" == false ]]; then
      [[ "$shells" == *"bash"* ]] && inject_extensions_rc "${HOME}/.bashrc"
      [[ "$shells" == *"zsh"* ]]  && inject_extensions_rc "${HOME}/.zshrc"
    else
      warn "PASSWORD_STORE_ENABLE_EXTENSIONS=true is required for pass to load"
      warn "this extension. Add the following line to your shell RC file:"
      warn "  export PASSWORD_STORE_ENABLE_EXTENSIONS=true"
    fi
  fi

  info "pass-env ${VERSION} installed successfully!"

  if [[ "$NO_UNINSTALL" == false ]]; then
    info "To uninstall, run: bash ${INIT_SCRIPT_DIR}/pass-env-uninstall.sh"
  fi

  if [[ "$NO_INIT" == false ]]; then
    warn "Restart your shell (or source the relevant RC file) to activate shell integration."
  fi
}

main "$@"
