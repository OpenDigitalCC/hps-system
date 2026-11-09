#!/usr/bin/env bats
#
# CS-3.1: cluster-bootstrap.sh --network-add. The network layout is ONE JSON
# cluster key, network_layout; validation refuses a bad spec before anything is
# written. Real script, real registry, temp HPS_BASE (as test_p1_80).

common_env() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/scripts/cluster-bootstrap.sh"
  export HPS_SYSTEM_PATH="$ROOT"
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/logger.log"\n' "$1" > "$1/bin/logger"
  chmod +x "$1/bin/logger"
  export PATH="$1/bin:$PATH"
  export HPS_RESOLV_CONF="$1/resolv.conf"
  ARGS=(--name lab --dhcp-iface ens9 --network 10.100.1.0/24
        --ips-ip 10.100.1.1 --dhcp-range 10.100.1.100-10.100.1.199
        --dns-domain lab.hps)
}

use_base() {
  export HPS_BASE="$1/base"
  CFG="$HPS_BASE/hps-config"
  DB="$CFG/clusters/lab/cluster.db"
}

setup_file() {
  common_env "$BATS_FILE_TMPDIR"
  use_base "$BATS_FILE_TMPDIR"
  "$SCRIPT" "${ARGS[@]}" --storage-network 10.31.0.0/24 \
    --network-add odoo:10.40.0.0/24:vlan=40:bridge=br-odoo \
    --network-add db:10.41.0.0/24:vlan=41:purpose=storage \
    --network-add flat:10.42.0.0/24:nic=AA-BB-CC-DD-EE-01 \
    --network-add plain:10.43.0.0/24 \
    > "$BATS_FILE_TMPDIR/shared.out" 2>&1
}

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-00.XXXXXX")"
  common_env "$TEST_DIR"
  use_base "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

shared() {
  use_base "$BATS_FILE_TMPDIR"
}

# refused <network-add spec> <text expected in the output>
refused() {
  run "$SCRIPT" "${ARGS[@]}" --network-add "$1"
  [ "$status" -ne 0 ] || { echo "accepted $1"; return 1; }
  [[ "$output" == *"$2"* ]] || { echo "$1: $output"; return 1; }
  [ ! -e "$HPS_BASE" ] || { echo "$1 wrote the registry"; return 1; }
}

@test "the layout is one JSON cluster key with every network in it" {
  shared
  [ -f "$DB/network_layout.json" ]
  run jq -r 'keys | join(",")' "$DB/network_layout.json"
  [ "$output" = "db,flat,odoo,plain" ]
  run jq -cS '.odoo' "$DB/network_layout.json"
  [ "$output" = '{"bridge":"br-odoo","cidr":"10.40.0.0/24","purpose":"workload","vlan":40}' ]
}

@test "defaults: bridge br-<name>, purpose workload, vlan null; storage purpose kept" {
  shared
  [ "$(jq -r '.plain.bridge' "$DB/network_layout.json")" = "br-plain" ]
  [ "$(jq -r '.plain.purpose' "$DB/network_layout.json")" = "workload" ]
  [ "$(jq -r '.plain.vlan' "$DB/network_layout.json")" = "null" ]
  [ "$(jq -r '.db.purpose' "$DB/network_layout.json")" = "storage" ]
  [ "$(jq -r '.db.bridge' "$DB/network_layout.json")" = "br-db" ]
}

@test "a nic with colons or dashes is kept as a normalised MAC on an untagged network" {
  shared
  [ "$(jq -r '.flat.nic' "$DB/network_layout.json")" = "aa:bb:cc:dd:ee:01" ]
  [ "$(jq -r '.flat.vlan' "$DB/network_layout.json")" = "null" ]
}

@test "the provisioning network and its keys are unchanged by the layout" {
  shared
  [ "$(jq -r . "$DB/network_cidr.json")" = "10.100.1.0/24" ]
  [ "$(jq -r . "$DB/network_dhcp_range_start.json")" = "10.100.1.100" ]
  [ ! -e "$DB/network_provisioning.json" ]
}

@test "the summary prints network_layout" {
  grep -q '^network_layout ' "$BATS_FILE_TMPDIR/shared.out"
}

@test "a colon-form MAC given as nic= is accepted on the command line" {
  run "$SCRIPT" "${ARGS[@]}" --network-add flat:10.42.0.0/24:nic=aa:bb:cc:dd:ee:01
  [ "$status" -eq 0 ]
  [ "$(jq -r '.flat.nic' "$DB/network_layout.json")" = "aa:bb:cc:dd:ee:01" ]
}

