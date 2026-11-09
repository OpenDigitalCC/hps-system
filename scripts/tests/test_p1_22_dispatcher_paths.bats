#!/usr/bin/env bats
#
# CS-1.2: ce_dispatcher_bring_up uses the ctrl-exec 0.14 paths
# (/etc/ctrl-exec-dispatcher) and the tarball install route. Paths are
# redirected into a temp dir; install.sh and the dispatcher are shims.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-22.XXXXXX")"
  export TEST_DIR
  export CALLS="$TEST_DIR/calls"
  : > "$CALLS"
  hps_log() { :; }
  export -f hps_log

  export CTRL_EXEC_PERSIST_CONF="$TEST_DIR/srv/conf"
  export CTRL_EXEC_PERSIST_STATE="$TEST_DIR/srv/state"
  export CTRL_EXEC_DISPATCHER_CONF_DIR="$TEST_DIR/etc/ctrl-exec-dispatcher"
  export CTRL_EXEC_DISPATCHER_STATE_DIR="$TEST_DIR/var/lib/ctrl-exec"
  export CTRL_EXEC_DISPATCHER_TARBALL="$TEST_DIR/ctrl-exec-latest.tar.gz"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/bin/ctrl-exec-dispatcher"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin"

  # Shim dispatcher: setup-ca writes the CA where 0.14 puts it.
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOS'
#!/usr/bin/env bash
echo "dispatcher $*" >> "$CALLS"
if [[ "$1" == setup-ca ]]; then
  touch "$CTRL_EXEC_DISPATCHER_CONF_DIR/ca.crt"
fi
exit "${FAKE_CED_RC:-0}"
EOS
  chmod +x "$CTRL_EXEC_DISPATCHER"

  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

make_tarball() {
  mkdir -p "$TEST_DIR/pkg/ctrl-exec-9.9.9"
  cat > "$TEST_DIR/pkg/ctrl-exec-9.9.9/install.sh" <<'EOS'
#!/usr/bin/env bash
echo "install.sh $*" >> "$CALLS"
EOS
  chmod +x "$TEST_DIR/pkg/ctrl-exec-9.9.9/install.sh"
  tar -czf "$CTRL_EXEC_DISPATCHER_TARBALL" -C "$TEST_DIR/pkg" ctrl-exec-9.9.9
}

@test "bring-up links the 0.14 config dir to persistent storage" {
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  [ -L "$CTRL_EXEC_DISPATCHER_CONF_DIR" ]
  [ "$(readlink "$CTRL_EXEC_DISPATCHER_CONF_DIR")" = "$CTRL_EXEC_PERSIST_CONF" ]
  [ -L "$CTRL_EXEC_DISPATCHER_STATE_DIR" ]
}

@test "bring-up initialises the CA when ca.crt is missing from the new dir" {
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  grep -q '^dispatcher setup-ca$' "$CALLS"
  grep -q '^dispatcher setup-ctrl-exec$' "$CALLS"
  [ -f "$CTRL_EXEC_PERSIST_CONF/ca.crt" ]
}

@test "bring-up skips CA setup when ca.crt already exists in the new dir" {
  mkdir -p "$CTRL_EXEC_PERSIST_CONF"
  touch "$CTRL_EXEC_PERSIST_CONF/ca.crt"
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  run grep -c setup "$CALLS"
  [ "$output" -eq 0 ]
}

@test "bring-up ignores a CA left under the pre-0.13 config name" {
  mkdir -p "$TEST_DIR/etc/ctrl-exec"
  touch "$TEST_DIR/etc/ctrl-exec/ca.crt"
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  grep -q '^dispatcher setup-ca$' "$CALLS"
}

@test "bring-up installs from the tarball with install.sh --dispatcher" {
  rm -f "$CTRL_EXEC_DISPATCHER"
  make_tarball
  # install.sh stands in for the real installer by dropping the dispatcher.
  cat > "$TEST_DIR/pkg/ctrl-exec-9.9.9/install.sh" <<'EOS'
#!/usr/bin/env bash
echo "install.sh $*" >> "$CALLS"
cat > "$CTRL_EXEC_DISPATCHER" <<'EOD'
#!/usr/bin/env bash
echo "dispatcher $*" >> "$CALLS"
[[ "$1" == setup-ca ]] && touch "$CTRL_EXEC_DISPATCHER_CONF_DIR/ca.crt"
exit 0
EOD
chmod +x "$CTRL_EXEC_DISPATCHER"
EOS
  tar -czf "$CTRL_EXEC_DISPATCHER_TARBALL" -C "$TEST_DIR/pkg" ctrl-exec-9.9.9
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  grep -q '^install.sh --dispatcher$' "$CALLS"
  grep -q '^dispatcher setup-ca$' "$CALLS"
}

@test "bring-up fails clearly when neither dispatcher nor tarball exists" {
  rm -f "$CTRL_EXEC_DISPATCHER"
  run ce_dispatcher_bring_up
  [ "$status" -eq 1 ]
}

@test "bring-up also installs ctrl-exec-api from the tarball when it is absent" {
  grep -q 'install.sh --api' "$BATS_TEST_DIRNAME/../../lib/functions.d/ctrl-exec-functions.sh"
  grep -q 'command -v ctrl-exec-api' "$BATS_TEST_DIRNAME/../../lib/functions.d/ctrl-exec-functions.sh"
}
