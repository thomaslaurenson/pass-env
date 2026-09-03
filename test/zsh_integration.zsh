#!/usr/bin/env zsh
# zsh integration test for contrib/pass-env-init.sh
#
# Exercises the zsh-specific _passenv_keys branch by populating
# _PASSENV_TRACKER and verifying passenv loaded output.
#
# Must be run from the repository root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"
export PASSENV_FIXTURE_CONTENT_DIR="$REPO_ROOT/test/fixtures/content"
# mock_pass delegates 'pass env ...' to the real extension; tell it where.
export PASS_ENV_SRC="$REPO_ROOT/src/env.bash"

# Put mock_pass on PATH as 'pass', same pattern as bats setup().
tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin"' EXIT INT TERM
ln -sf "$REPO_ROOT/test/helpers/mock_pass" "$tmpbin/pass"
export PATH="$tmpbin:$PATH"

source "$REPO_ROOT/contrib/pass-env-init.sh"

# Test 1: passenv set populates the tracker.
passenv set "myentry.env" >/dev/null
if [[ -z "${_PASSENV_TRACKER[myentry.env]:-}" ]]; then
  printf 'FAIL: myentry.env not in tracker after passenv set\n' >&2
  exit 1
fi

# Test 2: passenv loaded calls _passenv_keys (the zsh-specific branch)
# and produces correct output.
output="$(passenv loaded)"
if [[ "$output" != *"myentry.env"* ]]; then
  printf 'FAIL: passenv loaded did not include myentry.env\n' >&2
  exit 1
fi
if [[ "$output" != *"MY_VAR"* ]]; then
  printf 'FAIL: passenv loaded did not include MY_VAR\n' >&2
  exit 1
fi

# Test 3: passenv unset removes the entry from the tracker.
passenv unset "myentry.env" >/dev/null
if [[ -n "${_PASSENV_TRACKER[myentry.env]:-}" ]]; then
  printf 'FAIL: myentry.env still in tracker after passenv unset\n' >&2
  exit 1
fi

# Test 4: passenv unset restores a pre-existing value (zsh snapshot path).
export MY_VAR='previous !d+f$bn value'
passenv set "myentry.env" >/dev/null
if [[ "${MY_VAR}" != "myvalue" ]]; then
  printf 'FAIL: MY_VAR not overwritten by passenv set\n' >&2
  exit 1
fi
passenv unset "myentry.env" >/dev/null
if [[ "${MY_VAR}" != 'previous !d+f$bn value' ]]; then
  printf 'FAIL: MY_VAR not restored to pre-load value after unset (got: %s)\n' "${MY_VAR:-<unset>}" >&2
  exit 1
fi
unset MY_VAR

# Test 5: passenv unset removes a variable that did not exist before set.
unset MY_OTHER 2>/dev/null || true
passenv set "myentry.env" >/dev/null
if [[ -z "${MY_OTHER:-}" ]]; then
  printf 'FAIL: MY_OTHER not set by passenv set\n' >&2
  exit 1
fi
passenv unset "myentry.env" >/dev/null
if [[ -n "${MY_OTHER+x}" ]]; then
  printf 'FAIL: MY_OTHER still set after passenv unset\n' >&2
  exit 1
fi

# Test 6: entry content cannot rebind the loader local holding the tracker key.
content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/rebind_current.env"
printf 'current=hijacked.env\nREAL_VAR=realvalue\n' > "$content_fixture"
touch "$PASSWORD_STORE_DIR/rebind_current.env.gpg"
passenv set "rebind_current.env" >/dev/null
rm -f "$content_fixture" "$PASSWORD_STORE_DIR/rebind_current.env.gpg"
if [[ -z "${_PASSENV_TRACKER[rebind_current.env]:-}" ]]; then
  printf 'FAIL: rebind_current.env not tracked under its real name\n' >&2
  exit 1
fi
if [[ -n "${_PASSENV_TRACKER[hijacked.env]:-}" ]]; then
  printf 'FAIL: entry content rebound the tracker key to hijacked.env\n' >&2
  exit 1
fi
passenv unset "rebind_current.env" >/dev/null

# Test 7: a stray BASH_VERSION does not flip the loader's dialect detection.
export PRESET_VAR=presetvalue
BASH_VERSION='5.2'
stmt="$(_passenv_snapshot_stmt PRESET_VAR)"
unset BASH_VERSION
if [[ "$stmt" != 'export PRESET_VAR=presetvalue' ]]; then
  printf 'FAIL: snapshot wrong with BASH_VERSION set under zsh (got: %s)\n' "$stmt" >&2
  exit 1
fi
unset PRESET_VAR

printf 'ok\n'
