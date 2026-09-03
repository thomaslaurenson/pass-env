#!/usr/bin/env bash

# pass extension: env
#
# Requires:
# pass with the env extension
# gpg (bundled with pass)
# fzf (optional, for interactive selection)
#
# NOTE: pass extensions are *sourced* into the pass process, not executed.
# Every function and global in this file is therefore prefixed with
# _pass_env_ / PASSENV_ to avoid colliding with pass's own functions
# (e.g. pass defines its own die()) or variables.

set -euo pipefail

readonly PASSENV_VERSION="0.3.1"

# Marker line emitted before each entry's exports by the `set` subcommand.
# contrib/pass-env-init.sh parses these to attribute variables to entries
# (including entries chosen interactively via fzf). It is a shell comment,
# so raw `eval "$(pass env set ...)"` usage is unaffected.
readonly PASSENV_ENTRY_MARKER="# pass-env entry: "

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $@ - Error message text
# Outputs:
#   stderr: formatted error message prefixed with 'pass env:'
# Returns:
#   exits 1 (does not return to the caller)
_pass_env_die() { printf 'pass env: %s\n' "$*" >&2; exit 1; }

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
_pass_env_is_entry_in_store() {
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
# LD_PRELOAD injects shared objects, HOME redirects dotfile loading, FPATH
# hijacks zsh autoloadable functions). A denylist is never complete, but it
# blocks the most common attack vectors.
#
# Arguments:
#   $1 - Variable name to check
# Returns:
#   0 if the name is dangerous
#   1 if the name is safe
_pass_env_is_dangerous_var() {
  case "$1" in
    # Shell resolution, startup, and prompt hooks. Every prompt string is
    # listed, not just PS1: bash expands PS0 with command substitution before
    # running each command, and zsh's PROMPT/RPROMPT family does the same under
    # PROMPT_SUBST, which most zsh frameworks enable.
    PATH|IFS|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|SHELL|HOME|\
    PROMPT_COMMAND|PS0|PS1|PS2|PS3|PS4|\
    PROMPT|PROMPT2|PROMPT3|PROMPT4|RPROMPT|RPS1|RPS2|SPROMPT|\
    FPATH|ZDOTDIR|CDPATH|\
    GLOBIGNORE|RANDOM|LINENO|PIPESTATUS|DIRSTACK)
      return 0 ;;
    # Dynamic linker / libc
    LD_*|DYLD_*|GCONV_PATH|LOCPATH|TMPDIR|TERMINFO|TERMINFO_DIRS)
      return 0 ;;
    # Programs commonly executed implicitly by other tools. LESSOPEN and
    # LESSCLOSE carry a whole command line rather than a program name: less
    # runs a value beginning with '|' through a shell for every file it opens,
    # which covers man, git log and anything else that pages.
    PAGER|MANPAGER|EDITOR|VISUAL|BROWSER|\
    LESSOPEN|LESSCLOSE)
      return 0 ;;
    # git: variables that name a command git will execute, plus the
    # GIT_CONFIG_* family, which names one indirectly by injecting arbitrary
    # config (core.pager, core.sshCommand, core.fsmonitor, alias.*) into every
    # git invocation, including ones with no tty and no pager.
    GIT_SSH|GIT_SSH_COMMAND|GIT_PAGER|GIT_EDITOR|GIT_SEQUENCE_EDITOR|\
    GIT_EXTERNAL_DIFF|GIT_ASKPASS|GIT_PROXY_COMMAND|\
    GIT_CONFIG*)
      return 0 ;;
    # pass and GnuPG's own configuration. An entry that sets these turns the
    # tool against itself: PASSWORD_STORE_DIR repoints every later pass call at
    # a store the attacker controls, PASSWORD_STORE_ENABLE_EXTENSIONS with a
    # store-local .extensions directory turns store write access into code
    # execution, and GNUPGHOME selects a gpg.conf that can name programs to run.
    PASSWORD_STORE_*|GNUPGHOME|GPG_*|PINENTRY_*)
      return 0 ;;
    # Language runtimes: code/path injection on next interpreter start
    PYTHONPATH|PYTHONSTARTUP|PYTHONHOME|\
    PERL5LIB|PERL5OPT|RUBYLIB|RUBYOPT|\
    NODE_OPTIONS|NODE_PATH|\
    JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Print all .env entries in the password store, one per line.
