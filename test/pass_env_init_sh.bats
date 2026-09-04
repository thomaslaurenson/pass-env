#!/usr/bin/env bats

# Tests for contrib/pass-env-init.sh
#
# The mock 'pass' binary placed on PATH mocks 'pass show' and delegates every
# 'pass env ...' call to the real src/env.bash.
# Each @test block runs in its own process; setup() sources pass-env-init.sh
# fresh with an empty _PASSENV_TRACKER.

bats_require_minimum_version 1.7.0

# Configure the test environment before each test.
#
# Places mock_pass on PATH as 'pass', exports store path variables, and
# sources pass-env-init.sh so the passenv shell function is available.
#
# Globals:
#   BATS_TEST_DIRNAME, BATS_TEST_TMPDIR - provided by bats
#   PASSWORD_STORE_DIR, PASSENV_FIXTURE_CONTENT_DIR, PATH - exported
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"
  export PASSENV_FIXTURE_CONTENT_DIR="$REPO_ROOT/test/fixtures/content"
  # mock_pass delegates 'pass env ...' to the real extension; tell it where.
  export PASS_ENV_SRC="$REPO_ROOT/src/env.bash"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -sf "$REPO_ROOT/test/helpers/mock_pass" "$BATS_TEST_TMPDIR/bin/pass"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Source after PATH is configured so pass is resolvable immediately.
  source "$REPO_ROOT/contrib/pass-env-init.sh"
}

# passenv set: loading entries into the shell

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

# passenv unset: removing entries from the shell

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

@test "set: rolls back previously loaded entries when a later entry fails" {
  # myentry.env loads fine; nonexistent.env has no fixture so mock_pass exits 1
  passenv set "myentry.env" "nonexistent.env" 2>/dev/null || true
  [[ -z "${MY_VAR:-}" ]]
  [[ -z "${_PASSENV_TRACKER[myentry.env]:-}" ]]
}

@test "unset: prints a message and returns 0 when no entries are loaded" {
  run passenv unset
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no entries" ]]
}

# passenv run: subprocess injection and isolation

@test "run: injects entry vars into the subprocess" {
  run passenv run "myentry.env" -- printenv MY_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue" ]]
}

@test "run: vars do not leak into the calling shell" {
  passenv run "myentry.env" -- true
  [[ -z "${MY_VAR:-}" ]]
}

@test "run: multiple entries are each visible inside the subprocess" {
  run passenv run "myentry.env" "second.env" -- bash -c 'printf "%s %s" "$MY_VAR" "$SECOND_VAR"'
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue secondvalue" ]]
}

@test "run: preserves the exit status of the subprocess" {
  run passenv run "myentry.env" -- bash -c 'exit 42'
  [ "$status" -eq 42 ]
}

# passenv list: store entry listing

@test "list: exits 0 and lists available store entries" {
  run passenv list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
  [[ "$output" =~ "second.env" ]]
}

@test "list: strips the .gpg suffix from entry names" {
  run passenv list
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ ".gpg" ]]
}

# passenv loaded: tracker state display

@test "loaded: shows all currently loaded entries" {
  passenv set "myentry.env" "second.env"
  run passenv loaded
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
  [[ "$output" =~ "second.env" ]]
}

@test "loaded: includes variable names for each loaded entry" {
  passenv set "myentry.env"
  run passenv loaded
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MY_VAR" ]]
}

@test "loaded: reports that no entries are loaded when tracker is empty" {
  run passenv loaded
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no entries" ]]
}

# Loader guard: re-sourcing does not clear the tracker

@test "re-sourcing the loader does not reset a populated tracker" {
  passenv set "myentry.env"
  source "$REPO_ROOT/contrib/pass-env-init.sh"
  [[ -n "${_PASSENV_TRACKER[myentry.env]:-}" ]]
}

# Restore semantics: unset returns variables to their pre-load state

@test "unset: restores the previous value of a variable that existed before set" {
  export MY_VAR="original_value"
  passenv set "myentry.env"
  [[ "$MY_VAR" == "myvalue" ]]
  passenv unset "myentry.env"
  [[ "$MY_VAR" == "original_value" ]]
}

@test "unset: removes a variable that did not exist before set" {
  unset MY_VAR 2>/dev/null || true
  passenv set "myentry.env"
  [[ "$MY_VAR" == "myvalue" ]]
  passenv unset "myentry.env"
  [[ -z "${MY_VAR+x}" ]]
}

@test "unset: restores special-character values verbatim" {
  export MY_VAR='prev !d+f$bn value'
  passenv set "myentry.env"
  passenv unset "myentry.env"
  [[ "$MY_VAR" == 'prev !d+f$bn value' ]]
}

@test "set: rollback restores previous values, not just unset" {
  export MY_VAR="original_value"
  passenv set "myentry.env" "nonexistent.env" 2>/dev/null || true
  [[ "$MY_VAR" == "original_value" ]]
  [[ -z "${_PASSENV_TRACKER[myentry.env]:-}" ]]
}

# Entry marker: tracker keys use real entry names

@test "set: tracker key comes from the entry marker in pass env set output" {
  passenv set "myentry.env"
  run passenv loaded
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
  ! [[ "$output" =~ "__passenv_" ]]
}

# passenv run: assignment prefix in the command

@test "run: honors a leading VAR=value assignment before the command" {
  run passenv run "myentry.env" -- FROMCMD=fromcmd printenv FROMCMD
  [ "$status" -eq 0 ]
  [[ "$output" == "fromcmd" ]]
}

@test "run: substitutes a {{VAR}} placeholder from the entry" {
  run passenv run "myentry.env" -- printf '%s' '{{MY_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue" ]]
}

