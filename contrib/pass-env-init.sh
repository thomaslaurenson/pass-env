# pass env shell loader
#
# Source this in ~/.bashrc and/or ~/.zshrc:
# source /path/to/pass-env/contrib/pass-env-init.sh
#
# Requires: 
# pass with the env extension
# gpg (bunled with pass)
# fzf (optional, for interactive selection)

# Initialise the tracking associative array exactly once per session.
# The guard prevents re-initialisation if the file is sourced more than once.
if [[ -z "${_PASSENV_TRACKER+x}" ]]; then
  declare -gA _PASSENV_TRACKER
fi

# Print each key of _PASSENV_TRACKER, one per line.
#
# Abstracts the bash/zsh difference in associative-array key iteration:
# bash uses ${!arr[@]}; zsh uses ${(@k)arr}. Uses eval to parse the zsh
# syntax without the bash parser ever seeing it.
#
# Environment:
#   _PASSENV_TRACKER - associative array of loaded entries
#   ZSH_VERSION      - set by zsh; selects the correct iteration syntax
# Outputs:
#   stdout: entry key names, one per line
# Returns:
#   0 always
_passenv_keys() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval 'printf "%s\n" "${(@k)_PASSENV_TRACKER}"'
  else
    printf '%s\n' "${!_PASSENV_TRACKER[@]}"
  fi
}

# Print each whitespace-separated word of STRING, one per line.
#
# Avoids the read -a (bash) vs read -A (zsh) incompatibility by relying on
# unquoted word-splitting, which is consistent across both shells.
#
# Arguments:
#   $1 - Space-separated string of words
# Outputs:
#   stdout: one word per line
# Returns:
#   0 always
_passenv_split_words() {
  # shellcheck disable=SC2086  # intentional: unquoted split on whitespace
  printf '%s\n' $1
}

# Main entry point for the passenv shell function.
#
# Dispatches to the appropriate subcommand handler. Defaults to 'help' when
# called with no arguments.
#
# Arguments:
#   $1 - Subcommand: set | unset | run | list | loaded | help (default: help)
#   $@ - Additional arguments forwarded to the subcommand handler
# Outputs:
#   stdout: subcommand output
#   stderr: error message for unknown subcommands
# Returns:
#   0 on success
#   1 for unknown subcommands
passenv() {
  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    set)     _passenv_set   "$@" ;;
    unset)   _passenv_unset "$@" ;;
    run)     _passenv_run   "$@" ;;
    list)    _passenv_list        ;;
    loaded)  _passenv_loaded      ;;
    version|-v|--version) _passenv_version ;;
    help|-h|--help) _passenv_help ;;
    *) printf 'passenv: unknown subcommand: %s\n' "$subcmd" >&2
       _passenv_help >&2
       return 1 ;;
  esac
}

# Print the version of pass-env.
#
# Outputs:
#   stdout: 'pass-env VERSION' forwarded from pass env version
# Returns:
#   exit status of pass env version
_passenv_version() {
  pass env version
}

# Execute a command with environment variables from one or more pass entries.
#
# Thin wrapper around 'pass env run'. Entries are decrypted and the command
# is executed in a subshell — nothing leaks into the calling shell. Supports
# the same argument syntax as the pass extension: ENTRY [ENTRY ...] -- CMD.
# If no ENTRY is given before --, an interactive fzf picker is launched.
#
# Arguments:
#   $@ - [ENTRY ...] -- COMMAND [ARGS...]
# Outputs:
#   stdout/stderr: forwarded from COMMAND
# Returns:
#   exit status of COMMAND
#   1 if arguments are missing or pass env run fails
_passenv_run() {
  pass env run "$@"
}