#
# Walks PASSWORD_STORE_DIR, finds every *.env.gpg file, skips symlinks that
# resolve outside the store, strips the store root prefix and the .gpg
# suffix, and prints one sorted entry path per line. Shared by the `list`
# subcommand and the fzf picker.
#
# Arguments:
#   $1 - Password store directory (absolute)
# Outputs:
#   stdout: entry path(s), one per line (no .gpg suffix), sorted
# Returns:
#   0 always
_pass_env_store_entries() {
  local password_store_dir="$1"
  find "${password_store_dir}" -name "*.env.gpg" \( -type f -o -type l \) \
    | while IFS= read -r f; do
      # Skip symlinks that resolve outside the password store.
      _pass_env_is_entry_in_store "${f}" "${password_store_dir}" || continue
      printf '%s\n' "${f#"${password_store_dir}/"}"
    done \
    | sed 's/\.gpg$//' \
    | sort
}

# Present an interactive fzf picker of all .env entries in the password store.
#
# Supports TAB-based multi-selection (fzf --multi). Prints selected entry
# path(s) one per line, with the .gpg suffix removed. Callers must verify
# fzf availability and store existence before calling.
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
_pass_env_fzf_select_entry() {
  local query="${1:-}"
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
  # Buffer the entry list and feed fzf via herestring rather than a pipe:
  # in a pipeline, the producer receives SIGPIPE (status 141) whenever fzf
  # exits before consuming all input, and with pipefail that would be
  # indistinguishable from a real failure. With <<<, the function's status
  # is fzf's alone (0 = selection, 130 = ESC/ctrl-c).
  local entry_list
  entry_list="$(_pass_env_store_entries "${password_store_dir}")"
  fzf "${fzf_args[@]}" <<< "${entry_list}"
}