@test "run: --no-expand leaves placeholders literal" {
  run passenv run --no-expand "myentry.env" -- printf '%s' '{{MY_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == '{{MY_VAR}}' ]]
}

# Reserved namespace and marker validation

# Replace the mock pass with one emitting pre-canned 'pass env set' output.
#
# The current extension refuses to emit the lines these tests need, so the
# skew cases cannot be driven through it. The loader and the extension install
# as separate files and can be upgraded independently, which is the state
# being reproduced here.
#
# Arguments:
#   $1 - Exact stdout the fake 'pass env set' should produce
# Globals:
#   BATS_TEST_TMPDIR - provided by bats; holds the fake binary and its payload
_passenv_fake_pass_output() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/fake_output"
  # setup() left a symlink here pointing at test/helpers/mock_pass. Remove it
  # first: redirecting onto a symlink writes through it and would overwrite the
  # tracked helper in the repository.
  rm -f "$BATS_TEST_TMPDIR/bin/pass"
  cat > "$BATS_TEST_TMPDIR/bin/pass" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "env" ]] || exit 1
cat "$BATS_TEST_TMPDIR/fake_output"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/pass"
}

@test "set: an entry key of 'current' does not move the tracker key" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/rebind_current.env"
  printf 'current=hijacked.env\nREAL_VAR=realvalue\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/rebind_current.env.gpg"
  passenv set "rebind_current.env"
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/rebind_current.env.gpg"
  [[ -n "${_PASSENV_TRACKER[rebind_current.env]:-}" ]]
  [[ -z "${_PASSENV_TRACKER[hijacked.env]:-}" ]]
  [[ "$REAL_VAR" == "realvalue" ]]
}

@test "set: drops a reserved _passenv_ key from skewed extension output" {
  _passenv_fake_pass_output "# pass-env entry: skew.env
export _passenv_current=hijacked.env
export SKEW_VAR=skewvalue"
  passenv set "skew.env"
  [[ "$SKEW_VAR" == "skewvalue" ]]
  [[ -n "${_PASSENV_TRACKER[skew.env]:-}" ]]
  [[ -z "${_PASSENV_TRACKER[hijacked.env]:-}" ]]
}

@test "set: refuses an unsafe entry name in skewed extension output" {
  _passenv_fake_pass_output "# pass-env entry: evil\$(touch ${BATS_TEST_TMPDIR}/PWNED).env
export SKEW_VAR=skewvalue"
  run passenv set "skew.env"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "refusing unsafe entry name" ]]
  [[ ! -e "$BATS_TEST_TMPDIR/PWNED" ]]
}

# Shell detection

@test "snapshot: restores the real value when BASH_VERSION is cleared" {
  export PRESET_VAR=presetvalue
  local saved="$BASH_VERSION"
  BASH_VERSION=""
  run _passenv_snapshot_stmt PRESET_VAR
  BASH_VERSION="$saved"
  [ "$status" -eq 0 ]
  [[ "$output" == "export PRESET_VAR=presetvalue" ]]
}

@test "snapshot: still records an unset for a variable that is genuinely absent" {
  unset ABSENT_VAR 2>/dev/null || true
  run _passenv_snapshot_stmt ABSENT_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == "unset ABSENT_VAR" ]]
}

# Shared variables across entries

@test "unset: a variable another entry still provides is left alone" {
  local shared="$PASSENV_FIXTURE_CONTENT_DIR/shared_a.env"
  local shared_b="$PASSENV_FIXTURE_CONTENT_DIR/shared_b.env"
  printf 'SHARED_VAR=from_a\n' > "$shared"
  printf 'SHARED_VAR=from_b\n' > "$shared_b"
  touch "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  unset SHARED_VAR 2>/dev/null || true
  passenv set "shared_a.env" "shared_b.env"
  passenv unset "shared_a.env"
  local after_first="${SHARED_VAR:-<unset>}"
  passenv unset "shared_b.env"
  local after_second="${SHARED_VAR+set}"
  rm -f "$shared" "$shared_b" \
    "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  [[ "$after_first" == "from_b" ]]
  [[ -z "$after_second" ]]
}

@test "unset: a shared variable does not resurrect after every entry is unset" {
  local shared="$PASSENV_FIXTURE_CONTENT_DIR/shared_a.env"
  local shared_b="$PASSENV_FIXTURE_CONTENT_DIR/shared_b.env"
  printf 'SHARED_VAR=from_a\n' > "$shared"
  printf 'SHARED_VAR=from_b\n' > "$shared_b"
  touch "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  export SHARED_VAR=original
  passenv set "shared_a.env" "shared_b.env"
  passenv unset "shared_a.env"
  passenv unset "shared_b.env"
  rm -f "$shared" "$shared_b" \
    "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  [[ "$SHARED_VAR" == "original" ]]
}

@test "unset: the original value is restored whichever order entries are unset" {
  local shared="$PASSENV_FIXTURE_CONTENT_DIR/shared_a.env"
  local shared_b="$PASSENV_FIXTURE_CONTENT_DIR/shared_b.env"
  printf 'SHARED_VAR=from_a\n' > "$shared"
  printf 'SHARED_VAR=from_b\n' > "$shared_b"
  touch "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  export SHARED_VAR=original
  passenv set "shared_a.env" "shared_b.env"
  passenv unset "shared_b.env"
  passenv unset "shared_a.env"
  rm -f "$shared" "$shared_b" \
    "$PASSWORD_STORE_DIR/shared_a.env.gpg" "$PASSWORD_STORE_DIR/shared_b.env.gpg"
  [[ "$SHARED_VAR" == "original" ]]
}
