# pass env shell loader
#
# Source this in ~/.bashrc and/or ~/.zshrc:
# source /path/to/pass-env/contrib/pass-env-init.sh
#
# Requires:
# pass with the env extension
# gpg (bundled with pass)
# fzf (optional, for interactive selection)

# Note: set -euo pipefail is intentionally absent. This file is sourced into
# the user's interactive shell; enabling errexit here would cause the shell
# to exit on any error inside passenv functions, which would be catastrophic
# for an interactive session.

# Require bash 4.0+ or zsh. Both support declare -gA / associative arrays.
# On macOS, /bin/bash is 3.2 (GPLv2 restriction). Users must install bash via
# Homebrew: brew install bash
if [[ -z "${ZSH_VERSION:-}" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  printf 'pass-env-init.sh: bash 4.0+ or zsh required (found bash %s)\n' \
    "${BASH_VERSION:-unknown}" >&2
  return 1
fi

# Initialise the tracking associative arrays exactly once per session.
# The guard prevents re-initialisation if the file is sourced more than once.
#   _PASSENV_TRACKER  entry -> space-separated variable names loaded from it
#   _PASSENV_RESTORE  entry -> newline-separated shell statements that restore
#                     each variable to its pre-load state (export of the old
#                     value, or unset when it did not previously exist)
if [[ -z "${_PASSENV_TRACKER+x}" ]]; then
  declare -gA _PASSENV_TRACKER
fi
if [[ -z "${_PASSENV_RESTORE+x}" ]]; then
  declare -gA _PASSENV_RESTORE
fi

# Print each key of _PASSENV_TRACKER, one per line.
#
# Abstracts the bash/zsh difference in associative-array key iteration:
# bash uses ${!arr[@]}; zsh uses ${(@k)arr}. Uses eval to parse the zsh
# syntax without the bash parser ever seeing it.
# Branches on BASH_VERSION (set by bash itself, not spoofable by end users)
# rather than ZSH_VERSION (a plain env var that could be set in bash).
#
# Environment:
#   _PASSENV_TRACKER - associative array of loaded entries
#   BASH_VERSION     - set by bash; selects the bash iteration syntax
# Outputs:
#   stdout: entry key names, one per line
# Returns:
#   0 always
_passenv_keys() {
  if [[ -n "${BASH_VERSION:-}" ]]; then
    printf '%s\n' "${!_PASSENV_TRACKER[@]}"
  else
    # zsh: use parameter expansion flag (@k) for associative array keys
    eval 'printf "%s\n" "${(@k)_PASSENV_TRACKER}"'
  fi
}

# Print each whitespace-separated word of STRING, one per line.
#
# Avoids the read -a (bash) vs read -A (zsh) incompatibility by relying on
# unquoted word-splitting, which is consistent across both shells.
# Safety: this function is only called with $varlist, whose words are variable
# names validated against ^[A-Za-z_][A-Za-z0-9_]*$; that character class
# excludes all IFS characters (space, tab, newline), so word-splitting on $1
# is safe and produces exactly one name per line.
#
# Arguments:
#   $1 - Space-separated string of words
# Outputs:
#   stdout: one word per line
# Returns:
#   0 always
_passenv_split_words() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    # In zsh, unquoted $1 does not word-split by default; ${=1} enables it.
    # Safety contract: callers must only pass variable names validated against
    # ^[A-Za-z_][A-Za-z0-9_]*$; that character class excludes all IFS chars,
    # making word-splitting safe and deterministic. Never call with arbitrary input.
    # shellcheck disable=SC2086,SC2296
    printf '%s\n' ${=1}
  else
    # shellcheck disable=SC2086  # Unquoted word-splitting is intentional here.
    # Safety contract: as above. This disable is load-bearing; do not remove
    # without understanding this contract.
    printf '%s\n' $1
  fi
}

# Report whether a variable name is currently set in this shell.
#
# Cross-shell indirection: bash uses ${!name+x}; zsh uses ${(P)name+x}
# (parsed via eval so the bash parser never sees the zsh syntax).
#
# Arguments:
#   $1 - Variable name (must already be validated as a shell identifier)
# Returns:
#   0 if the variable is set (possibly empty), 1 otherwise
_passenv_var_is_set() {
  if [[ -n "${BASH_VERSION:-}" ]]; then
    [[ -n "${!1+x}" ]]
  else
    # shellcheck disable=SC2296
    eval '[[ -n "${(P)1+x}" ]]'
  fi
}

# Print a single shell statement that restores a variable to its current state.
#
# If the variable is currently set, prints 'export NAME=<quoted current value>'
# (note: a previously non-exported shell variable is restored as exported; a
# known, documented limitation). If unset, prints 'unset NAME'. The value is
# quoted with printf %q so the statement is safe to eval later.
#
# Arguments:
#   $1 - Variable name (must already be validated as a shell identifier)
# Outputs:
#   stdout: one restore statement
# Returns:
#   0 always
_passenv_snapshot_stmt() {
  local name="$1" val
  if _passenv_var_is_set "${name}"; then
    if [[ -n "${BASH_VERSION:-}" ]]; then
      val="${!name}"
    else
      # shellcheck disable=SC2296
      eval 'val="${(P)name}"'
    fi
    printf 'export %s=%q\n' "${name}" "${val}"
  else
    printf 'unset %s\n' "${name}"
  fi
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

  case "${subcmd}" in
    set)     _passenv_set   "$@" ;;
    unset)   _passenv_unset "$@" ;;
    run)     _passenv_run   "$@" ;;
    list)    _passenv_list        ;;
    loaded)  _passenv_loaded      ;;
    version|-v|--version) _passenv_version ;;
    help|-h|--help) _passenv_help ;;
    *) printf 'passenv: unknown subcommand: %s\n' "${subcmd}" >&2
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
# is executed in a subshell; nothing leaks into the calling shell. Supports
# the same argument syntax as the pass extension, including {{VAR}} argument
# placeholders and leading VAR=VALUE assignments before COMMAND (see
# _pass_env_run_with_env in src/env.bash). If no ENTRY is given before --, an
# interactive fzf picker is launched.
#
# Arguments:
#   $@ - [--no-expand] [ENTRY ...] -- [VAR=VALUE ...] COMMAND [ARGS...]
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
# If loading multiple entries and one fails, all entries successfully loaded
# earlier in this call are rolled back (their variables are restored to their
# pre-load values and the entries are removed from the tracker).
#
# Arguments:
#   $@ - Pass entry paths to load (optional; launches fzf picker if omitted)
# Returns:
#   0 if all entries loaded successfully
#   1 if any entry fails to load (previously loaded entries in this call are rolled back)
_passenv_set() {
  local force=false
  if [[ "${1:-}" == "--force" ]]; then
    force=true
    shift
  fi

  if [[ $# -eq 0 ]]; then
    _passenv_load_one "" "${force}"
    return
  fi
  local e
  local loaded=()
  for e in "$@"; do
    if _passenv_load_one "${e}" "${force}"; then
      loaded+=("${e}")
    else
      if [[ ${#loaded[@]} -gt 0 ]]; then
        printf 'passenv: rolling back previously loaded entries due to failure\n' >&2
        _passenv_unset "${loaded[@]}"
      fi
      return 1
    fi
  done
}

# Load the output of one 'pass env set' invocation into the current shell.
#
# Calls 'pass env set [ENTRY]' in a command substitution, then processes the
# output line by line:
#   - '# pass-env entry: NAME' marker lines attribute the export lines that
#     follow to NAME. This is how interactively (fzf) selected entries are
#     tracked under their real names, including multi-select.
#   - 'export KEY=...' lines are validated against a strict identifier guard
#     (defense-in-depth; value-level injection protection comes from printf %q
#     in the extension - both layers are required) and eval'd individually.
# Before a variable is first assigned for an entry, its pre-load state is
# snapshotted into _PASSENV_RESTORE so 'passenv unset' can restore it.
# All other lines are ignored.
#
# Arguments:
#   $1 - Pass entry path (optional; fzf picker is launched inside the
#        extension when omitted)
#   $2 - Force flag ("true" to reload an already-loaded entry)
# Environment:
#   _PASSENV_TRACKER, _PASSENV_RESTORE - updated
# Outputs:
#   stdout: 'passenv: loaded ENTRY -> VAR1 VAR2 ...' per loaded entry
#   stderr: error messages on failure
# Returns:
#   0 on success
#   1 if the pass command fails, returns no output, or emits no valid exports
_passenv_load_one() {
  local entry="${1:-}"
  local force="${2:-false}"

  if [[ -n "${entry}" && "${force}" != true && -n "${_PASSENV_TRACKER[$entry]+x}" ]]; then
    printf 'passenv: %s is already loaded (use --force to reload)\n' "${entry}"
    return 0
  fi

  # Capture stdout; keep stderr visible so fzf UI is not swallowed.
  # Build args explicitly to avoid word-splitting on unquoted conditional expansion.
  local pass_args=()
  [[ -n "${entry}" ]] && pass_args=("${entry}")
  local output
  if ! output="$(pass env set "${pass_args[@]}")" ; then
    printf 'passenv: pass env set failed for: %s\n' "${entry:-<interactive>}" >&2
    return 1
  fi

  if [[ -z "${output}" ]]; then
    printf 'passenv: pass env set returned no output\n' >&2
    return 1
  fi

  # Process the output section by section. 'current' is the entry the
  # following export lines belong to; it defaults to the requested entry so
  # marker-less output (e.g. an older extension version) still tracks
  # correctly for explicit loads.
  local current="${entry}"
  local skip_section=false
  local line rest key val
  local any_loaded=false
  local section_entries=""   # newline-separated, in load order
  while IFS= read -r line; do
    case "${line}" in
      "# pass-env entry: "*)
        current="${line#\# pass-env entry: }"
        skip_section=false
        if [[ "${force}" != true && -n "${_PASSENV_TRACKER[$current]+x}" ]]; then
          # Interactive multi-select can include an already-loaded entry.
          printf 'passenv: %s is already loaded (use --force to reload)\n' "${current}"
          skip_section=true
        fi
        continue
        ;;
      "export "*)
        [[ "${skip_section}" == true ]] && continue
        rest="${line#export }"
        key="${rest%%=*}"
        # Strict identifier guard: drop anything that is not export KEY=...
        # NOTE: this validates the key name only; it does NOT constrain values.
        # Protection against value-level injection comes entirely from
        # printf %q in the extension. Both layers are required.
        [[ "${rest}" == *=* ]] || continue
        [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        if [[ -z "${current}" ]]; then
          # No entry name and no marker (should not happen with a current
          # extension); fall back to a stable synthetic key.
          current="__passenv_interactive"
        fi

        # Snapshot the pre-load state the first time this var is recorded
        # for this entry, so unset can restore it. Re-loads with --force keep
        # the original (true pre-load) snapshot.
        case " ${_PASSENV_TRACKER[$current]:-} " in
          *" ${key} "*) : ;;  # already tracked; keep existing snapshot
          *)
            _PASSENV_RESTORE[$current]="${_PASSENV_RESTORE[$current]:-}${_PASSENV_RESTORE[$current]:+
}$(_passenv_snapshot_stmt "${key}")"
            _PASSENV_TRACKER[$current]="${_PASSENV_TRACKER[$current]:-}${_PASSENV_TRACKER[$current]:+ }${key}"
            ;;
        esac

        eval "${line}"
        any_loaded=true
        case "
${section_entries}
" in
          *"
${current}
"*) : ;;
          *) section_entries="${section_entries}${section_entries:+
}${current}" ;;
        esac
        ;;
      *) : ;;  # ignore stray lines (blank lines, debug output, etc.)
    esac
  done <<< "${output}"

  if [[ "${any_loaded}" != true ]]; then
    # Nothing was eval'd. If sections were skipped as already loaded that is
    # a success; otherwise the output contained no valid export lines.
    if [[ "${skip_section}" == true ]]; then
      return 0
    fi
    printf 'passenv: no valid export lines found in output\n' >&2
    return 1
  fi

  while IFS= read -r current; do
    [[ -n "${current}" ]] || continue
    printf 'passenv: loaded %s -> %s\n' "${current}" "${_PASSENV_TRACKER[$current]}"
  done <<< "${section_entries}"
}

