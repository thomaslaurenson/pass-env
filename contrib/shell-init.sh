# passenv shell loader
# Source this in ~/.bashrc and/or ~/.zshrc:
#   source /path/to/pass-env/shell/loader.sh
#
# Requires: pass with the env extension, gpg, fzf (for interactive selection)
# Compatible with bash 4+ and zsh 5.2+

# ---------------------------------------------------------------------------
# Initialise the tracking associative array exactly once per session.
# The guard prevents re-initialisation if the file is sourced more than once.
# ---------------------------------------------------------------------------
if [[ -z "${_PASSENV_TRACKER+x}" ]]; then
  declare -A _PASSENV_TRACKER
fi

# ---------------------------------------------------------------------------
# _passenv_keys
#   Print each key of _PASSENV_TRACKER on its own line.
#   Uses eval to isolate zsh-specific syntax from the bash parser.
# ---------------------------------------------------------------------------
_passenv_keys() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval 'printf "%s\n" "${(@k)_PASSENV_TRACKER}"'
  else
    printf '%s\n' "${!_PASSENV_TRACKER[@]}"
  fi
}

# ---------------------------------------------------------------------------
# _passenv_indirect VARNAME
#   Print the runtime value of the variable named VARNAME.
#   Uses eval so that neither shell sees the other's indirection syntax.
# ---------------------------------------------------------------------------
_passenv_indirect() {
  eval "printf '%s' \"\${$1}\""
}

# ---------------------------------------------------------------------------
# _passenv_split_words STRING
#   Print each whitespace-separated word of STRING on its own line.
#   Avoids the read -a (bash) vs read -A (zsh) incompatibility.
# ---------------------------------------------------------------------------
_passenv_split_words() {
  printf '%s\n' $1
}

# ---------------------------------------------------------------------------
# passenv — main entry point
# ---------------------------------------------------------------------------
passenv() {
  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    set)     _passenv_set   "$@" ;;
    unset)   _passenv_unset "$@" ;;
    list)    _passenv_list        ;;
    print)   _passenv_print       ;;
    help|-h|--help) _passenv_help ;;
    *) printf 'passenv: unknown subcommand: %s\n' "$subcmd" >&2
       _passenv_help >&2
       return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# passenv set [ENTRY...]
#   Decrypt one or more pass entries, eval the exported vars into the current
#   shell, and record each entry and its var names in _PASSENV_TRACKER.
#   With no ENTRY, an interactive fzf picker is launched inside the pass-env
#   extension; fzf --multi may return several entries in one call.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# _passenv_load_one ENTRY
#   Internal helper: load a single pass entry into the current shell.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# passenv unset [ENTRY...]
#   Unset all vars tracked for each ENTRY and remove them from the tracker.
#   If no ENTRY is given, a multi-select fzf picker is shown over loaded entries.
# ---------------------------------------------------------------------------
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
    # eval expands $entry before unset sees the array subscript.
    eval "unset '_PASSENV_TRACKER[$entry]'"

    printf 'passenv: unset %s → %s\n' "$entry" "$varlist"
  done
}

# ---------------------------------------------------------------------------
# passenv list
#   Print a formatted table of all currently loaded entries and their vars.
# ---------------------------------------------------------------------------
_passenv_list() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n'
    return 0
  fi

  printf '%-40s %s\n' 'ENTRY' 'VARIABLES'
  printf '%-40s %s\n' '----------------------------------------' '---------'
  _passenv_keys | while IFS= read -r k; do
    printf '%-40s %s\n' "$k" "${_PASSENV_TRACKER[$k]}"
  done
}

# ---------------------------------------------------------------------------
# passenv print
#   Print each tracked var and its live value. Mask sensitive var names.
# ---------------------------------------------------------------------------
_passenv_print() {
  if [[ ${#_PASSENV_TRACKER[@]} -eq 0 ]]; then
    printf 'passenv: no entries are currently loaded\n'
    return 0
  fi

  _passenv_keys | while IFS= read -r k; do
    printf '# %s\n' "$k"
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      local val
      val="$(_passenv_indirect "$v")"
      if printf '%s' "$v" | grep -qiE '(SECRET|TOKEN|PASSWORD|KEY|PASS)'; then
        printf '  %s=%s\n' "$v" '******'
      else
        printf '  %s=%s\n' "$v" "$val"
      fi
    done < <(_passenv_split_words "${_PASSENV_TRACKER[$k]}")
  done
}

# ---------------------------------------------------------------------------
# passenv help
# ---------------------------------------------------------------------------
_passenv_help() {
  cat <<'EOF'
Usage: passenv <subcommand> [ENTRY]

Subcommands:
  set   [ENTRY]   Decrypt a pass entry and load its vars into the current shell.
                  If ENTRY is omitted, an interactive fzf picker is launched.
                  Example:  passenv set os/undercloud.env

  unset [ENTRY]   Unset the vars loaded from ENTRY in the current shell.
                  If ENTRY is omitted, an interactive fzf picker is shown over
                  currently loaded entries.
                  Example:  passenv unset os/undercloud.env

  list            Print all currently loaded entries and their variable names.

  print           Print currently loaded vars and their live values.
                  Values for vars whose names contain SECRET, TOKEN, PASSWORD,
                  KEY, or PASS are masked as ******.

  help            Show this message.

Notes:
  - Pass entries must contain KEY=VALUE lines (one per line).
  - Blank lines and # comment lines are ignored.
  - _PASSENV_TRACKER is session-local and reset on shell exit.
  - Requires: pass with the env extension, gpg, fzf.
EOF
}
