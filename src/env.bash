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

  local key val
  while IFS= read -r line; do
    # Skip blank lines
    [ -z "$line" ] && continue
    # Skip comment lines (#)
    case "$line" in \#*) continue ;; esac
    # Accept KEY=VALUE; validate the key is a legal shell identifier
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in $entry: $key"
    else
      die "unsupported line format in $entry: $line"
    fi
    # Re-emit with shell-safe quoting
    printf '%s=%q\n' "$key" "$val"
  done <<< "$content"
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
  # Read a KEY=VALUE entry from pass and emit `export KEY=VALUE` lines for eval.
  local entry="$1"
  local content
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"
  local key val
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in $entry: $key"
      printf 'export %s=%q\n' "$key" "$val"
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
  local keys=() key
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if [[ "$line" =~ ^([^=]+)= ]]; then
      key="${BASH_REMATCH[1]}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in $entry: $key"
      keys+=("$key")
    fi
  done <<< "$content"
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
    raw_entry=""
    [ "${1:-}" = "--entry" ] && { raw_entry="${2:-}"; shift 2; }
    [ -z "$raw_entry" ] && [ $# -gt 0 ] && { raw_entry="$1"; shift; }
    while IFS= read -r e; do set_env "$e"; done < <(_resolve_entry "$raw_entry")
    ;;
  unset)
    raw_entry=""
    [ "${1:-}" = "--entry" ] && { raw_entry="${2:-}"; shift 2; }
    [ -z "$raw_entry" ] && [ $# -gt 0 ] && { raw_entry="$1"; shift; }
    while IFS= read -r e; do unset_env "$e"; done < <(_resolve_entry "$raw_entry")
    ;;
  *) die "unknown subcommand: $cmd (try 'pass env help')" ;;
esac
