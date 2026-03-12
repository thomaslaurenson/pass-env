#!/usr/bin/env bash
# pass extension: env
# Location: ~/.password-store/.extensions/env.bash
# Usage: pass env <subcommand> [flags]

set -euo pipefail

PASS_CMD="pass"  # in case you need to call back into pass

die() { printf 'pass env: %s\n' "$*" >&2; exit 1; }

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

# Resolve an entry: use candidate if it exists in the store, otherwise fall
# back to interactive fzf selection (pre-seeded with the candidate as query).
# Prints one or more entry paths, one per line (fzf --multi may return many).
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

help() {
  cat <<'EOF'
Usage:
  pass env run   [ENTRY [ENTRY ...]] -- COMMAND [ARGS...]
  pass env set   [ENTRY [ENTRY ...]]
  pass env unset [ENTRY [ENTRY ...]]
  pass env help

Notes:
  - ENTRY must end in .env  (e.g. os/prod.env, api/openai.env).
  - ENTRY is optional for all subcommands; omit it to pick interactively
    with fzf (TAB to multi-select).
  - Entries must contain KEY=VALUE lines (one per line).
    Blank lines and lines beginning with # are ignored.
  - `run`   loads vars into the subprocess only; nothing leaks to the
    calling shell (safest option):
              pass env run os/prod.env -- printenv MY_VAR
              pass env run e1.env e2.env -- myapp
  - `set` / `unset` print shell statements; eval them to modify the current
    shell.  If you have sourced shell/loader.sh, use `passenv set/unset`
    instead — it handles eval and tracking automatically:
              passenv set os/prod.env
              passenv set os/prod.env api/openai.env
              passenv unset os/prod.env
    Raw eval form (without loader.sh):
              eval "$(pass env set os/prod.env)"
              eval "$(pass env unset os/prod.env)"
EOF
}

_parse_entry() {
  # Internal: decrypt ENTRY and emit KEY=QUOTEDVAL lines (one per variable).
  # Blank lines and # comment lines are skipped. Key names are validated as
  # legal shell identifiers: ^[A-Za-z_][A-Za-z0-9_]*$
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

print_entry() {
  # Emit KEY=QUOTEDVAL lines from a pass entry (used by run_with_env).
  _parse_entry "$1"
}

run_with_env() {
  # Args: ENTRY [ENTRY ...] -- COMMAND [ARGS...]
  # Vars are loaded into a subshell only; nothing is written to disk.
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

set_env() {
  # Emit `export KEY=QUOTEDVAL` lines for ENTRY; pipe output to eval to load
  # the variables into the current shell (or a subshell for `run`).
  _parse_entry "$1" | sed 's/^/export /'
}

unset_env() {
  # Emit `unset KEY KEY ...` for all variables defined in ENTRY.
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
  run)
    raw_entry=""
    saw_dashdash=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) raw_entry="$2"; shift 2 ;;
        --) shift; saw_dashdash=1; break ;;
        *) break ;;
      esac
    done
    # Only pick up a positional entry if -- hasn't already been consumed;
    # if -- was seen first, everything remaining is the command.
    if [ "$saw_dashdash" -eq 0 ]; then
      [ -z "$raw_entry" ] && [ $# -gt 0 ] && { raw_entry="$1"; shift; }
      [ "${1:-}" = "--" ] && shift  # consume -- that follows a positional entry
    fi
    entries=()
    while IFS= read -r e; do entries+=("$e"); done < <(_resolve_entry "$raw_entry")
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
      while IFS= read -r e; do set_env "$e"; done < <(_resolve_entry "")
    else
      for raw_e in "${raw_entries[@]}"; do
        while IFS= read -r e; do set_env "$e"; done < <(_resolve_entry "$raw_e")
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
      while IFS= read -r e; do unset_env "$e"; done < <(_resolve_entry "")
    else
      for raw_e in "${raw_entries[@]}"; do
        while IFS= read -r e; do unset_env "$e"; done < <(_resolve_entry "$raw_e")
      done
    fi
    ;;
  *) die "unknown subcommand: $cmd (try 'pass env help')" ;;
esac
