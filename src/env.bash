#!/usr/bin/env bash
# pass extension: env
# Location: ~/.password-store/.extensions/env.bash
# Usage: pass env <subcommand> [flags]

set -euo pipefail

PASS_CMD="pass"  # in case you need to call back into pass

die() { printf 'pass env: %s\n' "$*" >&2; exit 1; }

help() {
  cat <<'EOF'
Usage:
  pass env print --entry PATH [--export]
  pass env run --entry PATH -- COMMAND [ARGS...]
  pass env set NAME VALUE --entry PATH
  pass env unset NAME --entry PATH
  pass env ls --entry PATH
  pass env help

Notes:
  - The --entry PATH argument is required for all commands.
  - Entries contain either KEY=VALUE lines or export KEY=VALUE lines.
  - Use `print` with --export to force "export KEY=VALUE" output.
  - `run` loads variables only for the invoked COMMAND (safer).
EOF
}

# ---- helpers ----
entry_arg() {
  local entry="$ENTRY_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry) [ $# -ge 2 ] || die "--entry requires a value"; entry="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$entry"
  # echo remaining args to stdout? We'll just rely on caller to re-parse.
}

print_entry() {
  # $1: entry path; $2: mode "raw" or "export"
  local entry="$1" mode="${2:-raw}"
  # Decrypt content
  local content
  content="$("$PASS_CMD" show -- "$entry")" || die "unable to show entry: $entry"

  # Normalize to KEY=VALUE lines:
  # - If lines already start with 'export ', strip it unless mode=export
  # - Ensure values are shell-escaped
  while IFS= read -r line; do
    # skip blanks/comments
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac

    # Accept either KEY=VAL or export KEY=VAL
    if [[ "$line" =~ ^export[[:space:]]+([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    else
      die "unsupported line format in $entry: $line"
    fi

    # Re-emit safely (re-quote)
    # Use printf %q for bash; for POSIX you'd need a custom escaper
    if [ "$mode" = export ]; then
      printf 'export %s=%q\n' "$key" "$val"
    else
      printf '%s=%q\n' "$key" "$val"
    fi
  done <<< "$content"
}

run_with_env() {
  local entry="$1"; shift
  [ "$#" -ge 1 ] || die "run: missing COMMAND"
  # Build an env file for a subshell
  local tmp
  tmp="$(mktemp)"
  # Ensure cleanup even if command fails
  trap 'rm -f "$tmp"' EXIT
  print_entry "$entry" raw >"$tmp"
  # shellcheck disable=SC1090
  ( set -a; . "$tmp"; exec "$@" )
  # trap will clean up on function exit
}

set_var() {
  local name="$1" value="$2" entry="$3"
  # Load content, update or append the KEY=VALUE line, write back via pass edit
  local content
  content="$("$PASS_CMD" show -- "$entry" 2>/dev/null || true)"
  local updated=""
  local found=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^([[:space:]]*export[[:space:]]+)?$name= ]]; then
      updated+="$name=$value"$'\n'
      found=1
    else
      updated+="$line"$'\n'
    fi
  done <<< "$content"
  [ "$found" -eq 1 ] || updated+="$name=$value"$'\n'

  # Write back using pass's editor pipeline
  printf '%s' "$updated" | "$PASS_CMD" insert -m -f -- "$entry" >/dev/null
  printf 'Set %s in %s\n' "$name" "$entry"
}

unset_var() {
  local name="$1" entry="$2"
  local content
  content="$("$PASS_CMD" show -- "$entry" 2>/dev/null || true)"
  [ -n "$content" ] || die "entry not found or empty: $entry"

  local updated=""
  local removed=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^([[:space:]]*export[[:space:]]+)?$name= ]]; then
      removed=1; continue
    fi
    updated+="$line"$'\n'
  done <<< "$content"

  printf '%s' "$updated" | "$PASS_CMD" insert -m -f -- "$entry" >/dev/null
  [ "$removed" -eq 1 ] && printf 'Unset %s in %s\n' "$name" "$entry" || printf 'No %s in %s\n' "$name" "$entry"
}

# ---- dispatcher ----
cmd="${1:-help}"; shift || true
case "$cmd" in
  help|-h|--help) help ;;
  print)
    mode="raw"
    entry=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) entry="$2"; shift 2 ;;
        --export) mode="export"; shift ;;
        *) break ;;
      esac
    done
    [ -n "$entry" ] || die "Required: --entry PATH (see 'pass env help')"
    print_entry "$entry" "$mode"
    ;;
  run)
    entry=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --entry) entry="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    [ -n "$entry" ] || die "Required: --entry PATH (see 'pass env help')"
    run_with_env "$entry" "$@"
    ;;
  set)
    name="${1:-}"
    value="${2:-}"
    entry=""
    shift 2 || true
    if [ -z "${name:-}" ] || [ -z "${value:-}" ]; then die "usage: pass env set NAME VALUE --entry PATH"; fi
    [ "${1:-}" = "--entry" ] && { entry="${2:-}"; shift 2; }
    [ -n "$entry" ] || die "Required: --entry PATH (see 'pass env help')"
    set_var "$name" "$value" "$entry"
    ;;
  unset)
    name="${1:-}"
    entry=""
    shift || true
    [ -n "${name:-}" ] || die "usage: pass env unset NAME --entry PATH"
    [ "${1:-}" = "--entry" ] && { entry="${2:-}"; shift 2; }
    [ -n "$entry" ] || die "Required: --entry PATH (see 'pass env help')"
    unset_var "$name" "$entry"
    ;;
  ls)
    entry=""
    [ "${1:-}" = "--entry" ] && { entry="${2:-}"; shift 2; }
    [ -n "$entry" ] || die "Required: --entry PATH (see 'pass env help')"
    print_entry "$entry" raw | sed 's/=.*$//'
    ;;
  *) die "unknown subcommand: $cmd (try 'pass env help')" ;;
esac