# Restore variables for one or more loaded entries and remove them from the
# tracker.
#
# Each variable loaded from the entry is restored to its pre-load state: the
# previous value is re-exported, or the variable is unset if it did not exist
# before loading. With arguments, processes each named entry in turn. With no
# arguments, presents a multi-select fzf picker over currently loaded entries.
# Errors for individual unknown entries are printed to stderr but do not abort
# the loop.
#
# Known limitation: if two loaded entries define the same variable, unsetting
# one restores that variable to its state before *that entry* was loaded,
# which may differ from what the other entry expects.
#
# Arguments:
#   $@ - Entry keys to unset (optional; launches fzf picker if omitted)
# Environment:
#   _PASSENV_TRACKER, _PASSENV_RESTORE - matched entries are removed
# Outputs:
#   stdout: 'passenv: unset ENTRY -> VAR1 VAR2 ...' for each unset entry
#   stderr: warning if a named entry is not currently loaded
# Returns:
#   0 always (errors for individual entries are non-fatal)
_passenv_unset() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n' >&2
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
    tmp_preview="$(mktemp)" || { printf 'passenv: failed to create temp file\n' >&2; return 1; }

    # Save existing trap state before overwriting. passenv is a shell function,
    # so trap modifies the interactive shell's global trap table directly. Without
    # saving/restoring, any EXIT/INT/TERM traps the user set would be destroyed.
    local prev_int prev_term prev_exit
    prev_int="$(trap -p INT)"
    prev_term="$(trap -p TERM)"
    prev_exit="$(trap -p EXIT)"

    trap 'rm -f "${tmp_preview}"' INT TERM EXIT
    _passenv_keys | while IFS= read -r k; do
      printf '%s\t%s\n' "$k" "${_PASSENV_TRACKER[$k]}"
    done > "${tmp_preview}"

    local selected
    selected="$(awk -F'\t' '{print $1}' "${tmp_preview}" \
      | fzf --multi \
            --height=40% \
            --layout=reverse \
            --border \
            --prompt="Unset entry: " \
            --header="ENTER: select  |  TAB+ENTER: select multiple  |  ESC: cancel" \
            --preview="awk -F'\t' -v k={} '\$1==k {print \"Vars: \" \$2}' $(printf '%q' "${tmp_preview}")")"
    rm -f "${tmp_preview}"

    # Restore previous traps. trap -p output is eval-safe: the shell itself
    # generates it with proper quoting. The :-: default is a no-op command,
    # used when no trap was previously set (trap -p returns empty string).
    trap - INT TERM EXIT
    eval "${prev_int:-:}"
    eval "${prev_term:-:}"
    eval "${prev_exit:-:}"

    [[ -z "${selected}" ]] && { printf 'passenv: no entry selected\n'; return 0; }
    while IFS= read -r e; do
      entries_to_unset+=("${e}")
    done <<< "${selected}"
  else
    entries_to_unset=("$@")
  fi

  local entry varlist v any_unset=false
  for entry in "${entries_to_unset[@]}"; do
    if [[ -z "${_PASSENV_TRACKER[$entry]+x}" ]]; then
      printf 'passenv: %s is not currently loaded\n' "${entry}" >&2
      continue
    fi

    varlist="${_PASSENV_TRACKER[$entry]}"

    if [[ -n "${_PASSENV_RESTORE[$entry]:-}" ]]; then
      # Restore each variable to its pre-load state. Statements were built
      # by _passenv_snapshot_stmt at load time (export NAME=%q / unset NAME)
      # and are eval-safe.
      eval "${_PASSENV_RESTORE[$entry]}"
    else
      # Fallback for tracker data without restore info: plain unset.
      while IFS= read -r v; do
        [[ -n "${v}" ]] && unset "${v}"
      done < <(_passenv_split_words "${varlist}")
    fi

    # Safe: `unset "arr[$key]"` evaluates its subscript, but entry names are
    # validated against a restricted character set in the extension before they
    # can enter the tracker, so this subscript holds no shell metacharacters.
    unset "_PASSENV_TRACKER[${entry}]"
    unset "_PASSENV_RESTORE[${entry}]"

    printf 'passenv: unset %s -> %s\n' "${entry}" "${varlist}"
    any_unset=true
  done

  [[ "${any_unset}" == true ]] || return 1
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
#   stdout: one 'passenv: ENTRY -> VARS' line per loaded entry, or a
#           'no entries' message if the tracker is empty
# Returns:
#   0 always
_passenv_loaded() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n' >&2
    return 0
  fi

  _passenv_keys | while IFS= read -r k; do
    printf 'passenv: %s -> %s\n' "$k" "${_PASSENV_TRACKER[$k]}"
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
  set    [--force] [ENTRY ...]  Decrypt a pass entry and load its vars into the
                                current shell. If ENTRY is omitted, an fzf picker
                                is launched. Use --force to reload an already-loaded
                                entry without being skipped.
                                Example:  passenv set os/prod.env
                                          passenv set os/prod.env api/openai.env
                                          passenv set --force os/prod.env
  unset  [ENTRY ...]            Restore the vars loaded from ENTRY to their
                                pre-load values (previous value re-exported, or
                                unset if the var did not exist before). If ENTRY
                                is omitted, an fzf picker is shown over currently
                                loaded entries.
                                Example:  passenv unset os/prod.env

  run    [ENTRY ...] -- CMD     Decrypt one or more entries and run CMD with those
                                vars in its environment only; nothing leaks into
                                the current shell. If ENTRY is omitted, an fzf
                                picker is launched.
                                Example:  passenv run os/prod.env -- printenv MY_VAR
                                          passenv run e1.env e2.env -- myapp

                                To use an entry's variables as command ARGUMENTS,
                                write {{VAR}}. A bare $VAR cannot work: your shell
                                expands it before pass runs, when the entry is not
                                yet loaded. {{VAR}} needs no quoting.
                                Example:  passenv run api.env -- \
                                            myapp --model {{MODEL}} --input "hi"

                                A leading VAR=VALUE before CMD sets that variable
                                for the command, overriding the entry:
                                Example:  passenv run api.env -- LOG_LEVEL=debug myapp

                                Pass --no-expand to leave {{...}} literal.

  list                          List all .env entries available in the password
                                store.

  loaded                        Print all entries currently loaded in this shell
                                session and their associated variable names.

  version                       Print the installed pass-env version.

  help                          Show this message.

Notes:
  - Pass entries must contain KEY=VALUE lines (one per line).
  - Blank lines and # comment lines are ignored.
  - When multiple entries define the same variable, later entries override
    earlier ones; unsetting one of them restores that variable to its state
    before that entry was loaded.
  - _PASSENV_TRACKER is session-local and reset on shell exit.
  - Requires: pass with the env extension, gpg, fzf.
EOF
}
