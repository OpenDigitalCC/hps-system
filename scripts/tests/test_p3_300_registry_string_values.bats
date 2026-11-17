#!/usr/bin/env bats
#
# The Bash registry stores every scalar as the string given. A number-looking
# value (a MAC such as 5254000870e4, a hex id such as 8187e907) was re-printed
# by jq as a float (5.254000870E+13, 8.187E+910) when it was stored as a JSON
# number. Objects and arrays stay JSON.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-300.XXXXXX")"
  export TEST_DIR
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  HOSTS="$TEST_DIR/cfg/clusters/lab/hosts"
  export HOSTS
  mkdir -p "$HOSTS" "$TEST_DIR/cfg/clusters/lab/cluster.db"
  export HPS_LOG="$TEST_DIR/hps.log"
  : > "$HPS_LOG"
  hps_log() { echo "$*" >> "$HPS_LOG"; }
  make_timestamp() { echo "2026-11-17 12:00:00 UTC"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      cluster_hosts)  echo "$HOSTS" ;;
      config_base)    echo "$TEST_DIR/cfg" ;;
      *) return 1 ;;
    esac
  }
  export -f hps_log make_timestamp hps_get_config
  # shellcheck disable=SC1091
  source "$ROOT/lib/hps-registry.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  system_registry set ACTIVE_CLUSTER lab
  M=52:54:00:08:70:e4
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a MAC of digits and one e is stored and read back as given" {
  host_registry "$M" set boot_mac_last 5254000870e4
  run host_registry "$M" get boot_mac_last
  [ "$status" -eq 0 ]
  [ "$output" = "5254000870e4" ]
  [ "$(cat "$HOSTS/5254000870e4.db/boot_mac_last.json")" = '"5254000870e4"' ]
}

@test "a hex id that reads as a huge exponent is stored and read back as given" {
  host_registry "$M" set zfs_hostid 8187e907
  run host_registry "$M" get zfs_hostid
  [ "$output" = "8187e907" ]
}

@test "leading zeros, trailing zeros, true and null are kept as text" {
  local v
  for v in 007 1.50 1e5 true null 123456789012345678901234; do
    host_registry "$M" set probe "$v"
    [ "$(host_registry "$M" get probe)" = "$v" ]
  done
}

@test "text with quotes and spaces survives" {
  host_registry "$M" set note 'say "hi" there'
  [ "$(host_registry "$M" get note)" = 'say "hi" there' ]
}

@test "an object stays JSON" {
  host_registry "$M" set bmc_options '{"outlet":"pdu1:7"}'
  run jq -r .outlet "$HOSTS/5254000870e4.db/bmc_options.json"
  [ "$output" = "pdu1:7" ]
}

@test "an array stays JSON" {
  host_registry "$M" set nets '["a","b"]'
  run jq -r '.[1]' "$HOSTS/5254000870e4.db/nets.json"
  [ "$output" = "b" ]
}

@test "numeric comparison on the read value still works" {
  host_registry "$M" set pair_reboots 2
  v="$(host_registry "$M" get pair_reboots)"
  [ "$v" -lt 3 ]
  [ "$((v + 1))" -eq 3 ]
}

@test "cluster and system registries store a scalar as the string given" {
  cluster_registry lab set probe 8187e907
  [ "$(cluster_registry lab get probe)" = "8187e907" ]
  system_registry set PROBE 5254000870e4
  [ "$(system_registry get PROBE)" = "5254000870e4" ]
}

@test "a value written by Perl reads the same in Bash, and the other way round" {
  perl -I "$ROOT/lib/perl" -MHPS::Registry -e 'HPS::Registry->new(config_base=>$ENV{HPS_CONFIG_BASE})->host_set("5254000870e4","zfs_hostid","8187e907")'
  [ "$(host_registry "$M" get zfs_hostid)" = "8187e907" ]
  host_registry "$M" set boot_mac_last 5254000870e4
  run perl -I "$ROOT/lib/perl" -MHPS::Registry -e 'print HPS::Registry->new(config_base=>$ENV{HPS_CONFIG_BASE})->host_get("5254000870e4","boot_mac_last")'
  [ "$output" = "5254000870e4" ]
}

@test "the read-only check lists a mangled value and changes nothing" {
  mkdir -p "$HOSTS/5254000870e4.db"
  printf '5.254000870E+13\n' > "$HOSTS/5254000870e4.db/boot_mac_last.json"
  run -1 perl "$ROOT/bin/hps-registry-keys" --check --config-base "$TEST_DIR/cfg"
  [[ "$output" == *"host 5254000870e4 boot_mac_last 5.254000870E+13"* ]]
  [ "$(cat "$HOSTS/5254000870e4.db/boot_mac_last.json")" = "5.254000870E+13" ]
}

@test "the read-only check passes on clean data" {
  host_registry "$M" set boot_mac_last 5254000870e4
  host_registry "$M" set zfs_hostid 8187e907
  run perl "$ROOT/bin/hps-registry-keys" --check --config-base "$TEST_DIR/cfg"
  [ "$status" -eq 0 ]
}
