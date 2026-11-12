#!/usr/bin/env bats
#
# CS-1.8: a first start with no OpenSVC package and an empty distros folder
# must not fail service preparation or the post-start listener.

setup() {
  ORIG_PATH="$PATH"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-81.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/functions.d/supervisor-functions.sh"
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  supervisor_populate_tftp() { echo populate_tftp >> "$CALLS"; }
  os_seed_nixos() { echo os_seed >> "$CALLS"; }
  create_config_lighttpd() { echo lighttpd >> "$CALLS"; }
  create_config_dnsmasq() { echo dnsmasq >> "$CALLS"; }
  update_dns_dhcp_files() { echo dns_dhcp >> "$CALLS"; }
  create_config_rsyslog() { echo rsyslog >> "$CALLS"; }
  create_config_chrony() { echo chrony >> "$CALLS"; }
  osvc_prepare_cluster() { echo osvc_prepare >> "$CALLS"; return "${FAKE_OSVC_RC:-0}"; }
  osvc_configure_cluster() { echo osvc_configure >> "$CALLS"; return "${FAKE_OSVC_RC:-0}"; }
}

teardown() {
  PATH="$ORIG_PATH"
  rm -rf "$TEST_DIR"
}

@test "supervisor_prepare_services continues and succeeds when OpenSVC cannot be prepared" {
  FAKE_OSVC_RC=1
  run supervisor_prepare_services
  [ "$status" -eq 0 ]
  grep -q 'warn.*OpenSVC not prepared' "$TEST_DIR/hps.log"
  [ "$(tail -1 "$CALLS")" = "osvc_prepare" ]
  grep -qx lighttpd "$CALLS"
  grep -qx dnsmasq "$CALLS"
}

@test "_supervisor_post_start skips OpenSVC configuration when om is not installed" {
  mkdir -p "$TEST_DIR/empty"
  # shellcheck disable=SC2123  # an empty search path is the point: om must not be found
  PATH="$TEST_DIR/empty"
  run _supervisor_post_start
  [ "$status" -eq 0 ]
  PATH="$ORIG_PATH"
  if grep -qx osvc_configure "$CALLS"; then return 1; fi
  grep -q '^info .*not installed' "$TEST_DIR/hps.log"
  [ "$(grep -c 'not installed' "$TEST_DIR/hps.log")" -eq 1 ]
}

@test "the post-start listener runs once per supervisord start: no quick-exit retries, no restart" {
  local f="$ROOT/lib/functions.d/configure-supervisor.sh" block
  block=$(sed -n '/^\[eventlistener:post_start_config\]/,/^EOF/p' "$f")
  [[ "$block" == *$'\nstartsecs=0\n'* ]]
  [[ "$block" == *$'\nstartretries=0\n'* ]]
  [[ "$block" == *$'\nautorestart=false\n'* ]]
}

@test "_supervisor_post_start still configures OpenSVC and reports its failure when om exists" {
  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/om"
  chmod +x "$TEST_DIR/bin/om"
  PATH="$TEST_DIR/bin:$PATH"
  run _supervisor_post_start
  [ "$status" -eq 0 ]
  grep -qx osvc_configure "$CALLS"
  FAKE_OSVC_RC=1
  run _supervisor_post_start
  [ "$status" -eq 1 ]
}

