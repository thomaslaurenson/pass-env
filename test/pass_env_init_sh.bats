#!/usr/bin/env bats

# Tests for contrib/pass-env-init.sh
#
# The mock 'pass' binary placed on PATH handles 'pass env set ENTRY' calls.
# Each @test block runs in its own process; setup() sources pass-env-init.sh
# fresh with an empty _PASSENV_TRACKER.

bats_require_minimum_version 1.7.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"
  export PASSENV_FIXTURE_CONTENT_DIR="$REPO_ROOT/test/fixtures/content"

  # Place mock_pass on PATH as 'pass' so pass-env-init.sh's 'pass env set' works.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -sf "$REPO_ROOT/test/helpers/mock_pass" "$BATS_TEST_TMPDIR/bin/pass"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Source after PATH is configured so pass is resolvable immediately.
  source "$REPO_ROOT/contrib/pass-env-init.sh"
}

# ---------------------------------------------------------------------------
# passenv set — loading entries into the shell
# ---------------------------------------------------------------------------

@test "set: exports the entry's variables into the current shell" {
  passenv set "myentry.env"
  [[ "$MY_VAR" == "myvalue" ]]
  [[ "$MY_OTHER" == "othervalue" ]]
}

@test "set: records the entry and its var names in the tracker" {
  passenv set "myentry.env"
  [[ "${_PASSENV_TRACKER[myentry.env]:-}" =~ "MY_VAR" ]]
}

@test "set: loading the same entry twice does not duplicate tracked vars" {
  passenv set "myentry.env"
  passenv set "myentry.env"
  count=$(printf '%s\n' "${_PASSENV_TRACKER[myentry.env]}" | tr ' ' '\n' | grep -c '^MY_VAR$')
  [[ "$count" -eq 1 ]]
}

@test "set: accepts multiple entries in one call" {
  passenv set "myentry.env" "second.env"
  [[ "$MY_VAR" == "myvalue" ]]
  [[ "$SECOND_VAR" == "secondvalue" ]]
  [[ -n "${_PASSENV_TRACKER[myentry.env]:-}" ]]
  [[ -n "${_PASSENV_TRACKER[second.env]:-}" ]]
}

# ---------------------------------------------------------------------------
# passenv unset — removing entries from the shell
# ---------------------------------------------------------------------------

@test "unset: removes the entry's variables from the shell" {
  passenv set "myentry.env"
  passenv unset "myentry.env"
  [[ -z "${MY_VAR:-}" ]]
}

@test "unset: removes the entry from the tracker" {
  passenv set "myentry.env"
  passenv unset "myentry.env"
  [[ -z "${_PASSENV_TRACKER[myentry.env]:-}" ]]
}

@test "unset: does not affect other loaded entries" {
  passenv set "myentry.env" "second.env"
  passenv unset "myentry.env"
  [[ -z "${MY_VAR:-}" ]]
  [[ "$SECOND_VAR" == "secondvalue" ]]
  [[ -n "${_PASSENV_TRACKER[second.env]:-}" ]]
}

@test "unset: prints a message and returns 0 when no entries are loaded" {
  run passenv unset
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no entries" ]]
}

# ---------------------------------------------------------------------------
# passenv list
# ---------------------------------------------------------------------------

@test "list: shows all currently loaded entries" {
  passenv set "myentry.env" "second.env"
  run passenv list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
  [[ "$output" =~ "second.env" ]]
}

@test "list: reports that no entries are loaded when tracker is empty" {
  run passenv list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no entries" ]]
}

# ---------------------------------------------------------------------------
# passenv print — value display and sensitive-value masking
# ---------------------------------------------------------------------------

@test "print: shows the value of a non-sensitive variable" {
  passenv set "myentry.env"
  run passenv print
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myvalue" ]]
}

@test "print: masks a variable whose name contains PASSWORD" {
  export MY_PASSWORD=supersecret
  _PASSENV_TRACKER["myentry.env"]="MY_PASSWORD"
  run passenv print
  [[ "$output" =~ "MY_PASSWORD=******" ]]
  ! [[ "$output" =~ "supersecret" ]]
}

@test "print: masks a variable whose name contains SECRET" {
  export API_SECRET=topsecret
  _PASSENV_TRACKER["myentry.env"]="API_SECRET"
  run passenv print
  [[ "$output" =~ "API_SECRET=******" ]]
  ! [[ "$output" =~ "topsecret" ]]
}

@test "print: masks a variable whose name contains TOKEN" {
  export GITHUB_TOKEN=ghp_abc123
  _PASSENV_TRACKER["myentry.env"]="GITHUB_TOKEN"
  run passenv print
  [[ "$output" =~ "GITHUB_TOKEN=******" ]]
  ! [[ "$output" =~ "ghp_abc123" ]]
}

@test "print: does not mask PASSPORT_NUM (PASS not at a word boundary)" {
  export PASSPORT_NUM=AB1234
  _PASSENV_TRACKER["myentry.env"]="PASSPORT_NUM"
  run passenv print
  [[ "$output" =~ "AB1234" ]]
}

@test "print: reports that no entries are loaded when tracker is empty" {
  run passenv print
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no entries" ]]
}

# ---------------------------------------------------------------------------
# Loader guard — re-sourcing does not clear the tracker
# ---------------------------------------------------------------------------

@test "re-sourcing the loader does not reset a populated tracker" {
  passenv set "myentry.env"
  source "$REPO_ROOT/contrib/pass-env-init.sh"
  [[ -n "${_PASSENV_TRACKER[myentry.env]:-}" ]]
}