# Load one or more pass entries into the current shell.
#
# Iterates over the provided entry arguments, calling _passenv_load_one for
# each. With no arguments, launches an interactive fzf picker via the pass
# env extension (fzf --multi is enabled inside the extension).
#
# Arguments:
#   $@ - Pass entry paths to load (optional; launches fzf picker if omitted)
# Returns:
#   0 if all entries loaded successfully
#   1 if any entry fails to load
_passenv_set() {
  if [[ $# -eq 0 ]]; then
    _passenv_load_one ""
    return
  fi
  local e
  for e in "$@"; do
    _passenv_load_one "$e" || return 1
  done
}

# Load a single pass entry into the current shell.
#
# Calls 'pass env set ENTRY' in a command substitution to obtain export
# statements, filters them through a strict identifier guard as a
# defense-in-depth measure, then evals the result into the current shell.
# Records the entry name and its variable names in _PASSENV_TRACKER.
#
# Arguments:
#   $1 - Pass entry path (optional; fzf picker is launched inside the
#        extension when omitted)
# Environment:
#   _PASSENV_TRACKER - associative array updated with the loaded var names
# Outputs:
#   stdout: 'passenv: loaded ENTRY → VAR1 VAR2 ...' confirmation line
#   stderr: error messages on failure
# Returns:
#   0 on success
#   1 if the pass command fails, returns no output, or emits no valid exports
_passenv_load_one() {
  local entry="${1:-}"

  # Capture stdout; keep stderr visible so fzf UI is not swallowed.
  local output
  if ! output="$(pass env set ${entry:+"$entry"})"; then
    printf 'passenv: pass env set failed for: %s\n' "${entry:-<interactive>}" >&2
    return 1
  fi

  if [[ -z "$output" ]]; then
    printf 'passenv: pass env set returned no output\n' >&2
    return 1
  fi

  # Extract var names using awk — avoids BASH_REMATCH which is not portable
  # to zsh's =~ operator.
  local varlist
  varlist="$(printf '%s\n' "$output" \
    | awk '/^export [A-Za-z_][A-Za-z0-9_]*=/ { split($2, a, "="); printf "%s ", a[1] }' \
    | sed 's/[[:space:]]*$//')"

  if [[ -z "$varlist" ]]; then
    printf 'passenv: no valid export lines found in output\n' >&2
    return 1
  fi

  # When no entry was given, fzf resolved it inside the extension but never
  # surfaces the chosen name. Derive a stable tracker key from the var names.
  if [[ -z "$entry" ]]; then
    entry="__passenv_$(printf '%s' "$varlist" | cksum | awk '{print $1}')"
  fi

  # Load only validated export lines (defense-in-depth: env.bash validates key
  # names before emitting, but we filter here as a secondary guard).
  local safe_output
  safe_output="$(printf '%s\n' "$output" | grep -E '^export [A-Za-z_][A-Za-z0-9_]*=')"
  eval "$safe_output"

  # Merge with any previously tracked vars for this entry (deduplicated).
  local existing="${_PASSENV_TRACKER[$entry]:-}"
  local merged
  if [[ -n "$existing" ]]; then
    merged="$(printf '%s %s' "$existing" "$varlist" \
      | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  else
    merged="$varlist"
  fi
  _PASSENV_TRACKER["$entry"]="$merged"

  printf 'passenv: loaded %s → %s\n' "$entry" "$merged"
}

# Unset variables for one or more loaded entries and remove them from the tracker.
#
# With arguments, unsets each named entry in turn. With no arguments, presents
# a multi-select fzf picker over currently loaded entries. Errors for individual
# unknown entries are printed to stderr but do not abort the loop.
#
# Arguments:
#   $@ - Entry keys to unset (optional; launches fzf picker if omitted)
# Environment:
#   _PASSENV_TRACKER - associative array; matched entries are removed
# Outputs:
#   stdout: 'passenv: unset ENTRY → VAR1 VAR2 ...' for each unset entry
#   stderr: warning if a named entry is not currently loaded
# Returns:
#   0 always (errors for individual entries are non-fatal)
_passenv_unset() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n'
    return 0
  fi

  local entries_to_unset=()
  if [[ $# -eq 0 ]]; then
    # Interactive multi-select picker when no entry is given.
    if ! command -v fzf &>/dev/null; then
      printf 'passenv: an ENTRY argument is required (fzf is not installed)\n' >&2
      return 1
    fi

    # Write a tab-separated preview file so fzf can show var names without
    # needing access to the associative array (not inherited by subprocesses).
    local tmp_preview
    tmp_preview="$(mktemp)"
    trap 'rm -f "$tmp_preview"' INT TERM EXIT
    _passenv_keys | while IFS= read -r k; do
      printf '%s\t%s\n' "$k" "${_PASSENV_TRACKER[$k]}"
    done > "$tmp_preview"

    local selected
    selected="$(awk -F'\t' '{print $1}' "$tmp_preview" \
      | fzf --multi \
            --height=40% \
            --layout=reverse \
            --border \
            --prompt="Unset entry: " \
            --header="ENTER: select  |  TAB+ENTER: select multiple  |  ESC: cancel" \
            --preview="awk -F'\t' -v k={} '\$1==k {print \"Vars: \" \$2}' $(printf '%q' "$tmp_preview")")"
    rm -f "$tmp_preview"
    trap - INT TERM EXIT

    [[ -z "$selected" ]] && { printf 'passenv: no entry selected\n'; return 0; }
    while IFS= read -r e; do
      entries_to_unset+=("$e")
    done <<< "$selected"
  else
    entries_to_unset=("$@")
  fi

  local entry varlist v
  for entry in "${entries_to_unset[@]}"; do
    if [[ -z "${_PASSENV_TRACKER[$entry]+x}" ]]; then
      printf 'passenv: %s is not currently loaded\n' "$entry" >&2
      continue
    fi

    varlist="${_PASSENV_TRACKER[$entry]}"

    # Unset each tracked variable.
    while IFS= read -r v; do
      [[ -n "$v" ]] && unset "$v"
    done < <(_passenv_split_words "$varlist")

    # Remove the entry from the tracker.
    unset "_PASSENV_TRACKER[$entry]"

    printf 'passenv: unset %s → %s\n' "$entry" "$varlist"
  done
}

# List all .env entries available in the password store.
#
# Delegates to 'pass env list', which walks PASSWORD_STORE_DIR and prints
# every *.env.gpg entry path (one per line, no .gpg suffix, sorted).
#
# Outputs:
#   stdout: available entry path(s), one per line
# Returns:
#   0 on success, non-zero if pass env list fails
_passenv_list() {
  pass env list
}

# Print a formatted table of all currently loaded entries and their variables.
#
# Outputs a two-column header table (ENTRY / VARIABLES). Uses _passenv_keys
# to iterate in a shell-agnostic way across both bash and zsh.
#
# Environment:
#   _PASSENV_TRACKER - associative array of loaded entries
# Outputs:
#   stdout: one 'passenv: ENTRY → VARS' line per loaded entry, or a
#           'no entries' message if the tracker is empty
# Returns:
#   0 always
_passenv_loaded() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n'
    return 0
  fi

  _passenv_keys | while IFS= read -r k; do
    printf 'passenv: %s → %s\n' "$k" "${_PASSENV_TRACKER[$k]}"
  done
}

# Print usage information for the passenv shell function.
#
# Outputs:
#   stdout: usage text covering all subcommands, examples, and notes
# Returns:
#   0 always
_passenv_help() {
  cat <<'EOF'
Usage: passenv <subcommand> [ENTRY]

Subcommands:
  set    [ENTRY ...]            Decrypt a pass entry and load its vars into the
                                current shell. If ENTRY is omitted, an fzf picker
                                is launched.
                                Example:  passenv set os/prod.env
                                          passenv set os/prod.env api/openai.env

  unset  [ENTRY ...]            Unset the vars loaded from ENTRY in the current
                                shell. If ENTRY is omitted, an fzf picker is shown
                                over currently loaded entries.
                                Example:  passenv unset os/prod.env

  run    [ENTRY ...] -- CMD     Decrypt one or more entries and run CMD with those
                                vars in its environment only — nothing leaks into
                                the current shell. If ENTRY is omitted, an fzf
                                picker is launched.
                                Example:  passenv run os/prod.env -- printenv MY_VAR
                                          passenv run e1.env e2.env -- myapp

  list                          List all .env entries available in the password
                                store.

  loaded                        Print all entries currently loaded in this shell
                                session and their associated variable names.

  version                       Print the installed pass-env version.

  help                          Show this message.

Notes:
  - Pass entries must contain KEY=VALUE lines (one per line).
  - Blank lines and # comment lines are ignored.
  - _PASSENV_TRACKER is session-local and reset on shell exit.
  - Requires: pass with the env extension, gpg, fzf.
EOF
}
