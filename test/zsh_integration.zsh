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

# Put mock_pass on PATH as 'pass' — same pattern as bats setup().
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

printf 'ok\n'
