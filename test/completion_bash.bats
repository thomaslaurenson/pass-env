#!/usr/bin/env bats

# Tests for completion/pass-env.bash.completion
#
# The completion functions are driven directly: COMP_WORDS and COMP_CWORD are
# set, the function is called, and COMPREPLY is asserted. bash-completion is
# not required, so this suite behaves the same on a runner that lacks it.
#
# setup() supplies three stand-ins for bash-completion. Each records what it
# was asked to do rather than swallowing it, so a test can assert the request:
#   _init_completion  populates cur/prev/words/cword from COMP_WORDS
#   compopt           appends its arguments to COMPOPT_CALLS
#   _command_offset   appends its argument to COMMAND_OFFSET_CALLS
#
# What these fakes deliberately do NOT model is readline's own quoting of the
# words it inserts from COMPREPLY. That happens in the terminal, after this
# code has returned, so no test in this file can observe it. It is covered by
# the pty-driven test instead.

bats_require_minimum_version 1.7.0

# Configure the test environment before each test.
#
# Globals:
#   BATS_TEST_DIRNAME - provided by bats
#   REPO_ROOT, PASSWORD_STORE_DIR - set
#   COMPOPT_CALLS, COMMAND_OFFSET_CALLS - reset, then appended to by the fakes
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"

  COMPOPT_CALLS=()
  COMMAND_OFFSET_CALLS=()
  declare -gA _PASSENV_TRACKER=()

  _init_completion() {
    cur="${COMP_WORDS[COMP_CWORD]}"
    if (( COMP_CWORD > 0 )); then prev="${COMP_WORDS[COMP_CWORD-1]}"; else prev=""; fi
    words=("${COMP_WORDS[@]}")
    cword="$COMP_CWORD"
    return 0
  }
  compopt() { COMPOPT_CALLS+=("$*"); }
  _command_offset() { COMMAND_OFFSET_CALLS+=("$1"); }

  source "$REPO_ROOT/completion/pass-env.bash.completion"
}

