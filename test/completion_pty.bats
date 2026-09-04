#!/usr/bin/env bats

# Terminal-level tests for completion/pass-env.bash.completion
#
# test/completion_bash.bats asserts what the completion functions put into
# COMPREPLY. It cannot assert what readline then inserts onto the command line,
# and that is where the escaping actually matters: a candidate can be generated
# perfectly safely and still execute when the user presses Enter. Seeing that
# requires a real terminal, so these tests drive an interactive bash through a
# pty (test/helpers/pty_complete.py).
#
# They skip rather than fail where the environment cannot support them, since a
# missing bash-completion says nothing about this project's correctness.

bats_require_minimum_version 1.7.0

# Configure the test environment before each test.
#
# Globals:
#   BATS_TEST_DIRNAME, BATS_TEST_TMPDIR - provided by bats
#   REPO_ROOT, PTY_DRIVER, BC_SCRIPT, STORE_DIR, WORK_DIR, RC_FILE - set
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PTY_DRIVER="$REPO_ROOT/test/helpers/pty_complete.py"

  command -v python3 &>/dev/null || skip "python3 is required to drive a pty"

  BC_SCRIPT=""
  local candidate
  for candidate in \
    /usr/share/bash-completion/bash_completion \
    /etc/bash_completion \
    /usr/local/etc/profile.d/bash_completion.sh \
    /opt/homebrew/etc/profile.d/bash_completion.sh
  do
    [[ -r "$candidate" ]] && { BC_SCRIPT="$candidate"; break; }
  done
  [[ -n "$BC_SCRIPT" ]] || skip "bash-completion is not installed"

  STORE_DIR="$BATS_TEST_TMPDIR/store"
  WORK_DIR="$BATS_TEST_TMPDIR/cwd"
  RC_FILE="$BATS_TEST_TMPDIR/rc"
  mkdir -p "$STORE_DIR" "$WORK_DIR"
}

# Write the rcfile the spawned bash will read.
#
# The payload in a hostile entry name has to be slash-free, since a filename
# cannot contain one, so it writes relative to WORK_DIR and the shell is placed
# there. passenv is stubbed to a no-op: the point is what the shell does with
# the completed line, not what passenv would then do with it.
write_rcfile() {
  cat > "$RC_FILE" <<EOF
PS1='RDY> '
source ${BC_SCRIPT}
export PASSWORD_STORE_DIR="${STORE_DIR}"
cd "${WORK_DIR}"
source ${REPO_ROOT}/completion/pass-env.bash.completion
complete -F __passenv passenv
passenv() { :; }
EOF
}

@test "pty: a command substitution in a store filename is inserted escaped" {
  touch "${STORE_DIR}/zz\$(touch PWNED).env.gpg"
  write_rcfile
  run python3 "$PTY_DRIVER" "$RC_FILE" "passenv set zz"
  [ "$status" -eq 0 ]
  [[ "$output" == *'zz\$\(touch\ PWNED\).env'* ]]
  [[ ! -e "${WORK_DIR}/PWNED" ]]
}

@test "pty: a backtick in a store filename is inserted escaped" {
  touch "${STORE_DIR}/bt\`touch PWNED_BT\`.env.gpg"
  write_rcfile
  run python3 "$PTY_DRIVER" "$RC_FILE" "passenv set bt"
  [ "$status" -eq 0 ]
  [[ ! -e "${WORK_DIR}/PWNED_BT" ]]
}

@test "pty: an ordinary entry name completes unchanged" {
  touch "${STORE_DIR}/myentry.env.gpg"
  write_rcfile
  run python3 "$PTY_DRIVER" "$RC_FILE" "passenv set myent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"passenv set myentry.env"* ]]
}
