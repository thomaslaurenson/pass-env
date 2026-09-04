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
  # The status is discarded on purpose. __pass_env_complete_entries ends on a
  # failed prefix match whenever the last store entry does not match the token,
  # so it returns non-zero despite documenting "Returns: 0 always". bash ignores
  # a completion function's status, and COMPREPLY is the contract under test.
  "$fn" || true
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