# Validate a resolved entry name before it is handed back to a caller.
#
# Enforces three properties, in order: the name ends in .env, contains no
# path-traversal component, and is built only from characters that occur in
# legitimate store paths. The character-set check is the security-critical
# one: entry names flow into contexts that evaluate them (associative-array
# subscripts in the passenv shell loader, `compgen -W` in bash completion, the
# fzf preview command), so a name from a hostile store such as 'evil$(id).env'
# must never reach them. Applied to both explicit candidates and names chosen
# interactively via fzf, since fzf lists raw store filenames an attacker with
# write access to the store controls.
#
# Arguments:
#   $1 - Entry name to validate
# Outputs:
#   stderr: error message describing the first failing check
# Returns:
#   0 if the name is valid
#   exits 1 otherwise
_pass_env_validate_name() {
  local name="$1"
  [[ "${name}" == *.env ]] || _pass_env_die "entry name must end in .env: ${name}"
  # Reject absolute paths and any '..' path *component* to prevent directory
  # traversal outside PASSWORD_STORE_DIR. Matching whole components (rather
  # than any '..' substring) keeps legitimate names like 'a..b.env' working.
  if [[ "${name}" == /* || "/${name}/" == *"/../"* ]]; then
    _pass_env_die "invalid entry path (no traversal allowed): ${name}"
  fi
  # Restrict to the characters that appear in real store paths. This blocks
  # shell metacharacters ($ ` ; | & ( ) < > etc.) that would otherwise be
  # evaluated when the name is later used as an array subscript or a
  # completion word.
  [[ "${name}" =~ ^[A-Za-z0-9._/@+-]+$ ]] \
    || _pass_env_die "invalid characters in entry name: ${name}"
}

# Resolve a pass entry path, falling back to fzf when no candidate is given.
#
# If the candidate is non-empty and names a valid .env entry on disk, prints
# it and returns immediately. If the candidate is non-empty but not found,
# exits with an error. Only when the candidate is empty (no argument provided)
# does it launch _pass_env_fzf_select_entry for interactive selection.
# Every resolved name, explicit or interactively selected, is passed through
# _pass_env_validate_name (.env suffix, no traversal, safe character set).
#
# Arguments:
#   $1 - Candidate entry path (optional; triggers fzf if empty or not found)
# Environment:
#   PASSWORD_STORE_DIR - root of the password store (default: ~/.password-store)
# Outputs:
#   stdout: resolved entry path(s), one per line
#   stderr: error if the candidate is invalid or is not found
# Returns:
#   0 on success
#   exits 1 if the candidate is invalid or no entry can be resolved
_pass_env_resolve_entry() {
  local candidate="$1"
  local password_store_dir="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
  if [[ -n "${candidate}" ]]; then
    _pass_env_validate_name "${candidate}"
    local gpg_file="${password_store_dir}/${candidate}.gpg"
    if [[ -f "${gpg_file}" ]]; then
      if ! _pass_env_is_entry_in_store "${gpg_file}" "${password_store_dir}"; then
        _pass_env_die "entry path escapes password store (symlink): ${candidate}"
      fi
      printf '%s\n' "${candidate}"
      return
    fi
    _pass_env_die "entry not found: ${candidate}"
  fi
  # Interactive selection. Validate preconditions here (not inside the
  # command substitution below) so their error messages are not followed
  # by a redundant 'No entry selected.'
  command -v fzf &>/dev/null \
    || _pass_env_die "ENTRY is required (fzf not installed for interactive selection)"
  [[ -d "${password_store_dir}" ]] \
    || _pass_env_die "password store not found: ${password_store_dir} (has pass been initialised?)"
  local selected
  # ESC / ctrl-c makes fzf exit non-zero; the || catches it so the user
  # gets a message instead of a silent set -e exit.
  selected="$(_pass_env_fzf_select_entry "")" || _pass_env_die "No entry selected."
  [[ -n "${selected}" ]] || _pass_env_die "No entry selected."
  # fzf returns raw store filenames; validate each (fzf --multi can return
  # several lines) before emitting so a hostile name never reaches a caller.
  local sel
  while IFS= read -r sel; do
    [[ -n "${sel}" ]] || continue
    _pass_env_validate_name "${sel}"
  done <<< "${selected}"
  printf '%s\n' "${selected}"
}

# Print usage information for the pass env extension to stdout.
#
# Outputs:
#   stdout: usage text covering all subcommands and their options
# Returns:
#   0 always
_pass_env_help() {
  cat <<'EOF'
Usage:
  pass env version
  pass env list
  pass env run   [--no-expand] [ENTRY [ENTRY ...]] -- [VAR=VALUE ...] COMMAND [ARGS...]
  pass env set   [ENTRY [ENTRY ...]]
  pass env unset [ENTRY [ENTRY ...]]
  pass env help

Notes:
  - ENTRY must end in .env  (e.g. os/prod.env, api/openai.env).
  - ENTRY is optional for run/set/unset; omit it to pick interactively
    with fzf (TAB to multi-select).
  - Entries must contain KEY=VALUE lines (one per line).
    Blank lines and lines beginning with # are ignored.
  - When multiple entries define the same variable, later entries
    override earlier ones.
  - `list` prints all .env entries available in the password store.
  - `run`   loads vars into the subprocess only; nothing leaks to the
    calling shell.  Provides isolation and cleanup, but does not protect
    against a compromised store:
              pass env run os/prod.env -- printenv MY_VAR
              pass env run e1.env e2.env -- myapp

    To use an entry's variables as command ARGUMENTS, write {{VAR}}.
    A bare $VAR cannot work: your shell expands it before pass runs, when
    the entry is not yet loaded, so it collapses to an empty string.
    {{VAR}} is inert to the shell, so it needs no quoting:
              pass env run api.env -- myapp --model {{MODEL}} --input "hi"
    Only variables supplied by the named entries (and by VAR=VALUE
    assignments, below) are substituted; any other {{...}} text is left
    alone.  Use --no-expand to disable substitution entirely.

    A leading VAR=VALUE assignment before COMMAND sets that variable for
    the command, overriding the entry, exactly as it would in a shell:
              pass env run api.env -- LOG_LEVEL=debug myapp

  - `set` / `unset` print shell statements; eval them to modify the current
    shell.  If you have sourced contrib/pass-env-init.sh, use `passenv set/unset`
    instead; it handles eval, tracking, and restoring previous values
    automatically:
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
_pass_env_version() {
  printf 'pass-env %s\n' "${PASSENV_VERSION}"
}

# List all .env entries available in the password store.
#
# Environment:
#   PASSWORD_STORE_DIR - root of the password store (default: ~/.password-store)
# Outputs:
#   stdout: available entry path(s), one per line (no .gpg suffix)
# Returns:
#   0 always
_pass_env_list() {
  local password_store_dir="${PASSWORD_STORE_DIR:-${HOME}/.password-store}"
  [[ -d "${password_store_dir}" ]] \
    || _pass_env_die "password store not found: ${password_store_dir} (has pass been initialised?)"
  _pass_env_store_entries "${password_store_dir}"
}

# Iterate over each validated variable in a decrypted pass entry, calling a
# callback for every KEY=VALUE pair. All parsing, validation, and denylist
# checks happen here in one place, callers only provide the emit action.
#
# The emit callbacks assign the variables they are given, and an assignment
# lands in the nearest enclosing scope that already declares that name. This
# function's own locals are therefore reachable from entry content, so they all
# carry the _pass_env_ prefix and keys in that namespace are refused below.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
#   $2 - Callback function name; called as "$callback" "$key" "$val"
# Returns:
#   0 on success, exits 1 on decryption failure, invalid key name, reserved key
#   name, dangerous variable, or unsupported line format
_pass_env_for_each_var() {
  local _pass_env_entry="$1" _pass_env_callback="$2"
  local _pass_env_content _pass_env_key _pass_env_val _pass_env_line
  _pass_env_content="$(pass show -- "${_pass_env_entry}")" \
    || _pass_env_die "unable to show entry: ${_pass_env_entry}"
  while IFS= read -r _pass_env_line; do
    # Strip trailing CR (handles CRLF files transparently)
    _pass_env_line="${_pass_env_line%$'\r'}"
    [[ -z "${_pass_env_line}" ]] && continue
    case "${_pass_env_line}" in \#*) continue ;; esac
    if [[ "${_pass_env_line}" =~ ^([^=]+)=(.*)$ ]]; then
      _pass_env_key="${BASH_REMATCH[1]}"; _pass_env_val="${BASH_REMATCH[2]}"
      [[ "${_pass_env_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || _pass_env_die "invalid variable name in ${_pass_env_entry}: ${_pass_env_key}"
      # Reserved namespace. Without this a key of 'callback' would rebind the
      # dispatch target on the line below and the next line of the entry would
      # be executed as a command; '_PASS_ENV_LOADED_NAMES' would forge the
      # placeholder allowlist. Renaming the locals is what makes one prefix
      # test sufficient here.
      case "${_pass_env_key}" in
        _pass_env_*|_PASS_ENV_*)
          _pass_env_die "reserved variable name in ${_pass_env_entry}: ${_pass_env_key}" ;;
      esac
      if _pass_env_is_dangerous_var "${_pass_env_key}"; then
        _pass_env_die "refusing to set sensitive variable from entry: ${_pass_env_key}"
      fi
      "${_pass_env_callback}" "${_pass_env_key}" "${_pass_env_val}"
    else
      _pass_env_die "unsupported line format in ${_pass_env_entry} (expected KEY=VALUE)"
    fi
  done <<< "${_pass_env_content}"
}

# Decrypt a pass entry and emit KEY=QUOTEDVAL lines.
#
# Each non-blank, non-comment line must be in KEY=VALUE format. Key names are
# validated against ^[A-Za-z_][A-Za-z0-9_]*$. Values are shell-quoted with
# printf %q so the output is safe to eval or source directly.
#
# Output is buffered: nothing is emitted until the entire entry parses
# successfully, so a malformed line produces no partial output.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: KEY=QUOTEDVAL lines, one per variable
#   stderr: error message on invalid content or decryption failure
# Returns:
#   0 on success
#   exits 1 on decryption failure, invalid key name, or unsupported line format
_pass_env_parse_entry() {
  local _pass_env_parse_buf=""
  _pass_env_for_each_var "$1" _pass_env_parse_buf_emit
  printf '%s\n' "${_pass_env_parse_buf}"
}

# Callback for _pass_env_parse_entry: buffer KEY=%q lines instead of emitting
# immediately.
_pass_env_parse_buf_emit() {
  _pass_env_parse_buf="${_pass_env_parse_buf}${_pass_env_parse_buf:+
}$(printf '%s=%q' "$1" "$2")"
}

# Export all variables from a pass entry directly into the current (sub)shell.
#
# Parses the entry and calls 'export KEY=VALUE' for each line using the raw
# value, without printf %q encoding or eval. The key is validated; the value
# is assigned as-is so special characters (!, $, #, etc.) are preserved.
# Used by _pass_env_run_with_env; _pass_env_set_env is used by the set
# subcommand for eval output.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Returns:
#   0 on success, exits 1 on decryption failure, invalid key name, or
#   unsupported line format
_pass_env_export_entry() {
  _pass_env_for_each_var "$1" _pass_env_export_emit
}

# Callback for _pass_env_export_entry: export KEY=VALUE directly and record
# the name in _PASS_ENV_LOADED_NAMES so it can be referenced by a {{NAME}}
# placeholder in the command's arguments.
_pass_env_export_emit() {
  export "$1=$2"
  _PASS_ENV_LOADED_NAMES="${_PASS_ENV_LOADED_NAMES:-}${_PASS_ENV_LOADED_NAMES:+ }$1"
}

# Substitute {{NAME}} placeholders in a single argument.
#
# Why placeholders exist at all: the calling shell expands $NAME *before*
# pass runs, when the entry is not yet loaded, so a bare $NAME on the command
# line always collapses to an empty string. {{NAME}} is inert to both bash and
# zsh (brace expansion requires a comma or a .. range), so it survives the
# call site unquoted and can be resolved here, after the entry is loaded.
#
# Only names in the allowlist ($1) are substituted; these are the variables
# actually supplied by the named entries plus any leading VAR=value assignments
# on the command. Any other {{...}} text (e.g. a Handlebars template) is left
# exactly as written.
#
# Safety: substitution uses parameter expansion only. There is no eval and the
# result is never re-parsed, so a value from a compromised store becomes an
# inert argument string rather than executable code.
#
# The result is returned in the global _PASS_ENV_EXPANDED rather than on stdout
# so that no command-substitution subshell is forked per argument.
#
# Arguments:
#   $1 - Space-separated allowlist of variable names
#   $2 - The argument to expand
# Environment:
#   _PASS_ENV_EXPANDED - set to the expanded argument
# Returns:
#   0 always
_pass_env_expand_placeholders() {
  local names=" $1 " rest="$2"
  local out="" name
  while [[ "${rest}" == *'{{'* ]]; do
    out="${out}${rest%%\{\{*}"   # text before the '{{'
    rest="${rest#*\{\{}"         # text after the '{{'
    if [[ "${rest}" != *'}}'* ]]; then
      # No closing '}}': nothing further can be a placeholder.
      out="${out}{{"
      continue
    fi
    name="${rest%%\}\}*}"
    if [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "${names}" == *" ${name} "* ]]; then
      out="${out}${!name}"
      rest="${rest#*\}\}}"
    else
      # Not a variable this run provides: emit the '{{' literally and keep
      # scanning after it, leaving the rest of the text untouched.
      out="${out}{{"
    fi
  done
  _PASS_ENV_EXPANDED="${out}${rest}"
}

# Execute a command with environment variables from one or more pass entries.
#
# Builds the command's environment and argument list in explicit stages, then
# execs. Everything happens inside a subshell, so no variables are written to
# disk and nothing leaks into the calling shell:
#
#   1. Load the entries. Later entries override earlier ones.
#   2. Apply any leading VAR=value assignments that precede COMMAND. These
#      override the entries, matching normal shell precedence
#      (`FOO=bar mycmd` sets FOO for mycmd). They come from the user rather
#      than from the store, so the denylist that guards entry content does not
#      apply to them, exactly as a shell would not second-guess them.
#   3. Substitute {{NAME}} placeholders in the remaining arguments, unless
#      expansion is disabled. The allowlist is the set of names supplied by
#      stages 1 and 2.
#   4. exec the command.
#
# Arguments:
#   $1 - "true" to expand {{NAME}} placeholders, "false" to leave them literal
#   $@ - ENTRY [ENTRY ...] -- COMMAND [ARGS...]
#        Entry paths must precede '--'; everything after '--' is the command,
#        optionally prefixed by VAR=value assignments.
# Outputs:
#   stdout/stderr: forwarded from COMMAND
# Returns:
#   exit status of COMMAND
#   exits 1 if ENTRY or COMMAND arguments are missing
_pass_env_run_with_env() {
  local _pass_env_expand="$1"; shift
  local _pass_env_entries=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    _pass_env_entries+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift
  [[ "${#_pass_env_entries[@]}" -ge 1 ]] || _pass_env_die "run: missing ENTRY"
  [[ "$#" -ge 1 ]] || _pass_env_die "run: missing COMMAND"
  (
    # Stage 1: entries. Locals in this function carry the _pass_env_ prefix
    # because stage 1 exports entry-controlled names into this scope; see
    # _pass_env_for_each_var for the reserved-namespace check that pairs
    # with the naming.
    _PASS_ENV_LOADED_NAMES=""
    local _pass_env_e
    for _pass_env_e in "${_pass_env_entries[@]}"; do
      _pass_env_export_entry "${_pass_env_e}"
    done

    # Stage 2: leading VAR=value assignments, which override the entries.
    local _pass_env_key _pass_env_val
    while [[ $# -gt 0 && "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      _pass_env_key="${1%%=*}"
      _pass_env_val="${1#*=}"
      export "${_pass_env_key}=${_pass_env_val}"
      _PASS_ENV_LOADED_NAMES="${_PASS_ENV_LOADED_NAMES:+${_PASS_ENV_LOADED_NAMES} }${_pass_env_key}"
      shift
    done
    # Every remaining token was an assignment: there is no command to run.
    [[ "$#" -ge 1 ]] || _pass_env_die "run: missing COMMAND"

    # Stage 3: {{NAME}} placeholder substitution.
    if [[ "${_pass_env_expand}" == true ]]; then
      local _pass_env_args=() _pass_env_a
      for _pass_env_a in "$@"; do
        _pass_env_expand_placeholders "${_PASS_ENV_LOADED_NAMES}" "${_pass_env_a}"
        _pass_env_args+=("${_PASS_ENV_EXPANDED}")
      done
      set -- "${_pass_env_args[@]}"
    fi

    # Stage 4: exec.
    exec "$@"
  )
}

# Emit an entry marker followed by 'export KEY=QUOTEDVAL' lines for all
# variables in a pass entry.
#
# Output is intended to be captured and eval'd by the caller to load variables
# into the current shell (the marker is a shell comment and eval-safe). When
# used via contrib/pass-env-init.sh, the loader parses the marker to attribute
# variables to the entry and handles the eval automatically.
#
# Arguments:
#   $1 - Pass entry path (relative to PASSWORD_STORE_DIR)
# Outputs:
#   stdout: marker line, then 'export KEY=QUOTEDVAL' lines, one per variable
# Returns:
#   0 on success, exits 1 on any error (see _pass_env_parse_entry)
_pass_env_set_env() {
  # Parse first so the marker is not emitted for a malformed entry
  # (preserves the "no partial output on error" guarantee).
  local parsed
  parsed="$(_pass_env_parse_entry "$1")"
  printf '%s%s\n' "${PASSENV_ENTRY_MARKER}" "$1"
  printf '%s\n' "${parsed}" | sed 's/^/export /'
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
#   0 on success, exits 1 on any error (see _pass_env_parse_entry)
_pass_env_unset_env() {
  local keys=() line
  while IFS= read -r line; do
    keys+=("${line%%=*}")
  done < <(_pass_env_parse_entry "$1")
  if [[ "${#keys[@]}" -gt 0 ]]; then
    printf 'unset %s\n' "${keys[@]}"
  fi
}

# Resolve entry arguments (explicit or interactive) and invoke a handler for
# each resolved entry. Shared by the set/unset dispatch arms.
#
# Arguments:
#   $1 - Handler function name, called once per resolved entry
#   $@ - Raw entry arguments (may be empty to trigger the fzf picker)
# Returns:
#   0 on success, exits 1 on any resolution or handler error
_pass_env_for_each_resolved() {
  local handler="$1"; shift
  local resolved e raw_e
  if [[ "$#" -eq 0 ]]; then
    resolved="$(_pass_env_resolve_entry "")" || exit 1
    while IFS= read -r e; do "${handler}" "${e}"; done <<< "${resolved}"
    return
  fi
  for raw_e in "$@"; do
    resolved="$(_pass_env_resolve_entry "${raw_e}")" || exit 1
    while IFS= read -r e; do "${handler}" "${e}"; done <<< "${resolved}"
  done
}

# Main dispatcher. Wrapped in a function so argument-handling variables stay
# local instead of leaking into the pass process (extensions are sourced).
#
# Arguments:
#   $@ - Subcommand and its arguments
_pass_env_main() {
  local cmd="${1:-help}"
  shift || true
  case "${cmd}" in
    help|-h|--help) _pass_env_help ;;
    version|-v|--version) _pass_env_version ;;
    list) _pass_env_list ;;
    run)
      local expand=true
      local raw_entries=() entries=() resolved e raw_e
      # Flags precede the entries. Only --no-expand is supported; it turns off
      # {{NAME}} placeholder substitution for the command's arguments.
      while [[ $# -gt 0 && "${1}" != "--" ]]; do
        case "${1}" in
          --no-expand) expand=false; shift ;;
          *) break ;;
        esac
      done
      while [[ $# -gt 0 && "${1}" != "--" ]]; do
        raw_entries+=("$1"); shift
      done
      [[ "${1:-}" == "--" ]] && shift
      if [[ "${#raw_entries[@]}" -eq 0 ]]; then
        resolved="$(_pass_env_resolve_entry "")" || exit 1
        while IFS= read -r e; do entries+=("${e}"); done <<< "${resolved}"
      else
        for raw_e in "${raw_entries[@]}"; do
          resolved="$(_pass_env_resolve_entry "${raw_e}")" || exit 1
          while IFS= read -r e; do entries+=("${e}"); done <<< "${resolved}"
        done
      fi
      _pass_env_run_with_env "${expand}" "${entries[@]}" -- "$@"
      ;;
    set)
      local raw_entries=()
      while [[ $# -gt 0 && "${1}" != "--" ]]; do
        raw_entries+=("$1"); shift
      done
      _pass_env_for_each_resolved _pass_env_set_env ${raw_entries[@]+"${raw_entries[@]}"}
      ;;
    unset)
      local raw_entries=()
      while [[ $# -gt 0 && "${1}" != "--" ]]; do
        raw_entries+=("$1"); shift
      done
      _pass_env_for_each_resolved _pass_env_unset_env ${raw_entries[@]+"${raw_entries[@]}"}
      ;;
    *) _pass_env_die "unknown subcommand: ${cmd} (try 'pass env help')" ;;
  esac
}

_pass_env_main "$@"
