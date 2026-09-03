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
#   PASSWORD_STORE_DIR, PASSENV_FIXTURE_CONTENT_DIR, PASS_ENV_SRC - exported
#   ENV_BASH - set
setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PASSWORD_STORE_DIR="$REPO_ROOT/test/fixtures/store"
  export PASSENV_FIXTURE_CONTENT_DIR="$REPO_ROOT/test/fixtures/content"
  ENV_BASH="$REPO_ROOT/src/env.bash"
  # mock_pass delegates 'pass env ...' to the real extension; tell it where.
  export PASS_ENV_SRC="$ENV_BASH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -sf "$REPO_ROOT/test/helpers/mock_pass" "$BATS_TEST_TMPDIR/bin/pass"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
  rm -f "${PASSWORD_STORE_DIR}/evil.env.gpg"
  rm -f "${PASSWORD_STORE_DIR}/escape_list.env.gpg"
  rm -rf "${PASSWORD_STORE_DIR}/subdir"
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

# list: store entry listing

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

# entry name character validation (command-injection prevention)

@test "set: rejects entry name containing command substitution" {
  run bash "$ENV_BASH" set 'evil$(id).env'
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid characters in entry name" ]]
}

@test "run: rejects entry name containing a semicolon" {
  run bash "$ENV_BASH" run 'foo;bar.env' -- true
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid characters in entry name" ]]
}

@test "set: rejects interactive fzf selection containing command substitution" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  # The \$ is escaped so this test shell does not expand it; env.bash must
  # reject the name before anything evaluates it, so 'pwned' is never created.
  run env "PATH=$tmpbin:$PATH" \
    "MOCK_FZF_OUTPUT=evil\$(touch $BATS_TEST_TMPDIR/pwned).env" \
    bash "$ENV_BASH" set
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid characters in entry name" ]]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

# set: output format and eval round-trip

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
  [[ "$BANG_VAR" == '!d+f$bn' ]]
  [[ "$DOLLAR_VAR" == 'price$100' ]]
  [[ "$HASH_VAR" == 'color#ffffff' ]]
}

@test "run: injects entry with bang, dollar, and hash chars into subprocess" {
  run bash "$ENV_BASH" run specialchars.env -- printenv BANG_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == '!d+f$bn' ]]
}

@test "run: injects entry with dollar sign in value into subprocess" {
  run bash "$ENV_BASH" run specialchars.env -- printenv DOLLAR_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == 'price$100' ]]
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

# unset: output format and eval round-trip

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

# run: subprocess injection and isolation

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

# Symlinked store entries

@test "list: includes symlinked .env entries" {
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "symlinked.env" ]]
}

# Canonical path verification (symlink escape prevention)

@test "set: accepts symlink that resolves within the store" {
  # symlinked.env.gpg -> myentry.env.gpg (both inside the fixture store)
  run bash "$ENV_BASH" set symlinked.env
  [ "$status" -eq 0 ]
  [[ "$output" =~ "export MY_VAR=" ]]
}

@test "set: rejects symlink that escapes the store" {
  # Create a symlink inside the store that points outside to /etc/hosts
  local evil="${PASSWORD_STORE_DIR}/evil.env.gpg"
  ln -sf /etc/hosts "${evil}"
  run bash "$ENV_BASH" set evil.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "escapes password store" || "$output" =~ "symlink" ]]
  rm -f "${evil}"
}

@test "run: rejects symlink that escapes the store" {
  local evil="${PASSWORD_STORE_DIR}/evil.env.gpg"
  ln -sf /etc/hosts "${evil}"
  run bash "$ENV_BASH" run evil.env -- true
  [ "$status" -ne 0 ]
  [[ "$output" =~ "escapes password store" || "$output" =~ "symlink" ]]
  rm -f "${evil}"
}

@test "unset: rejects symlink that escapes the store" {
  local evil="${PASSWORD_STORE_DIR}/evil.env.gpg"
  ln -sf /etc/hosts "${evil}"
  run bash "$ENV_BASH" unset evil.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "escapes password store" || "$output" =~ "symlink" ]]
  rm -f "${evil}"
}