# Drive a completion function against a command line.
#
# The last argument is the token being completed, matching how readline calls
# a completion with the cursor at the end of the current word.
#
# Arguments:
#   $1 - Completion function name
#   $@ - Words on the command line
# Globals:
#   COMP_WORDS, COMP_CWORD, COMPREPLY - set
complete_with() {
  local fn="$1"; shift
  COMP_WORDS=("$@")
  COMP_CWORD=$(( $# - 1 ))
  COMPREPLY=()
  "$fn"
}

# pass env: subcommand completion

@test "pass env: offers every subcommand" {
  complete_with __pass_env pass env ""
  [[ "${COMPREPLY[*]}" == "run set unset list version help" ]]
}

@test "pass env: filters subcommands by prefix" {
  complete_with __pass_env pass env "s"
  [[ "${COMPREPLY[*]}" == "set" ]]
}

@test "pass env: an unknown subcommand falls back to the subcommand list" {
  complete_with __pass_env pass env nosuch ""
  [[ "${COMPREPLY[*]}" == "run set unset list version help" ]]
}

@test "pass env: list takes no further arguments" {
  complete_with __pass_env pass env list ""
  [[ "${#COMPREPLY[@]}" -eq 0 ]]
}

# pass env run: flags, entries and delegation past the double dash

@test "pass env run: offers flags and entries before the double dash" {
  complete_with __pass_env pass env run ""
  [[ "${COMPREPLY[*]}" =~ "--no-expand" ]]
  [[ "${COMPREPLY[*]}" =~ "myentry.env" ]]
}

@test "pass env run: delegates to the command after the double dash" {
  complete_with __pass_env pass env run myentry.env -- somecmd ""
  [[ "${#COMMAND_OFFSET_CALLS[@]}" -eq 1 ]]
}

# Entry completion against the store

@test "pass env set: completes entries from the store" {
  complete_with __pass_env pass env set "my"
  [[ "${COMPREPLY[*]}" == "myentry.env" ]]
}

@test "pass env set: offers no entry when the prefix matches nothing" {
  complete_with __pass_env pass env set "zzzz"
  [[ "${#COMPREPLY[@]}" -eq 0 ]]
}

@test "pass env set: entry candidates keep the .env suffix and drop .gpg" {
  complete_with __pass_env pass env set "second"
  [[ "${COMPREPLY[*]}" == "second.env" ]]
}

@test "pass env set: entry completion turns off readline filename handling" {
  complete_with __pass_env pass env set "my"
  [[ "${COMPOPT_CALLS[*]}" =~ "+o filenames" ]]
}

# passenv: the shell function's own completion

@test "passenv: offers every subcommand" {
  complete_with __passenv passenv ""
  [[ "${COMPREPLY[*]}" == "set unset run list loaded version help" ]]
}

@test "passenv: filters subcommands by prefix" {
  complete_with __passenv passenv "l"
  [[ "${COMPREPLY[*]}" == "list loaded" ]]
}

@test "passenv set: completes entries from the store" {
  complete_with __passenv passenv set "my"
  [[ "${COMPREPLY[*]}" == "myentry.env" ]]
}

@test "passenv unset: completes from the tracker when it is populated" {
  _PASSENV_TRACKER["loaded.env"]="SOME_VAR"
  complete_with __passenv passenv unset "loa"
  [[ "${COMPREPLY[*]}" == "loaded.env" ]]
}

@test "passenv unset: falls back to the store when the tracker is empty" {
  complete_with __passenv passenv unset "my"
  [[ "${COMPREPLY[*]}" == "myentry.env" ]]
}

@test "passenv run: delegates to the command after the double dash" {
  complete_with __passenv passenv run myentry.env -- somecmd ""
  [[ "${#COMMAND_OFFSET_CALLS[@]}" -eq 1 ]]
}

# Escaping of attacker-controlled candidates

# Point the completion at a store containing a hostile filename.
#
# Uses a throwaway store rather than test/fixtures/store so a failure cannot
# leave a booby-trapped filename behind for the rest of the suite.
#
# Arguments:
#   $1 - Filename to create, without the .gpg suffix
setup_hostile_store() {
  export PASSWORD_STORE_DIR="$BATS_TEST_TMPDIR/hostile-store"
  mkdir -p "$PASSWORD_STORE_DIR"
  touch "$PASSWORD_STORE_DIR/$1.gpg"
}

@test "pass env set: a command substitution in a filename is escaped" {
  setup_hostile_store 'zz$(id).env'
  complete_with __pass_env pass env set "zz"
  [[ "${#COMPREPLY[@]}" -eq 1 ]]
  [[ "${COMPREPLY[0]}" == 'zz\$\(id\).env' ]]
}

@test "pass env set: a backtick in a filename is escaped" {
  setup_hostile_store 'bt`id`.env'
  complete_with __pass_env pass env set "bt"
  [[ "${COMPREPLY[0]}" != 'bt`id`.env' ]]
  [[ "${COMPREPLY[0]}" == *'\`'* ]]
}

@test "pass env set: a semicolon in a filename is escaped" {
  setup_hostile_store 'semi;touch pwn.env'
  complete_with __pass_env pass env set "semi"
  [[ "${COMPREPLY[0]}" == *'\;'* ]]
}

@test "pass env set: a space in a filename stays one candidate" {
  setup_hostile_store 'sp ace.env'
  complete_with __pass_env pass env set "sp"
  [[ "${#COMPREPLY[@]}" -eq 1 ]]
  [[ "${COMPREPLY[0]}" == 'sp\ ace.env' ]]
}

@test "pass env set: an ordinary nested path is left unchanged" {
  export PASSWORD_STORE_DIR="$BATS_TEST_TMPDIR/plain-store"
  mkdir -p "$PASSWORD_STORE_DIR/github"
  touch "$PASSWORD_STORE_DIR/github/pat.env.gpg"
  complete_with __pass_env pass env set "git"
  [[ "${COMPREPLY[0]}" == "github/pat.env" ]]
}

@test "passenv unset: a hostile tracker key is escaped" {
  _PASSENV_TRACKER['tk$(id).env']="SOME_VAR"
  complete_with __passenv passenv unset "tk"
  [[ "${COMPREPLY[0]}" == 'tk\$\(id\).env' ]]
}
