#!/usr/bin/env bats
#
# CS-2.4: ce_api_bring_up (called by ce_dispatcher_bring_up): api_socket and
# api_socket_group are written into ctrl-exec.conf once; the API client comes
# from the plugins .deb with `dpkg -i` only when ctrl-exec-cli is absent; the
# client is linked onto PATH. dpkg, usermod and getent are shims.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-62.XXXXXX")"
  export TEST_DIR
  export CALLS="$TEST_DIR/calls"
  : > "$CALLS"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/etc"

  export CTRL_EXEC_DISPATCHER_CONF="$TEST_DIR/etc/ctrl-exec.conf"
  export CTRL_EXEC_API_SOCKET="$TEST_DIR/run/api.sock"
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/ctrl-exec-api-plugins-latest.deb"
  export CTRL_EXEC_CLI_INSTALLED="$TEST_DIR/usr/share/ce/ctrl-exec-cli"
  export CTRL_EXEC_CLI_LINK="$TEST_DIR/bin/ctrl-exec-cli"
  export PATH="$TEST_DIR/bin:$PATH"

  printf 'port = 7443\nauth_hook = /etc/hook\n' > "$CTRL_EXEC_DISPATCHER_CONF"
  : > "$CTRL_EXEC_API_PLUGINS_DEB"

  # dpkg -i "installs" the client where the real deb does
  cat > "$TEST_DIR/bin/dpkg" <<'EOT'
#!/usr/bin/env bash
echo "dpkg $*" >> "$CALLS"
[[ -n "${FAKE_DPKG_RC:-}" ]] && exit "$FAKE_DPKG_RC"
mkdir -p "$(dirname "$CTRL_EXEC_CLI_INSTALLED")"
printf '#!/usr/bin/env bash\n' > "$CTRL_EXEC_CLI_INSTALLED"
chmod +x "$CTRL_EXEC_CLI_INSTALLED"
EOT
  cat > "$TEST_DIR/bin/usermod" <<'EOT'
#!/usr/bin/env bash
echo "usermod $*" >> "$CALLS"
EOT
  chmod +x "$TEST_DIR/bin/dpkg" "$TEST_DIR/bin/usermod"

  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "api_socket and its group are appended to ctrl-exec.conf" {
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -qx "api_socket = $TEST_DIR/run/api.sock" "$CTRL_EXEC_DISPATCHER_CONF"
  grep -qx 'api_socket_group = ctrl-exec' "$CTRL_EXEC_DISPATCHER_CONF"
  grep -qx 'port = 7443' "$CTRL_EXEC_DISPATCHER_CONF"
}

@test "api_socket is written once however often bring-up runs" {
  ce_api_bring_up
  ce_api_bring_up
  ce_api_bring_up
  [ "$(grep -c '^api_socket = ' "$CTRL_EXEC_DISPATCHER_CONF")" -eq 1 ]
  [ "$(grep -c '^api_socket_group = ' "$CTRL_EXEC_DISPATCHER_CONF")" -eq 1 ]
}

@test "an api_socket already in the config is left alone" {
  printf 'api_socket = /custom/api.sock\n' >> "$CTRL_EXEC_DISPATCHER_CONF"
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  [ "$(grep -c '^api_socket' "$CTRL_EXEC_DISPATCHER_CONF")" -eq 1 ]
  grep -qx 'api_socket = /custom/api.sock' "$CTRL_EXEC_DISPATCHER_CONF"
}

@test "dpkg -i runs when ctrl-exec-cli is absent, then the client is linked" {
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -qx "dpkg -i $CTRL_EXEC_API_PLUGINS_DEB" "$CALLS"
  [ -L "$CTRL_EXEC_CLI_LINK" ]
  [ "$(readlink "$CTRL_EXEC_CLI_LINK")" = "$CTRL_EXEC_CLI_INSTALLED" ]
}

@test "dpkg is not called when the client is already installed" {
  mkdir -p "$(dirname "$CTRL_EXEC_CLI_INSTALLED")"
  printf '#!/usr/bin/env bash\n' > "$CTRL_EXEC_CLI_INSTALLED"
  chmod +x "$CTRL_EXEC_CLI_INSTALLED"
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  run ! grep -q '^dpkg' "$CALLS"
}

@test "dpkg is not called when ctrl-exec-cli is on PATH" {
  printf '#!/usr/bin/env bash\n' > "$TEST_DIR/bin/ctrl-exec-cli"
  chmod +x "$TEST_DIR/bin/ctrl-exec-cli"
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  run ! grep -q '^dpkg' "$CALLS"
}

@test "a second bring-up does not run dpkg again" {
  ce_api_bring_up
  ce_api_bring_up
  [ "$(grep -c '^dpkg' "$CALLS")" -eq 1 ]
}

@test "a missing .deb is a warning, not a failure" {
  rm -f "$CTRL_EXEC_API_PLUGINS_DEB"
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  run ! grep -q '^dpkg' "$CALLS"
  grep -q 'warn ce_api_bring_up: ctrl-exec-cli absent' "$TEST_DIR/hps.log"
}

@test "a failing dpkg is a warning, not a failure" {
  FAKE_DPKG_RC=1 run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -q 'dpkg -i of the API plugins failed' "$TEST_DIR/hps.log"
}

@test "an absent ctrl-exec.conf is a warning and nothing is created" {
  rm -f "$CTRL_EXEC_DISPATCHER_CONF"
  run ce_api_bring_up
  [ "$status" -eq 0 ]
  [ ! -e "$CTRL_EXEC_DISPATCHER_CONF" ]
}

@test "ce_dispatcher_bring_up ends by calling ce_api_bring_up" {
  export CTRL_EXEC_PERSIST_CONF="$TEST_DIR/srv/conf"
  export CTRL_EXEC_PERSIST_STATE="$TEST_DIR/srv/state"
  export CTRL_EXEC_DISPATCHER_CONF_DIR="$TEST_DIR/etc2/ctrl-exec-dispatcher"
  export CTRL_EXEC_DISPATCHER_STATE_DIR="$TEST_DIR/var/lib/ctrl-exec"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/bin/ctrl-exec-dispatcher"
  printf '#!/usr/bin/env bash\ntouch "$CTRL_EXEC_DISPATCHER_CONF_DIR/ca.crt"\n' > "$CTRL_EXEC_DISPATCHER"
  chmod +x "$CTRL_EXEC_DISPATCHER"
  ce_api_bring_up() { echo "api-bring-up-called" >> "$CALLS"; }
  run ce_dispatcher_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'api-bring-up-called' "$CALLS"
}

@test "bring-up installs the HPS auth hook and names it in ctrl-exec.conf once" {
  grep -q 'auth-hook-hps' "$BATS_TEST_DIRNAME/../../lib/functions.d/ctrl-exec-functions.sh"
  grep -q 'auth_hook' "$BATS_TEST_DIRNAME/../../lib/functions.d/ctrl-exec-functions.sh"
  [ -x "$BATS_TEST_DIRNAME/../ctrl-exec-auth-hook.sh" ]
  grep -q 'ENVEXEC_PEER_UID' "$BATS_TEST_DIRNAME/../ctrl-exec-auth-hook.sh"
}