@test "set: rejects symlink via subdirectory that escapes the store" {
  # Create a subdirectory with a symlink pointing outside
  mkdir -p "${PASSWORD_STORE_DIR}/subdir"
  ln -sf /etc/hosts "${PASSWORD_STORE_DIR}/subdir/escape.env.gpg"
  run bash "$ENV_BASH" set subdir/escape.env
  [ "$status" -ne 0 ]
  [[ "$output" =~ "escapes password store" || "$output" =~ "symlink" ]]
  rm -rf "${PASSWORD_STORE_DIR}/subdir"
}

# list_entries: symlink filtering

@test "list: excludes symlinks that escape the store" {
  # Create a symlink inside the store that points outside
  local evil="${PASSWORD_STORE_DIR}/escape_list.env.gpg"
  ln -sf /etc/hosts "${evil}"
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  # The escaping symlink should NOT appear in the listing
  ! [[ "$output" =~ "escape_list.env" ]]
  rm -f "${evil}"
}

@test "list: still includes valid symlinks within the store" {
  # symlinked.env.gpg -> myentry.env.gpg (both inside the fixture store)
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "symlinked.env" ]]
}

@test "list: excludes dangling symlinks" {
  # Create a dangling symlink (target doesn't exist)
  local dangling="${PASSWORD_STORE_DIR}/dangling.env.gpg"
  ln -sf /nonexistent/path/file.env "${dangling}"
  run bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ "dangling.env" ]]
  rm -f "${dangling}"
}

# IFS-safe unset output

@test "unset: output is correct regardless of IFS value" {
  local result
  result="$(IFS=':' bash "$ENV_BASH" unset myentry.env)"
  [[ "$result" =~ "unset" ]]
  [[ "$result" =~ "MY_VAR" ]]
  [[ "$result" =~ "MY_OTHER" ]]
  # No IFS character should appear between the key names
  ! [[ "$result" =~ "MY_VAR:MY_OTHER" ]]
}

# Injection resistance

@test "set: shell metacharacters in values are neutralised by printf %q" {
  eval "$(bash "$ENV_BASH" set injection.env)"
  # Values must be literal strings, not executed
  [[ "$SAFE_VAR" == '$(echo INJECTED)' ]]
  [[ "$BACKTICK_VAR" == '`echo INJECTED`' ]]
  [[ "$SEMI_VAR" == 'val; echo INJECTED' ]]
}

# Interactive fzf selection

@test "run: exits non-zero and reports 'No entry selected' when fzf returns no selection" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run env "PATH=$tmpbin:$PATH" bash "$ENV_BASH" run -- true
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No entry selected" ]]
}

@test "run: uses fzf selection when no entry argument is given" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run --separate-stderr env "PATH=$tmpbin:$PATH" "MOCK_FZF_OUTPUT=myentry.env" bash "$ENV_BASH" run -- printenv MY_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue" ]]
}

@test "set: exits non-zero and reports 'No entry selected' when fzf returns no selection" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run env "PATH=$tmpbin:$PATH" bash "$ENV_BASH" set
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No entry selected" ]]
}

@test "set: uses fzf selection when no entry argument is given" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run env "PATH=$tmpbin:$PATH" "MOCK_FZF_OUTPUT=myentry.env" bash "$ENV_BASH" set
  [ "$status" -eq 0 ]
  [[ "$output" =~ "export MY_VAR=" ]]
  [[ "$output" =~ "export MY_OTHER=" ]]
}

@test "unset: exits non-zero and reports 'No entry selected' when fzf returns no selection" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run env "PATH=$tmpbin:$PATH" bash "$ENV_BASH" unset
  [ "$status" -ne 0 ]
  [[ "$output" =~ "No entry selected" ]]
}

@test "unset: uses fzf selection when no entry argument is given" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  ln -s "$REPO_ROOT/test/helpers/mock_fzf" "$tmpbin/fzf"
  run env "PATH=$tmpbin:$PATH" "MOCK_FZF_OUTPUT=myentry.env" bash "$ENV_BASH" unset
  [ "$status" -eq 0 ]
  [[ "$output" =~ "unset" ]]
  [[ "$output" =~ "MY_VAR" ]]
  [[ "$output" =~ "MY_OTHER" ]]
}

