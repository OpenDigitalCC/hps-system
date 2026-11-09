#!/usr/bin/env bats
#
# CS-1.1 item 5, 6: the bundle builder reads HOST_PROFILE (falling back to
# PROFILE), and init files are ordered base/ first, then the OS tree.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-12.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"
  export REG="$TEST_DIR/host.reg"
  : > "$REG"
  mac="00:11:22:33:44:55"

  hps_log() { echo "log $*" >> "$CALL_LOG"; }
  host_registry() {
    # host_registry <mac> get <key>
    local v
    v=$(sed -n "s/^$3=//p" "$REG")
    [[ -n "$v" ]] || return 1
    echo "$v"
  }
  export -f hps_log host_registry

  source "$ROOT/lib/functions.d/node-libraries-init.sh"
  # Defined after sourcing so the stub replaces the real bundle builder.
  node_build_functions() { echo "build $*" >> "$CALL_LOG"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "bundle builder reads HOST_PROFILE" {
  printf 'os_id=x86_64:alpine:3.20.2\nTYPE=TCH\nHOST_PROFILE=KVM\n' > "$REG"
  run hps_get_remote_functions
  [ "$status" -eq 0 ]
  grep -q "^build x86_64:alpine:3.20.2 TCH KVM " "$CALL_LOG"
  grep -q "HOST_PROFILE" "$CALL_LOG"
}

@test "bundle builder falls back to PROFILE" {
  printf 'os_id=x86_64:alpine:3.20.2\nTYPE=TCH\nPROFILE=OLD\n' > "$REG"
  run hps_get_remote_functions
  [ "$status" -eq 0 ]
  grep -q "^build x86_64:alpine:3.20.2 TCH OLD " "$CALL_LOG"
}

@test "bundle builder defaults the profile" {
  printf 'os_id=x86_64:alpine:3.20.2\nTYPE=TCH\n' > "$REG"
  run hps_get_remote_functions
  [ "$status" -eq 0 ]
  grep -q "^build x86_64:alpine:3.20.2 TCH DEFAULT " "$CALL_LOG"
}

@test "init files list base first then the OS tree, each sorted" {
  nm="$TEST_DIR/node-manager"
  mkdir -p "$nm/base" "$nm/base/sub" "$nm/alpine-3" "$nm/nixos-26" "$nm/aaa-1"
  touch "$nm/base/b.init" "$nm/base/sub/a.init" "$nm/alpine-3/x.init" "$nm/nixos-26/n.init"
  run _find_all_inits "$nm" "nixos-26"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$nm/base/b.init" ]
  [ "${lines[1]}" = "$nm/base/sub/a.init" ]
  [ "${lines[2]}" = "$nm/nixos-26/n.init" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "init order puts base first even when the OS dir sorts before base" {
  nm="$TEST_DIR/node-manager"
  mkdir -p "$nm/base" "$nm/alpine-3"
  touch "$nm/base/b.init" "$nm/alpine-3/x.init"
  run _find_all_inits "$nm" "alpine-3"
  [ "${lines[0]}" = "$nm/base/b.init" ]
  [ "${lines[1]}" = "$nm/alpine-3/x.init" ]
}
