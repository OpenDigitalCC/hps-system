#!/usr/bin/env bats
#
# IPS-07: registry key catalogue (HPS::Registry::Keys, docs/REGISTRY-KEYS.md),
# typed accessors, and ctrl_exec_paired_at written at pairing (the old key kept
# for one release, readers moved to the new one).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-96.XXXXXX")"
  export TEST_DIR
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  printf '#!/bin/bash\nexit 0\n' > "$CTRL_EXEC_DISPATCHER"
  chmod +x "$CTRL_EXEC_DISPATCHER"
  export REG_FILE="$TEST_DIR/registry"
  : > "$REG_FILE"
  id() { if [[ "${1:-}" == -u ]]; then echo 0; else command id "$@"; fi; }
  hps_log() { :; }
  host_registry() {
    local mac="$1" cmd="$2" key="$3" value="${4:-}"
    case "$cmd" in
      get)
        local line
        line=$(grep -F "${mac}|${key}=" "$REG_FILE" | tail -n1) || true
        [[ -n "$line" ]] || return 1
        printf '%s\n' "${line#*=}"
        ;;
      set) printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE" ;;
      delete) { grep -vF "${mac}|${key}=" "$REG_FILE" || true; } > "$REG_FILE.new"; mv "$REG_FILE.new" "$REG_FILE" ;;
    esac
  }
  export -f id hps_log host_registry
  # host_fqdn (host-functions.sh) stubbed: registry HOSTNAME (first label) + .lab.hps
  host_fqdn() {
    local h
    h=$(host_registry "$1" get HOSTNAME) || return 1
    printf '%s.lab.hps\n' "${h%%.*}"
  }
  export -f host_fqdn
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  MAC="52:54:00:11:22:33"
}

teardown() {
  rm -rf "$TEST_DIR"
}

seed_pairable() {
  host_registry "$MAC" set STATE NETWORK_BOOT
  host_registry "$MAC" set IP 10.99.1.50
  host_registry "$MAC" set HOSTNAME tch-050
  host_registry "$MAC" set last_boot_at "$(date +%s)"
  jq -n '{id:"abc123", hostname:"tch-050.lab.hps", ip:"10.99.1.50", source_ip:"10.99.1.50", code:"123456"}' \
    > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
}

@test "the catalogue test finds every written key in the table" {
  run perl -I"$ROOT/lib/perl" "$ROOT/t/83-registry-keys.t"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.."* ]]
  [[ "$output" != *"not ok"* ]]
}

@test "typed accessors refuse a wrong-typed value with the key named" {
  run perl -I"$ROOT/lib/perl" "$ROOT/t/84-registry-typed.t"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not ok"* ]]
}

@test "the catalogue declares ctrl_exec_paired_at an epoch" {
  run "$ROOT/bin/hps-registry-keys" --type host ctrl_exec_paired_at
  [ "$status" -eq 0 ]
  [ "$output" = "epoch" ]
}

@test "an unknown key has no declared type" {
  run "$ROOT/bin/hps-registry-keys" --type host no_such_key
  [ "$status" -eq 4 ]
}

@test "pairing records ctrl_exec_paired_at as an epoch and keeps the old key with the same value" {
  seed_pairable
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  run host_registry "$MAC" get ctrl_exec_paired_at
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{9,11}$ ]]
  at="$output"
  run host_registry "$MAC" get ctrl_exec_paired
  [ "$output" = "$at" ]
}

@test "a node paired before the upgrade (old key only) is still seen as paired" {
  seed_pairable
  host_registry "$MAC" set ctrl_exec_paired 1700000000
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "a node with only the new key is seen as paired" {
  seed_pairable
  host_registry "$MAC" set ctrl_exec_paired_at 1700000000
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "the node list reads ctrl_exec_paired_at" {
  source "$ROOT/lib/functions.d/cluster-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"
  hps_log() { :; }
  hps_get_config() { [[ "$1" == active_cluster ]] && echo lab; return 0; }
  cluster_registry() { return 1; }
  list_cluster_hosts() { printf '%s\n' aabbccddee01; }
  host_registry() {
    case "$1:$3" in
      aabbccddee01:ctrl_exec_paired_at) echo 1794321826 ;;
      aabbccddee01:HOSTNAME) echo tch-001 ;;
      aabbccddee01:IP) echo 192.0.2.12 ;;
      *) return 1 ;;
    esac
  }
  run -0 osvc_cluster_node_list
  [ "${lines[1]}" = "node tch-001 192.0.2.12" ]
}

@test "reopening the pairing window clears both pairing keys" {
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  ce_pairing_window_open() { return 0; }
  host_registry "$MAC" set ctrl_exec_paired_at 1700000000
  host_registry "$MAC" set ctrl_exec_paired 1700000000
  run nixos_open_pairing_window "$MAC"
  [ "$status" -eq 0 ]
  run host_registry "$MAC" get ctrl_exec_paired_at
  [ "$status" -eq 1 ]
  run host_registry "$MAC" get ctrl_exec_paired
  [ "$status" -eq 1 ]
}

@test "bin/hps-registry-keys --markdown is docs/REGISTRY-KEYS.md" {
  run "$ROOT/bin/hps-registry-keys" --markdown
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$ROOT/docs/REGISTRY-KEYS.md")" ]
}

@test "the wiring test fails when code writes a key that is not in the table" {
  mkdir -p "$TEST_DIR/copy/t"
  for d in lib http bin docs scripts cli node-manager; do
    cp -r "$ROOT/$d" "$TEST_DIR/copy/$d"
  done
  cp "$ROOT/t/83-registry-keys.t" "$TEST_DIR/copy/t/"
  run perl "$TEST_DIR/copy/t/83-registry-keys.t"
  [ "$status" -eq 0 ]
  printf '%s\n' 'host_registry "$mac" set brand_new_unlisted_key 1' >> "$TEST_DIR/copy/lib/functions.d/host-functions.sh"
  run perl "$TEST_DIR/copy/t/83-registry-keys.t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"brand_new_unlisted_key"* ]]
}
