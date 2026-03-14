#!/usr/bin/env bash

# pass extension: env
#
# Requires: 
# pass with the env extension
# gpg (bunled with pass)
# fzf (optional, for interactive selection)

set -euo pipefail

PASS_CMD="${PASS_CMD:-pass}"  # in case we need to call back into pass

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $@ - Error message text
# Outputs:
#   stderr: formatted error message prefixed with 'pass env:'
# Returns:
#   exits 1 (does not return to the caller)
die() { printf 'pass env: %s\n' "$*" >&2; exit 1; }

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
        die "--entry PATH is required (fzf not installed for interactive selection)"
    fi
    local password_store_dir="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
    find "$password_store_dir" -name "*.env.gpg" -type f \
        | while IFS= read -r f; do printf '%s\n' "${f#"$password_store_dir/"}"; done \
        | sed 's/\.gpg$//' \
        | sort \
        | fzf --multi \
              --height=40% \
              --layout=reverse \
              --border \
              --prompt="Pass entry: " \
              --header="ENTER: select one  |  TAB+ENTER: select multiple  |  ESC: cancel" \
              ${query:+--query="$query"}
}

# Resolve a pass entry path, falling back to fzf when not found directly.
#
# If the candidate is non-empty and names a valid .env entry on disk, prints
# it and returns immediately. Otherwise launches _fzf_select_entry, optionally
# pre-seeded with the candidate as a query string. Enforces the requirement
# that all entry names end in .env.
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
    local password_store_dir="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
    if [ -n "$candidate" ]; then
        [[ "$candidate" == *.env ]] || die "entry name must end in .env: $candidate"
        if [ -f "$password_store_dir/$candidate.gpg" ]; then
            printf '%s\n' "$candidate"
            return
        fi
        printf 'pass env: entry not found: %s\n' "$candidate" >&2
    fi
    local selected
    selected="$(_fzf_select_entry "$candidate")"
    [ -n "$selected" ] || die "No entry selected."
    printf '%s\n' "$selected"
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
    instead — it handles eval and tracking automatically:
              passenv set os/prod.env
              passenv set os/prod.env api/openai.env
              passenv unset os/prod.env
    Raw eval form (without pass-env-init.sh):
              eval "$(pass env set os/prod.env)"
              eval "$(pass env unset os/prod.env)"
EOF
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
  local password_store_dir="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
  find "$password_store_dir" -name "*.env.gpg" -type f \
    | while IFS= read -r f; do printf '%s\n' "${f#"$password_store_dir/"}"; done \
    | sed 's/\.gpg$//' \
    | sort
}

# Decrypt a pass entry and emit KEY=QUOTEDVAL lines.
#
# Each non-blank, non-comment line must be in KEY=VALUE format. Key names are
# validated against ^[A-Za-z_][A-Za-z0-9_]*$. Values are shell-quoted with
# printf %q so the output is safe to eval or source directly.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Environment:
#   PASS_CMD - pass executable to invoke (default: "pass")
# Outputs:
#   stdout: KEY=QUOTEDVAL lines, one per variable
#   stderr: error message on invalid content or decryption failure
# Returns:
#   0 on success
#   exits 1 on decryption failure, invalid key name, or unsupported line format
_parse_entry() {
  local entry="$1" content key val
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in $entry: $key"
      printf '%s=%q\n' "$key" "$val"
    else
      die "unsupported line format in $entry: $line"
    fi
  done <<< "$content"
}

# Emit KEY=QUOTEDVAL lines from a pass entry.
#
# Thin wrapper around _parse_entry; used internally by run_with_env.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: KEY=QUOTEDVAL lines, one per variable
# Returns:
#   0 on success, exits 1 on any error (see _parse_entry)
print_entry() {
  _parse_entry "$1"
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
run_with_env() {
  local entries=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    entries+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift
  [ "${#entries[@]}" -ge 1 ] || die "run: missing ENTRY"
  [ "$#" -ge 1 ] || die "run: missing COMMAND"
  (
    for e in "${entries[@]}"; do
      eval "$(set_env "$e")"
    done
    exec "$@"
  )
}

# Emit 'export KEY=QUOTEDVAL' lines for all variables in a pass entry.
#
# Output is intended to be captured and eval'd by the caller to load variables
# into the current shell. When used via contrib/shell-init.sh, _passenv_load_one
# handles the eval automatically.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: 'export KEY=QUOTEDVAL' lines, one per variable
# Returns:
#   0 on success, exits 1 on any error (see _parse_entry)
set_env() {
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
unset_env() {
  local keys=() line
  while IFS= read -r line; do
    keys+=("${line%%=*}")
  done < <(_parse_entry "$1")
  [ ${#keys[@]} -gt 0 ] && printf 'unset %s\n' "${keys[*]}"
}

# ---- dispatcher ----
cmd="${1:-help}"; shift || true
case "$cmd" in
  help|-h|--help) help ;;
  list) list_entries ;;
  run)
    raw_entries=()
    saw_dashdash=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) raw_entries+=("${2:-}"); shift 2 ;;
        --) shift; saw_dashdash=1; break ;;
        *) break ;;
      esac
    done
    # Collect all positional entries (everything up to --) when the explicit
    # -- separator was not the first token consumed.
    if [ "$saw_dashdash" -eq 0 ]; then
      while [ $# -gt 0 ] && [ "${1}" != "--" ]; do
        raw_entries+=("$1"); shift
      done
      [ "${1:-}" = "--" ] && shift
    fi
    if [ "${#raw_entries[@]}" -eq 0 ]; then
      entries=()
      while IFS= read -r e; do entries+=("$e"); done < <(_resolve_entry "")
    else
      entries=()
      for raw_e in "${raw_entries[@]}"; do
        while IFS= read -r e; do entries+=("$e"); done < <(_resolve_entry "$raw_e")
      done
    fi
    run_with_env "${entries[@]}" -- "$@"
    ;;
  set)
    raw_entries=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) raw_entries+=("${2:-}"); shift 2 ;;
        --) shift; break ;;
        *)  raw_entries+=("$1"); shift ;;
      esac
    done
    if [ "${#raw_entries[@]}" -eq 0 ]; then
      resolved="$(_resolve_entry "")" || exit 1
      while IFS= read -r e; do set_env "$e"; done <<< "$resolved"
    else
      for raw_e in "${raw_entries[@]}"; do
        resolved="$(_resolve_entry "$raw_e")" || exit 1
        while IFS= read -r e; do set_env "$e"; done <<< "$resolved"
      done
    fi
    ;;
  unset)
    raw_entries=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) raw_entries+=("${2:-}"); shift 2 ;;
        --) shift; break ;;
        *)  raw_entries+=("$1"); shift ;;
      esac
    done
    if [ "${#raw_entries[@]}" -eq 0 ]; then
      resolved="$(_resolve_entry "")" || exit 1
      while IFS= read -r e; do unset_env "$e"; done <<< "$resolved"
    else
      for raw_e in "${raw_entries[@]}"; do
        resolved="$(_resolve_entry "$raw_e")" || exit 1
        while IFS= read -r e; do unset_env "$e"; done <<< "$resolved"
      done
    fi
    ;;
  *) die "unknown subcommand: $cmd (try 'pass env help')" ;;
esac
