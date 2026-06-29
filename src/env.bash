#!/usr/bin/env bash

# pass extension: env
#
# Requires:
# pass with the env extension
# gpg (bundled with pass)
# fzf (optional, for interactive selection)

set -euo pipefail

readonly VERSION="0.2.4"

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $@ - Error message text
# Outputs:
#   stderr: formatted error message prefixed with 'pass env:'
# Returns:
#   exits 1 (does not return to the caller)
die() { printf 'pass env: %s\n' "$*" >&2; exit 1; }

# Verify that a .gpg file's canonical (symlink-resolved) path stays within
# the password store directory. Prevents symlink attacks where a .gpg file
# inside the store points to arbitrary files outside the store.
#
# Arguments:
#   $1 - Path to the .gpg file (absolute)
#   $2 - Password store directory (absolute)
# Returns:
#   0 if the resolved path is within the store
#   1 if the resolved path escapes the store or cannot be resolved
_is_entry_in_store() {
  local gpg_file="$1"
  local password_store_dir="$2"
  local real_file real_store
  real_file="$(realpath -- "${gpg_file}")" || return 1
  real_store="$(realpath -- "${password_store_dir}")" || return 1
  # The trailing / prevents prefix false positives (e.g. /store/foo matching /store_foo/bar).
  [[ "${real_file}" == "${real_store}/"* ]]
}

# Check whether a variable name is dangerous to set from an untrusted entry.
#
# Some environment variables cause code execution or change interpreter
# behaviour simply by being set (e.g. PATH hijacks binary resolution,
# LD_PRELOAD injects shared objects, PROMPT_COMMAND runs before each prompt).
# A denylist is never complete, but it blocks the most common attack vectors.
#
# Arguments:
#   $1 - Variable name to check
# Returns:
#   0 if the name is dangerous
#   1 if the name is safe
_is_dangerous_var() {
  case "$1" in
    PATH|IFS|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|\
    PROMPT_COMMAND|PS1|PS2|PS3|PS4|\
    GLOBIGNORE|RANDOM|LINENO|PIPESTATUS|DIRSTACK)
      return 0 ;;
    LD_*|DYLD_*)
      return 0 ;;
    PYTHONPATH|PERL5LIB|RUBYLIB|NODE_OPTIONS)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Present an interactive fzf picker of all .env entries in the password store.
#
# Supports TAB-based multi-selection (fzf --multi). Prints selected entry
# path(s) one per line, with the .gpg suffix removed. Dies if fzf is not
# installed.
#
# Arguments:
#   $1 - Optional seed query pre-filled in the fzf prompt (default: empty)
# Environment:
#   PASSWORD_STORE_DIR - root of the password store (default: ~/.password-store)
# Outputs:
#   stdout: selected entry path(s), one per line (no .gpg suffix)
# Returns:
#   0 on successful selection
#   non-zero if fzf exits with an error or the user presses ESC
_fzf_select_entry() {
  local query="${1:-}"
  if ! command -v fzf &>/dev/null; then
    die "ENTRY is required (fzf not installed for interactive selection)"
  fi
  local password_store_dir="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
  local fzf_args=(
    --multi
    --height=40%
    --layout=reverse
    --border
    --prompt="Pass entry: "
    --header="ENTER: select one  |  TAB+ENTER: select multiple  |  ESC: cancel"
  )
  [[ -n "${query}" ]] && fzf_args+=("--query=${query}")
  [[ -d "${password_store_dir}" ]] \
    || die "password store not found: ${password_store_dir} (has pass been initialised?)"
  find "${password_store_dir}" -name "*.env.gpg" \( -type f -o -type l \) \
    | while IFS= read -r f; do
      # Skip symlinks that resolve outside the password store.
      _is_entry_in_store "${f}" "${password_store_dir}" || continue
      printf '%s\n' "${f#"${password_store_dir}/"}"
    done \
    | sed 's/\.gpg$//' \
    | sort \
    | fzf "${fzf_args[@]}"
}