@test "no --network-add writes no layout; --force without it drops a stale one" {
  run "$SCRIPT" "${ARGS[@]}" --network-add wl:10.40.0.0/24:vlan=40
  [ "$status" -eq 0 ]
  [ -f "$DB/network_layout.json" ]
  run "$SCRIPT" "${ARGS[@]}" --force
  [ "$status" -eq 0 ]
  [ ! -e "$DB/network_layout.json" ]
}

@test "a second --force run with the same layout leaves identical files" {
  run "$SCRIPT" "${ARGS[@]}" --network-add wl:10.40.0.0/24:vlan=40
  [ "$status" -eq 0 ]
  cp "$DB/network_layout.json" "$TEST_DIR/first.json"
  run "$SCRIPT" "${ARGS[@]}" --network-add wl:10.40.0.0/24:vlan=40 --force
  [ "$status" -eq 0 ]
  diff "$TEST_DIR/first.json" "$DB/network_layout.json"
}

@test "bad names are refused" {
  refused "Odoo:10.40.0.0/24" "invalid --network-add name"
  refused "9db:10.40.0.0/24" "invalid --network-add name"
  refused "a_b:10.40.0.0/24" "invalid --network-add name"
  refused ":10.40.0.0/24" "invalid --network-add name"
}

@test "the implicit provisioning name is refused" {
  refused "provisioning:10.40.0.0/24" "implicit network"
}

@test "bad CIDRs are refused" {
  refused "wl:10.40.0.5/24" "invalid cidr"
  refused "wl:10.40.0.0/31" "invalid cidr"
  refused "wl:10.40.0.0/7" "invalid cidr"
  refused "wl:300.40.0.0/24" "invalid cidr"
  refused "wl" "invalid cidr"
}

@test "a CIDR overlapping the provisioning network is refused" {
  refused "wl:10.100.0.0/16" "overlaps the provisioning network"
  refused "wl:10.100.1.0/25" "overlaps the provisioning network"
}

@test "a CIDR overlapping the storage network is refused" {
  run "$SCRIPT" "${ARGS[@]}" --storage-network 10.31.0.0/24 --network-add wl:10.31.0.0/25
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps --storage-network"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "vlan outside 1-4094 or not a number is refused" {
  refused "wl:10.40.0.0/24:vlan=0" "vlan"
  refused "wl:10.40.0.0/24:vlan=4095" "vlan"
  refused "wl:10.40.0.0/24:vlan=ten" "vlan"
  refused "wl:10.40.0.0/24:vlan=" "vlan"
}

@test "unknown field, bad purpose, bad bridge, bad nic, nic with vlan are refused" {
  refused "wl:10.40.0.0/24:colour=red" "unknown field"
  refused "wl:10.40.0.0/24:purpose=provisioning" "purpose"
  refused "wl:10.40.0.0/24:bridge=Br_1" "bridge"
  refused "wl:10.40.0.0/24:bridge=0123456789abcdef" "bridge"
  refused "wl:10.40.0.0/24:nic=xyz" "nic is not a MAC"
  refused "wl:10.40.0.0/24:vlan=40:nic=aa:bb:cc:dd:ee:01" "exclusive"
}

@test "a long network name needs an explicit bridge" {
  refused "averyveryverylongname:10.40.0.0/24" "give bridge="
}

@test "duplicate name, vlan, bridge and overlapping ranges are refused" {
  run "$SCRIPT" "${ARGS[@]}" --network-add a:10.40.0.0/24 --network-add a:10.41.0.0/24
  [ "$status" -ne 0 ]
  [[ "$output" == *"given twice"* ]]
  run "$SCRIPT" "${ARGS[@]}" --network-add a:10.40.0.0/24:vlan=5 --network-add b:10.41.0.0/24:vlan=5
  [ "$status" -ne 0 ]
  [[ "$output" == *"vlan 5 is already used by 'a'"* ]]
  run "$SCRIPT" "${ARGS[@]}" --network-add a:10.40.0.0/24:bridge=brx --network-add b:10.41.0.0/24:bridge=brx
  [ "$status" -ne 0 ]
  [[ "$output" == *"bridge 'brx' is already used"* ]]
  run "$SCRIPT" "${ARGS[@]}" --network-add a:10.40.0.0/16 --network-add b:10.40.1.0/24
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps network 'a'"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "--network-add without a value is a usage error" {
  run "$SCRIPT" "${ARGS[@]}" --network-add
  [ "$status" -ne 0 ]
}
