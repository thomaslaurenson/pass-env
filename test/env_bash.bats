#!/usr/bin/env bats

# Tests for src/env.bash
#
# Uses a mock 'pass' command (test/helpers/mock_pass) to avoid requiring a
# real password store. Fixtures live in test/fixtures/content/. Dummy .gpg
# files in test/fixtures/store/ satisfy the _resolve_entry existence check.

bats_require_minimum_version 1.7.0

# Configure the test environment before each test.
#
# Sets REPO_ROOT and ENV_BASH, and exports the path variables required
# by env.bash and the mock pass command.
#
# Globals:
#   BATS_TEST_DIRNAME - provided by bats
#   PASSWORD_STORE_DIR, PASS_CMD, PASSENV_FIXTURE_CONTENT_DIR - exported
#   ENV_BASH - set
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"
  export PASS_CMD="$REPO_ROOT/test/helpers/mock_pass"
  export PASSENV_FIXTURE_CONTENT_DIR="$REPO_ROOT/test/fixtures/content"
  ENV_BASH="$REPO_ROOT/src/env.bash"
}

# Dispatcher

@test "help: exits 0 and prints usage" {
  run bash "$ENV_BASH" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pass env" ]]
}

@test "unknown subcommand: exits non-zero" {
  run bash "$ENV_BASH" badcmd
  [ "$status" -ne 0 ]
}

# list — store entry listing

@test "list: exits 0" {
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
}

@test "list: prints .env entries found in the fixture store" {
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
  [[ "$output" =~ "second.env" ]]
  [[ "$output" =~ "withcomments.env" ]]
}

@test "list: strips the .gpg suffix from entry names" {
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ ".gpg" ]]
}

@test "list: output is sorted alphabetically" {
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  sorted="$(printf '%s\n' "$output" | sort)"
  [[ "$output" == "$sorted" ]]
}

# .env suffix enforcement

@test "set: rejects entry that does not end in .env" {
  run bash "$ENV_BASH" set myentry
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must end in .env" ]]
}

@test "unset: rejects entry that does not end in .env" {
  run bash "$ENV_BASH" unset myentry
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must end in .env" ]]
}

@test "run: rejects entry that does not end in .env" {
  run bash "$ENV_BASH" run myentry -- true
  [ "$status" -ne 0 ]
  [[ "$output" =~ "must end in .env" ]]
}

# path traversal prevention

@test "set: rejects entry with directory traversal (..)" {
  run bash "$ENV_BASH" set ../../etc/passwd.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no traversal allowed" ]]
}

@test "set: rejects entry with absolute path" {
  run bash "$ENV_BASH" set /absolute/path.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no traversal allowed" ]]
}

@test "unset: rejects entry with directory traversal (..)" {
  run bash "$ENV_BASH" unset ../sibling.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no traversal allowed" ]]
}

# set — output format and eval round-trip

@test "set: emits export lines for a valid entry" {
  run bash "$ENV_BASH" set myentry.env
  [ "$status" -eq 0 ]
  [[ "$output" =~ "export MY_VAR=" ]]
  [[ "$output" =~ "export MY_OTHER=" ]]
}

@test "set: skips blank lines and comment lines" {
  run bash "$ENV_BASH" set withcomments.env
  [ "$status" -eq 0 ]
  [[ "$output" =~ "export REAL_VAR=" ]]
  [[ "$output" =~ "export ANOTHER_VAR=" ]]
  ! [[ "$output" =~ "COMMENT" ]]
}

@test "set: shell-quotes values with special characters" {
  run bash "$ENV_BASH" set specialchars.env
  [ "$status" -eq 0 ]
  eval "$output"
  [[ "$SPECIAL_VAR" == "hello world" ]]
  [[ "$QUOTE_VAR" == "it's a test" ]]
}

@test "set: rejects an entry that contains an invalid variable name" {
  run bash "$ENV_BASH" set badkeys.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid variable name" ]]
}

@test "set: output can be eval'd to set variables in the current shell" {
  eval "$(bash "$ENV_BASH" set myentry.env)"
  [[ "$MY_VAR" == "myvalue" ]]
  [[ "$MY_OTHER" == "othervalue" ]]
}

# unset — output format and eval round-trip

@test "unset: emits an unset statement listing all key names" {
  run bash "$ENV_BASH" unset myentry.env
  [ "$status" -eq 0 ]
  [[ "$output" =~ "unset" ]]
  [[ "$output" =~ "MY_VAR" ]]
  [[ "$output" =~ "MY_OTHER" ]]
}

@test "unset: output can be eval'd to remove previously exported variables" {
  eval "$(bash "$ENV_BASH" set myentry.env)"
  [[ "$MY_VAR" == "myvalue" ]]
  eval "$(bash "$ENV_BASH" unset myentry.env)"
  [[ -z "${MY_VAR:-}" ]]
}

# run — subprocess injection and isolation

@test "run: injects entry vars into the subprocess" {
  run bash "$ENV_BASH" run myentry.env -- printenv MY_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue" ]]
}

@test "run: variables do not leak into the calling shell" {
  bash "$ENV_BASH" run myentry.env -- true
  [[ -z "${MY_VAR:-}" ]]
}

@test "run: multiple entries are each visible inside the subprocess" {
  run bash "$ENV_BASH" run myentry.env second.env -- bash -c 'printf "%s %s" "$MY_VAR" "$SECOND_VAR"'
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue secondvalue" ]]
}

@test "run: preserves the exit status of the subprocess" {
  run bash "$ENV_BASH" run myentry.env -- bash -c 'exit 42'
  [ "$status" -eq 42 ]
}

# CRLF handling

@test "set: strips trailing CR from values in CRLF-encoded entries" {
  eval "$(bash "$ENV_BASH" set crlf.env)"
  # Value must equal the clean string with no embedded carriage return
  [[ "$CRLF_VAR" == "testvalue" ]]
  [[ "${#CRLF_VAR}" -eq 9 ]]
}

# Error message safety

@test "set: error for unsupported line format does not include the secret value" {
  run bash "$ENV_BASH" set badformat.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unsupported line format" ]]
  ! [[ "$output" =~ "supersecret123" ]]
}