# Resolve a pass entry path, falling back to fzf when not found directly.
#
# If the candidate is non-empty and names a valid .env entry on disk, prints
# it and returns immediately. Otherwise launches _fzf_select_entry, optionally
# pre-seeded with the candidate as a query string. Enforces the requirement
# that all entry names end in .env and rejects absolute paths and any path
# component containing '..' to prevent directory traversal outside the store.
#
# Arguments:
#   $1 - Candidate entry path (optional; triggers fzf if empty or not found)
# Environment:
#   PASSWORD_STORE_DIR - root of the password store (default: ~/.password-store)
# Outputs:
#   stdout: resolved entry path(s), one per line
#   stderr: error if the candidate does not end in .env or is not found
# Returns:
#   0 on success
#   exits 1 if the candidate is invalid or no entry can be resolved
_resolve_entry() {
  local candidate="$1"
  local password_store_dir="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
  if [[ -n "${candidate}" ]]; then
    [[ "${candidate}" == *.env ]] || die "entry name must end in .env: ${candidate}"
    # Reject absolute paths and any component containing '..' to prevent
    # directory traversal outside PASSWORD_STORE_DIR.
    [[ "${candidate}" == /* || "${candidate}" == *..* ]] && \
      die "invalid entry path (no traversal allowed): ${candidate}"
    local gpg_file="${password_store_dir}/${candidate}.gpg"
    if [[ -f "${gpg_file}" ]]; then
      if ! _is_entry_in_store "${gpg_file}" "${password_store_dir}"; then
        die "entry path escapes password store (symlink): ${candidate}"
      fi
      printf '%s\n' "${candidate}"
      return
    fi
    die "entry not found: ${candidate}"
  fi
  local selected
  selected="$(_fzf_select_entry "")"
  [[ -n "${selected}" ]] || die "No entry selected."
  printf '%s\n' "${selected}"
}

# Print usage information for the pass env extension to stdout.
#
# Outputs:
#   stdout: usage text covering all subcommands and their options
# Returns:
#   0 always
help() {
  cat <<'EOF'
Usage:
  pass env version
  pass env list
  pass env run   [ENTRY [ENTRY ...]] -- COMMAND [ARGS...]
  pass env set   [ENTRY [ENTRY ...]]
  pass env unset [ENTRY [ENTRY ...]]
  pass env help

Notes:
  - ENTRY must end in .env  (e.g. os/prod.env, api/openai.env).
  - ENTRY is optional for run/set/unset; omit it to pick interactively
    with fzf (TAB to multi-select).
  - Entries must contain KEY=VALUE lines (one per line).
    Blank lines and lines beginning with # are ignored.
  - `list` prints all .env entries available in the password store.
  - `run`   loads vars into the subprocess only; nothing leaks to the
    calling shell (safest option):
              pass env run os/prod.env -- printenv MY_VAR
              pass env run e1.env e2.env -- myapp
  - `set` / `unset` print shell statements; eval them to modify the current
    shell.  If you have sourced contrib/pass-env-init.sh, use `passenv set/unset`
    instead; it handles eval and tracking automatically:
              passenv set os/prod.env
              passenv set os/prod.env api/openai.env
              passenv unset os/prod.env
    Raw eval form (without pass-env-init.sh):
              eval "$(pass env set os/prod.env)"
              eval "$(pass env unset os/prod.env)"
EOF
}

# Print the version of pass-env.
#
# Outputs:
#   stdout: 'pass-env VERSION'
# Returns:
#   0 always
version() {
  printf 'pass-env %s\n' "${VERSION}"
}

# List all .env entries available in the password store.
#
# Walks PASSWORD_STORE_DIR, finds every *.env.gpg file, strips the store
# root prefix and the .gpg suffix, and prints one entry path per line.
# Output is sorted alphabetically.
#
# Environment:
#   PASSWORD_STORE_DIR - root of the password store (default: ~/.password-store)
# Outputs:
#   stdout: available entry path(s), one per line (no .gpg suffix)
# Returns:
#   0 always
list_entries() {
  local password_store_dir="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
  [[ -d "${password_store_dir}" ]] \
    || die "password store not found: ${password_store_dir} (has pass been initialised?)"

  find "${password_store_dir}" -name "*.env.gpg" \( -type f -o -type l \) \
    | while IFS= read -r f; do
      # Skip symlinks that resolve outside the password store.
      _is_entry_in_store "${f}" "${password_store_dir}" || continue
      printf '%s\n' "${f#"${password_store_dir}/"}"
    done \
    | sed 's/\.gpg$//' \
    | sort
}

# Iterate over each validated variable in a decrypted pass entry, calling a
# callback for every KEY=VALUE pair. All parsing, validation, and denylist
# checks happen here in one place, callers only provide the emit action.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
#   $2 - Callback function name; called as "$callback" "$key" "$val"
# Returns:
#   0 on success, exits 1 on decryption failure, invalid key name, dangerous
#   variable, or unsupported line format
_entry_for_each_var() {
  local entry="$1" callback="$2"
  local content key val line
  content="$(pass show -- "${entry}")" || die "unable to show entry: ${entry}"
  while IFS= read -r line; do
    line="${line%$'\r'}"   # Strip trailing CR (handles CRLF files transparently)
    [[ -z "${line}" ]] && continue
    case "${line}" in \#*) continue ;; esac
    if [[ "${line}" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in ${entry}: ${key}"
      _is_dangerous_var "${key}" && die "refusing to set sensitive variable from entry: ${key}"
      "${callback}" "${key}" "${val}"
    else
      die "unsupported line format in ${entry} (expected KEY=VALUE)"
    fi
  done <<< "${content}"
}

# Decrypt a pass entry and emit KEY=QUOTEDVAL lines.
#
# Each non-blank, non-comment line must be in KEY=VALUE format. Key names are
# validated against ^[A-Za-z_][A-Za-z0-9_]*$. Values are shell-quoted with
# printf %q so the output is safe to eval or source directly.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: KEY=QUOTEDVAL lines, one per variable
#   stderr: error message on invalid content or decryption failure
# Returns:
#   0 on success
#   exits 1 on decryption failure, invalid key name, or unsupported line format
_parse_entry() {
  _entry_for_each_var "$1" _parse_entry_emit
}

# Callback for _parse_entry: emit KEY=%q to stdout.
_parse_entry_emit() {
  printf '%s=%q\n' "$1" "$2"
}

# Export all variables from a pass entry directly into the current (sub)shell.
#
# Parses the entry and calls 'export KEY=VALUE' for each line using the raw
# value, without printf %q encoding or eval. The key is validated; the value
# is assigned as-is so special characters (!, $, #, etc.) are preserved.
# Used by _run_with_env; _set_env is used by the set subcommand for eval output.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Returns:
#   0 on success, exits 1 on decryption failure, invalid key name, or
#   unsupported line format
_export_entry() {
  _entry_for_each_var "$1" _export_entry_emit
}

# Callback for _export_entry: export KEY=VALUE directly.
_export_entry_emit() {
  export "$1=$2"
}

# Execute a command with environment variables from one or more pass entries.
#
# Entries are loaded and the command is executed entirely within a subshell;
# no variables are written to disk and nothing leaks into the calling shell.
#
# Arguments:
#   $@ - ENTRY [ENTRY ...] -- COMMAND [ARGS...]
#        Entry paths must precede '--'; everything after '--' is the command.
# Outputs:
#   stdout/stderr: forwarded from COMMAND
# Returns:
#   exit status of COMMAND
#   exits 1 if ENTRY or COMMAND arguments are missing
_run_with_env() {
  local entries=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    entries+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift
  [[ "${#entries[@]}" -ge 1 ]] || die "run: missing ENTRY"
  [[ "$#" -ge 1 ]] || die "run: missing COMMAND"
  (
    for e in "${entries[@]}"; do
      _export_entry "${e}"
    done
    exec "$@"
  )
}

# Emit 'export KEY=QUOTEDVAL' lines for all variables in a pass entry.
#
# Output is intended to be captured and eval'd by the caller to load variables
# into the current shell. When used via contrib/pass-env-init.sh, _passenv_load_one
# handles the eval automatically.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: 'export KEY=QUOTEDVAL' lines, one per variable
# Returns:
#   0 on success, exits 1 on any error (see _parse_entry)
_set_env() {
  _parse_entry "$1" | sed 's/^/export /'
}

# Emit an 'unset KEY KEY ...' line for all variables in a pass entry.
#
# Output is intended to be eval'd by the caller to remove variables from the
# current shell. The line is omitted when the entry defines no variables.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: 'unset KEY ...' line (omitted if the entry defines no variables)
# Returns:
#   0 on success, exits 1 on any error (see _parse_entry)
_unset_env() {
  local keys=() line
  while IFS= read -r line; do
    keys+=("${line%%=*}")
  done < <(_parse_entry "$1")
  if [[ "${#keys[@]}" -gt 0 ]]; then
    printf 'unset %s\n' "${keys[@]}"
  fi
}

cmd="${1:-help}"; shift || true
case "${cmd}" in
  help|-h|--help) help ;;
  version|-v|--version) version ;;
  list) list_entries ;;
  run)
    raw_entries=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
      raw_entries+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    if [[ "${#raw_entries[@]}" -eq 0 ]]; then
      entries=()
      resolved="$(_resolve_entry "")" || exit 1
      while IFS= read -r e; do entries+=("${e}"); done <<< "${resolved}"
    else
      entries=()
      for raw_e in "${raw_entries[@]}"; do
        resolved="$(_resolve_entry "${raw_e}")" || exit 1
        while IFS= read -r e; do entries+=("${e}"); done <<< "${resolved}"
      done
    fi
    _run_with_env "${entries[@]}" -- "$@"
    ;;
  set)
    raw_entries=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
      raw_entries+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    if [[ "${#raw_entries[@]}" -eq 0 ]]; then
      resolved="$(_resolve_entry "")" || exit 1
      while IFS= read -r e; do _set_env "${e}"; done <<< "${resolved}"
    else
      for raw_e in "${raw_entries[@]}"; do
        resolved="$(_resolve_entry "${raw_e}")" || exit 1
        while IFS= read -r e; do _set_env "${e}"; done <<< "${resolved}"
      done
    fi
    ;;
  unset)
    raw_entries=()
    while [[ $# -gt 0 && "${1}" != "--" ]]; do
      raw_entries+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    if [[ "${#raw_entries[@]}" -eq 0 ]]; then
      resolved="$(_resolve_entry "")" || exit 1
      while IFS= read -r e; do _unset_env "${e}"; done <<< "${resolved}"
    else
      for raw_e in "${raw_entries[@]}"; do
        resolved="$(_resolve_entry "${raw_e}")" || exit 1
        while IFS= read -r e; do _unset_env "${e}"; done <<< "${resolved}"
      done
    fi
    ;;
  *) die "unknown subcommand: ${cmd} (try 'pass env help')" ;;
esac