# Spaces in PASSWORD_STORE_DIR

@test "list: works when PASSWORD_STORE_DIR contains spaces" {
  local spaced_dir="$BATS_TEST_TMPDIR/store with spaces"
  mkdir -p "$spaced_dir"
  touch "$spaced_dir/myentry.env.gpg"
  run env "PASSWORD_STORE_DIR=$spaced_dir" bash "$ENV_BASH" list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "myentry.env" ]]
}

# Entry marker emission

@test "set: emits an entry marker comment before the exports" {
  run bash "$ENV_BASH" set myentry.env
  [ "$status" -eq 0 ]
  [[ "$output" =~ "# pass-env entry: myentry.env" ]]
}

@test "set: marker output is still eval-safe" {
  eval "$(bash "$ENV_BASH" set myentry.env)"
  [[ "$MY_VAR" == "myvalue" ]]
}

@test "set: no marker (no partial output) when the entry is malformed" {
  run bash "$ENV_BASH" set badformat.env
  [ "$status" -ne 0 ]
  ! [[ "$output" =~ "# pass-env entry" ]]
}

# Traversal check precision

@test "set: accepts an entry name containing '..' that is not a path component" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/a..b.env"
  printf 'DOTDOT_VAR=ok\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/a..b.env.gpg"
  run bash "$ENV_BASH" set a..b.env
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/a..b.env.gpg"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "export DOTDOT_VAR=" ]]
}

# Expanded denylist

@test "set: refuses to set HOME from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_home.env"
  printf 'HOME=/tmp/evil\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_home.env.gpg"
  run bash "$ENV_BASH" set danger_home.env
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_home.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

@test "run: refuses to set GIT_SSH_COMMAND from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_git.env"
  printf 'GIT_SSH_COMMAND=evil\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_git.env.gpg"
  run bash "$ENV_BASH" run danger_git.env -- true
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_git.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

@test "set: refuses to set PS0 from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_ps0.env"
  printf 'PS0=$(evil)\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_ps0.env.gpg"
  run bash "$ENV_BASH" set danger_ps0.env
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_ps0.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

@test "set: refuses to set the zsh RPROMPT from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_rprompt.env"
  printf 'RPROMPT=$(evil)\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_rprompt.env.gpg"
  run bash "$ENV_BASH" set danger_rprompt.env
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_rprompt.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

@test "run: refuses to set LESSOPEN from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_lessopen.env"
  printf 'LESSOPEN=|evil %%s\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_lessopen.env.gpg"
  run bash "$ENV_BASH" run danger_lessopen.env -- true
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_lessopen.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

@test "run: refuses to set GIT_CONFIG_KEY_0 from an entry" {
  local content_fixture="$PASSENV_FIXTURE_CONTENT_DIR/danger_gitconfig.env"
  printf 'GIT_CONFIG_KEY_0=core.fsmonitor\n' > "$content_fixture"
  touch "$PASSWORD_STORE_DIR/danger_gitconfig.env.gpg"
  run bash "$ENV_BASH" run danger_gitconfig.env -- true
  rm -f "$content_fixture" "$PASSWORD_STORE_DIR/danger_gitconfig.env.gpg"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sensitive variable" ]]
}

# Command after -- : leading VAR=value assignment prefix

@test "run: honors a leading VAR=value assignment before the command" {
  # Mirrors the real report: `run entry.env -- PASS=password openai ...`.
  # The assignment is the first token after --; a bare exec would treat
  # 'FROMCMD=fromcmd' as the program name and fail.
  run bash "$ENV_BASH" run myentry.env -- FROMCMD=fromcmd printenv FROMCMD
  [ "$status" -eq 0 ]
  [[ "$output" == "fromcmd" ]]
}

@test "run: assignment prefix does not stop entry vars from reaching the command" {
  # PASS=... prefixes the command; MY_VAR comes from the entry. Both must be visible.
  run bash "$ENV_BASH" run myentry.env -- PASS=secret bash -c 'printf "%s %s" "$PASS" "$MY_VAR"'
  [ "$status" -eq 0 ]
  [[ "$output" == "secret myvalue" ]]
}

