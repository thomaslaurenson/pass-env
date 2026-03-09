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
    find "$password_store_dir" \
        -name "*.gpg" \
        -printf "%P\n" \
        | sed 's/\.gpg$//' \
        | sort \
        | fzf --multi \
              --height=40% \
              --layout=reverse \
              --border \
              --prompt="Pass entry: " \
              --header="ENTER: select one  |  TAB+ENTER: select multiple  |  ESC: cancel" \
              ${query:+--query="$query"} \
        | head -n1
}

# Resolve an entry: use candidate if it exists in the store, otherwise fall
# back to interactive fzf selection (pre-seeded with the candidate as query).
_resolve_entry() {
    local candidate="$1"
    local password_store_dir="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
    if [ -n "$candidate" ]; then
        if [ -f "$password_store_dir/$candidate.gpg" ]; then
            printf '%s' "$candidate"
            return
        fi
        printf 'pass env: entry not found: %s\n' "$candidate" >&2
    fi
    local selected
    selected="$(_fzf_select_entry "$candidate")"
    [ -n "$selected" ] || die "No entry selected."
    printf '%s' "$selected"
}

help() {
  cat <<'EOF'
Usage:
  pass env run   [ENTRY]  -- COMMAND [ARGS...]
  pass env set   [ENTRY]
  pass env unset [ENTRY]
  pass env help

Notes:
  - ENTRY is optional; omit it to pick interactively with fzf.
  - Entries must contain KEY=VALUE lines (one per line).
  - `run`   loads vars only for the invoked COMMAND (one-off, safer).
  - `set`   prints export statements; eval to load vars into the current shell:
              eval "$(pass env set ENTRY)"
  - `unset` prints unset statements; eval to remove vars from the current shell:
              eval "$(pass env unset ENTRY)"
EOF
}

print_entry() {
  # $1: Entry path of password store
  local entry="$1"

  # Decrypt content from password store
  local content
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"

  while IFS= read -r line; do
    # Skip blank lines
    [ -z "$line" ] && continue
    # Skip comment lines (#)
    case "$line" in \#*) continue ;; esac
    # Accept KEY=VALUE
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    else
      die "unsupported line format in $entry: $line"
    fi
    # Re-emit with shell-safe quoting
    printf '%s=%q\n' "$key" "$val"
  done <<< "$content"
}

run_with_env() {
  # $1: entry path of password store
  local entry="$1"; shift
  [ "$#" -ge 1 ] || die "run: missing COMMAND"
  # Build an env file for a subshell
  local tmp
  tmp="$(mktemp)"
  # Ensure cleanup even if command fails
  trap 'rm -f "$tmp"' EXIT
  print_entry "$entry" >"$tmp"
  # shellcheck disable=SC1090
  ( set -a; . "$tmp"; exec "$@" )
  # trap will clean up on function exit
}

set_env() {
  # Read a KEY=VALUE entry from pass and emit `export KEY=VALUE` lines for eval.
  local entry="$1"
  local content
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      printf 'export %s=%q\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      die "unsupported line format in $entry: $line"
    fi
  done <<< "$content"
}

unset_env() {
  # Read a KEY=VALUE entry from pass and emit `unset KEY ...` lines for eval.
  local entry="$1"
  local content
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"
  local keys=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [[ "$line" =~ ^([^=]+)= ]]; then
      keys+=("${BASH_REMATCH[1]}")
    fi
  done <<< "$content"
  [ ${#keys[@]} -gt 0 ] && printf 'unset %s\n' "${keys[*]}"
}

# ---- dispatcher ----
cmd="${1:-help}"; shift || true
case "$cmd" in
  help|-h|--help) help ;;
  run)
    entry=""
    saw_dashdash=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) entry="$2"; shift 2 ;;
        --) shift; saw_dashdash=1; break ;;
        *) break ;;
      esac
    done
    # Only pick up a positional entry if -- hasn't already been consumed;
    # if -- was seen first, everything remaining is the command.
    if [ "$saw_dashdash" -eq 0 ]; then
      [ -z "$entry" ] && [ $# -gt 0 ] && { entry="$1"; shift; }
      [ "${1:-}" = "--" ] && shift  # consume -- that follows a positional entry
    fi
    entry="$(_resolve_entry "$entry")"
    run_with_env "$entry" "$@"
    ;;
  set)
    entry=""
    [ "${1:-}" = "--entry" ] && { entry="${2:-}"; shift 2; }
    [ -z "$entry" ] && [ $# -gt 0 ] && { entry="$1"; shift; }
    entry="$(_resolve_entry "$entry")"
    set_env "$entry"
    ;;
  unset)
    entry=""
    [ "${1:-}" = "--entry" ] && { entry="${2:-}"; shift 2; }
    [ -z "$entry" ] && [ $# -gt 0 ] && { entry="$1"; shift; }
    entry="$(_resolve_entry "$entry")"
    unset_env "$entry"
    ;;
  *) die "unknown subcommand: $cmd (try 'pass env help')" ;;
esac
