#!/usr/bin/env bats

# Tests for contrib/pass-env-uninstall.sh
#
# The script is sourced inside a fresh bash so its functions can be called
# directly with the install directories pointed at a temporary tree. A mock
# sudo on PATH records every invocation instead of escalating, so the tests
# observe whether the uninstaller would have asked for root for a given path.

bats_require_minimum_version 1.7.0

# Configure the test environment before each test.
#
# Globals:
#   REPO_ROOT  - absolute path to the repository root
#   SCRIPT     - path to the uninstaller under test
#   SUDO_LOG   - file the mock sudo appends its arguments to
#   LOCKED_DIR - directory made non-writable so removal needs escalation
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/contrib/pass-env-uninstall.sh"
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  LOCKED_DIR="$BATS_TEST_TMPDIR/locked"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SUDO_LOG"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sudo"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  mkdir -p "$LOCKED_DIR"
  : > "$LOCKED_DIR/victim"
  chmod 0555 "$LOCKED_DIR"
}

teardown() {
  chmod 0755 "$LOCKED_DIR" 2>/dev/null || true
}

# Source the uninstaller and run one of its functions in a fresh bash.
#
# Arguments:
#   $1 - Shell snippet to run after sourcing; the install directory globals
#        are set to $BATS_TEST_TMPDIR/sys/* before it runs
_uninstall_call() {
  bash -c '
    source "$1"
    EXTENSION_DIR="$2/sys/ext"
    MAN_DIR="$2/sys/man"
    BASH_COMP_DIR="$2/sys/bash"
    ZSH_COMP_DIR="$2/sys/zsh"
    INIT_SCRIPT_DIR="$2/sys/init"
    eval "$3"
  ' _ "$SCRIPT" "$BATS_TEST_TMPDIR" "$1"
}

# Manifest-driven removal and sudo policy

@test "manifest: a user manifest never removes a path with sudo" {
  [[ "$EUID" -ne 0 ]] || skip "root can write anywhere, so the -w check never fails"
  local manifest="$BATS_TEST_TMPDIR/user-manifest.txt"
  printf '%s\n' "$LOCKED_DIR/victim" > "$manifest"
  run _uninstall_call "remove_from_manifest '$manifest' user"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "KEPT" ]]
  [ -e "$LOCKED_DIR/victim" ]
  [ ! -e "$SUDO_LOG" ]
}

@test "manifest: a system manifest does not escalate for a path outside the install dirs" {
  [[ "$EUID" -ne 0 ]] || skip "root can write anywhere, so the -w check never fails"
  local manifest="$BATS_TEST_TMPDIR/system-manifest.txt"
  printf '%s\n' "$LOCKED_DIR/victim" > "$manifest"
  run _uninstall_call "remove_from_manifest '$manifest' system"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "KEPT" ]]
  [ -e "$LOCKED_DIR/victim" ]
  [ ! -e "$SUDO_LOG" ]
}

@test "manifest: a system manifest escalates for a path inside an install dir" {
  [[ "$EUID" -ne 0 ]] || skip "root can write anywhere, so the -w check never fails"
  # Put the locked directory where the init script dir is expected.
  mkdir -p "$BATS_TEST_TMPDIR/sys"
  chmod 0755 "$LOCKED_DIR"
  mv "$LOCKED_DIR" "$BATS_TEST_TMPDIR/sys/init"
  LOCKED_DIR="$BATS_TEST_TMPDIR/sys/init"
  chmod 0555 "$LOCKED_DIR"
  local manifest="$BATS_TEST_TMPDIR/system-manifest.txt"
  printf '%s\n' "$LOCKED_DIR/victim" > "$manifest"
  run _uninstall_call "remove_from_manifest '$manifest' system"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "REMOVED" ]]
  [ -e "$SUDO_LOG" ]
  grep -qF "rm -f $LOCKED_DIR/victim" "$SUDO_LOG"
}

@test "manifest: relative and blank lines are ignored" {
  local manifest="$BATS_TEST_TMPDIR/odd-manifest.txt"
  : > "$BATS_TEST_TMPDIR/relative-victim"
  printf '\nrelative-victim\n' > "$manifest"
  run _uninstall_call "cd '$BATS_TEST_TMPDIR' && remove_from_manifest '$manifest' user"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/relative-victim" ]
  [ ! -e "$manifest" ]
}

# RC file block removal

@test "rc: stripping the block keeps a symlinked rc file as a symlink" {
  local target="$BATS_TEST_TMPDIR/dotfiles_bashrc"
  local link="$BATS_TEST_TMPDIR/.bashrc"
  printf 'keep\n# pass-env-init BEGIN\nsource x\n# pass-env-init END\nkeep2\n' > "$target"
  ln -s "$target" "$link"
  run _uninstall_call "strip_rc_block '$link'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "REMOVED" ]]
  [ -L "$link" ]
  ! grep -q 'pass-env-init' "$target"
  grep -q '^keep$' "$target"
  grep -q '^keep2$' "$target"
}

@test "rc: a file without the block is left untouched" {
  local rc="$BATS_TEST_TMPDIR/.zshrc"
  printf 'keep\n' > "$rc"
  run _uninstall_call "strip_rc_block '$rc'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not installed" ]]
  [[ "$(cat "$rc")" == "keep" ]]
}

# Home directory lookup

@test "home: a username that is not a plain account name is rejected" {
  run _uninstall_call "user_home 'me\$(touch $BATS_TEST_TMPDIR/PWNED)'"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "home: the current user's home directory is found" {
  run _uninstall_call "user_home '$(id -un)'"
  [ "$status" -eq 0 ]
  [[ "$output" == "$HOME" ]]
}