@test "run: preserves a quoted argument containing a space" {
  run bash "$ENV_BASH" run myentry.env -- printf '[%s]' "test prompt"
  [ "$status" -eq 0 ]
  [[ "$output" == "[test prompt]" ]]
}

@test "run: preserves the command's own -- argument" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s\n' -- foo
  [ "$status" -eq 0 ]
  [[ "$output" == $'--\nfoo' ]]
}

# run: {{VAR}} argument placeholders

@test "run: substitutes a {{VAR}} placeholder from the entry" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s' '{{MY_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue" ]]
}

@test "run: substitutes a placeholder embedded in a larger argument" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s' 'x-{{MY_VAR}}-y'
  [ "$status" -eq 0 ]
  [[ "$output" == "x-myvalue-y" ]]
}

@test "run: substitutes multiple placeholders across arguments" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s|%s' '{{MY_VAR}}' '{{MY_OTHER}}'
  [ "$status" -eq 0 ]
  [[ "$output" == "myvalue|othervalue" ]]
}

@test "run: leaves {{...}} untouched when the name is not supplied by the entry" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s' 'Hello {{user_name}}!'
  [ "$status" -eq 0 ]
  [[ "$output" == 'Hello {{user_name}}!' ]]
}

@test "run: leaves unbalanced braces untouched" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s' '{{MY_VAR'
  [ "$status" -eq 0 ]
  [[ "$output" == '{{MY_VAR' ]]
}

@test "run: --no-expand leaves placeholders literal" {
  run bash "$ENV_BASH" run --no-expand myentry.env -- printf '%s' '{{MY_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == '{{MY_VAR}}' ]]
}

@test "run: substituted values are inert, not re-evaluated (no injection)" {
  # SEMI_VAR is literally 'val; echo INJECTED' in the fixture.
  run bash "$ENV_BASH" run injection.env -- printf '%s' '{{SEMI_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == 'val; echo INJECTED' ]]
}

@test "run: placeholder value containing spaces stays a single argument" {
  # SPECIAL_VAR is 'hello world'. It must arrive as ONE argument, not two:
  # the substituted value is never re-split or re-parsed.
  run bash "$ENV_BASH" run specialchars.env -- printf '[%s]' '{{SPECIAL_VAR}}'
  [ "$status" -eq 0 ]
  [[ "$output" == '[hello world]' ]]
}

# run: leading VAR=value assignments

@test "run: assignment prefix overrides a variable from the entry" {
  run bash "$ENV_BASH" run myentry.env -- MY_VAR=overridden printenv MY_VAR
  [ "$status" -eq 0 ]
  [[ "$output" == "overridden" ]]
}

@test "run: assignment prefix is usable as a {{VAR}} placeholder" {
  run bash "$ENV_BASH" run myentry.env -- FROMCMD=fromcmd printf '%s' '{{FROMCMD}}'
  [ "$status" -eq 0 ]
  [[ "$output" == "fromcmd" ]]
}

@test "run: multiple assignment prefixes are all applied" {
  run bash "$ENV_BASH" run myentry.env -- A=1 B=2 sh -c 'printf "%s%s" "$A" "$B"'
  [ "$status" -eq 0 ]
  [[ "$output" == "12" ]]
}

@test "run: an assignment-looking argument after the command is left alone" {
  run bash "$ENV_BASH" run myentry.env -- printf '%s' 'NOT=anassignment'
  [ "$status" -eq 0 ]
  [[ "$output" == 'NOT=anassignment' ]]
}

@test "run: errors when only assignments follow -- with no command" {
  run bash "$ENV_BASH" run myentry.env -- FOO=bar
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing COMMAND" ]]
}

@test "run: substituted values are not themselves re-expanded" {
  # A's value is the literal text '{{MY_VAR}}'. Substituting {{A}} must yield
  # that text verbatim, not 'myvalue': expansion is a single pass, so a value
  # can never smuggle in another placeholder.
  run bash "$ENV_BASH" run myentry.env -- A='{{MY_VAR}}' printf '%s' '{{A}}'
  [ "$status" -eq 0 ]
  [[ "$output" == '{{MY_VAR}}' ]]
}
