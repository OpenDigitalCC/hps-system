#!/usr/bin/env bats
#
# CS-1.8: scripts/cluster-bootstrap.sh. Runs the real script (real registry,
# real commit_changes, real pre-start-checks.sh) against a temp HPS_BASE.
# The interface does not need to exist; /etc/resolv.conf is redirected.

# Each bootstrap run takes seconds (the legacy commit path logs and jq-parses
# every key), so one shared run in $BATS_FILE_TMPDIR serves the read-only tests.
# Tests that change state use their own base ($TEST_DIR).

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
  "$SCRIPT" "${ARGS[@]}" --description "Lab cluster" --storage-network 10.31.0.0/24 \
    > "$BATS_FILE_TMPDIR/shared.out" 2>&1
}

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-80.XXXXXX")"
  common_env "$TEST_DIR"
  use_base "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# shared: point the test at the file-level bootstrap
shared() {
  use_base "$BATS_FILE_TMPDIR"
  export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
  export HPS_RESOLV_CONF="$BATS_FILE_TMPDIR/resolv.conf"
}

# key <name>: raw value from the lab cluster registry
key() { jq -r . "$DB/$1.json"; }

tree_sum() {
  (cd "$CFG" && find . -type f -not -path '*/.lock/*' | sort | xargs sha256sum)
}

@test "writes ACTIVE_CLUSTER and the cluster keys" {
  shared
  [ "$(jq -r . "$CFG/system.db/ACTIVE_CLUSTER.json")" = "lab" ]
  [ "$(key CLUSTER_NAME)" = "lab" ]
  [ "$(key STATUS)" = "initialized" ]
  [ "$(key DESCRIPTION)" = "Lab cluster" ]
  [ "$(key network_dns_domain)" = "lab.hps" ]
  [ "$(key network_dhcp_enabled)" = "true" ]
  [ "$(key network_dhcp_iface)" = "ens9" ]
  [ "$(key network_dhcp_ip)" = "10.100.1.1" ]
  [ "$(key network_dhcp_cidr)" = "10.100.1.1/24" ]
  [ "$(key network_cidr)" = "10.100.1.0/24" ]
  [ "$(key network_dhcp_rangesize)" = "100" ]
  [ "$(key network_dhcp_range_start)" = "10.100.1.100" ]
  [ "$(key network_dhcp_range_end)" = "10.100.1.199" ]
  [ "$(key network_syslog_server)" = "10.100.1.1" ]
  [ "$(key network_name_server)" = "10.100.1.1" ]
  [ "$(key network_time_server)" = "10.100.1.1" ]
  [ "$(key osvc_log_level)" = "info" ]
  [ "$(key osvc_listener_port)" = "1215" ]
  [ "$(key osvc_web_ui)" = "yes" ]
  [ "$(key osvc_web_port)" = "1214" ]
  [ "$(key osvc_hb_interval)" = "5" ]
  [ "$(key osvc_hb_timeout)" = "15" ]
  [ "$(key osvc_hb_type)" = "unicast" ]
}

@test "a storage network writes the vlan keys the interactive fragment writes" {
  shared
  [ "$(key network_storage_count)" = "1" ]
  [ "$(key network_storage_mtu)" = "1500" ]
  [ "$(key network_storage_base_vlan)" = "31" ]
  [ "$(key network_storage_subnet_base)" = "10.31" ]
  [ "$(key network_storage_subnet_cidr)" = "24" ]
  [ "$(key network_storage_vlan31_subnet)" = "10.31.0.0/24" ]
  [ "$(key network_storage_vlan31_gateway)" = "10.31.0.1" ]
  [ "$(key network_storage_vlan31_netmask)" = "255.255.255.0" ]
  [ "$(key network_storage_vlan31_domain)" = "storage1.lab.hps" ]
  [ "$(key network_storage_vlan31_allocated)" = "false" ]
}

@test "every key the dnsmasq generator reads is written, under the same name" {
  shared
  run grep -oE 'get (network_[a-z_]+)' "$ROOT/lib/functions.d/create-config-dnsmasq.sh"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 6 ]
  local line k
  for line in "${lines[@]}"; do
    k="${line#get }"
    [ -f "$DB/$k.json" ] || { echo "dnsmasq reads $k, bootstrap does not write it"; return 1; }
  done
}

@test "the IPS DNS and dhcp-hosts files are generated" {
  shared
  [ "$(cat "$CFG/clusters/lab/services/dns_hosts")" = "10.100.1.1 ips ips.lab.hps ntp syslog dhcp dns" ]
  [ -f "$CFG/clusters/lab/services/dhcp_addresses" ]
  [ -d "$CFG/clusters/lab/hosts" ]
}

@test "runs the pre-start checks and prints a summary of the keys" {
  shared
  out="$(cat "$BATS_FILE_TMPDIR/shared.out")"
  [[ "$out" == *"pre-start checks: passed"* ]]
  [[ "$out" =~ network_dhcp_iface[[:space:]]+ens9 ]]
  [[ "$out" =~ network_dhcp_range_end[[:space:]]+10.100.1.199 ]]
  [[ "$out" =~ ACTIVE_CLUSTER.*lab ]]
}

@test "says the interface cannot be checked outside the container" {
  shared
  grep -q "syntax only" "$BATS_FILE_TMPDIR/shared.out"
}

@test "logs every key it writes" {
  shared
  cat "$HPS_BASE"/hps-log/* "$BATS_FILE_TMPDIR/logger.log" > "$TEST_DIR/all.log" 2>/dev/null || true
  grep -q 'Set: network_dhcp_iface=ens9' "$TEST_DIR/all.log"
  grep -q 'Set: network_dhcp_range_start=10.100.1.100' "$TEST_DIR/all.log"
  grep -q 'Set: osvc_hb_type=unicast' "$TEST_DIR/all.log"
  grep -q 'bootstrap: set ACTIVE_CLUSTER=lab' "$TEST_DIR/all.log"
}

@test "refuses an existing cluster without --force and changes nothing" {
  shared
  tree_sum > "$TEST_DIR/before.sum"
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.50-10.100.1.60
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  tree_sum > "$TEST_DIR/after.sum"
  [ -s "$TEST_DIR/before.sum" ]
  diff "$TEST_DIR/before.sum" "$TEST_DIR/after.sum"
}

@test "a second --force run with the same arguments leaves identical files" {
  shared
  tree_sum > "$TEST_DIR/first.sum"
  run "$SCRIPT" "${ARGS[@]}" --description "Lab cluster" --storage-network 10.31.0.0/24 --force
  [ "$status" -eq 0 ]
  tree_sum > "$TEST_DIR/second.sum"
  [ -s "$TEST_DIR/first.sum" ]
  diff "$TEST_DIR/first.sum" "$TEST_DIR/second.sum"
}

@test "description defaults to the cluster name and dns domain to cluster.local" {
  run "$SCRIPT" --name lab --dhcp-iface ens9 --network 10.100.1.0/24 \
    --ips-ip 10.100.1.1 --dhcp-range 10.100.1.100-10.100.1.199
  [ "$status" -eq 0 ]
  [ "$(key DESCRIPTION)" = "lab" ]
  [ "$(key network_dns_domain)" = "cluster.local" ]
  [ "$(key network_storage_count)" = "0" ]
}

@test "--force rewrites changed values, drops stale storage keys, keeps CREATED" {
  run "$SCRIPT" "${ARGS[@]}" --storage-network 10.31.0.0/24
  [ "$status" -eq 0 ]
  created="$(key CREATED)"
  sleep 1
  run "$SCRIPT" --name lab --dhcp-iface ens10 --network 10.100.1.0/24 \
    --ips-ip 10.100.1.1 --dhcp-range 10.100.1.20-10.100.1.30 --force
  [ "$status" -eq 0 ]
  [ "$(key network_dhcp_iface)" = "ens10" ]
  [ "$(key network_dhcp_rangesize)" = "11" ]
  [ "$(key network_storage_count)" = "0" ]
  [ ! -e "$DB/network_storage_vlan31_subnet.json" ]
  [ "$(key CREATED)" = "$created" ]
}

@test "a range containing the IPS address is refused and nothing is written" {
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.1-10.100.1.50
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains the IPS address"* ]]
  run "$SCRIPT" --name lab --dhcp-iface ens9 --network 10.100.1.0/24 \
    --ips-ip 10.100.1.150 --dhcp-range 10.100.1.100-10.100.1.199
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains the IPS address"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "a range outside the CIDR is refused" {
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.2.10-10.100.2.20
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside"* ]]
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.200-10.100.2.10
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "the broadcast address and an inverted range are refused" {
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.100-10.100.1.255
  [ "$status" -ne 0 ]
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.199-10.100.1.100
  [ "$status" -ne 0 ]
  [[ "$output" == *"after range end"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "a bad CIDR is refused" {
  local bad
  for bad in 10.100.1.0/33 10.100.1.0 10.100.1.5/24 10.100.1.0/08 300.1.1.0/24 abc 10.100.1.0/31; do
    run "$SCRIPT" "${ARGS[@]}" --network "$bad"
    [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
    [[ "$output" == *"invalid --network"* ]] || { echo "$bad: $output"; return 1; }
  done
  [ ! -e "$HPS_BASE" ]
}

@test "an IPS address outside the CIDR or not a host address is refused" {
  local bad
  for bad in 10.100.2.1 10.100.1.0 10.100.1.255 10.100.1 not-an-ip 10.100.1.01; do
    run "$SCRIPT" "${ARGS[@]}" --ips-ip "$bad"
    [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
  done
  [ ! -e "$HPS_BASE" ]
}

@test "bad interface and cluster names are refused" {
  local bad
  for bad in "eth 0" "ens9;rm" "this-name-is-too-long" "-lead"; do
    run "$SCRIPT" "${ARGS[@]}" --dhcp-iface "$bad"
    [ "$status" -ne 0 ] || { echo "accepted iface '$bad'"; return 1; }
  done
  for bad in "9lab" "la--b" "la_b" "lab-"; do
    run "$SCRIPT" "${ARGS[@]}" --name "$bad"
    [ "$status" -ne 0 ] || { echo "accepted name '$bad'"; return 1; }
  done
  [ ! -e "$HPS_BASE" ]
}

@test "a storage network overlapping the cluster network or off-form is refused" {
  run "$SCRIPT" "${ARGS[@]}" --network 10.31.0.0/16 --ips-ip 10.31.0.1 \
    --dhcp-range 10.31.1.1-10.31.1.9 --storage-network 10.31.0.0/24
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlaps"* ]]
  run "$SCRIPT" "${ARGS[@]}" --storage-network 10.31.4.0/24
  [ "$status" -ne 0 ]
  [ ! -e "$HPS_BASE" ]
}

@test "missing and unknown arguments are usage errors" {
  run "$SCRIPT" --name lab
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
  run "$SCRIPT" "${ARGS[@]}" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dhcp-range"* ]]
}

@test "create_config_dnsmasq on the bootstrapped registry emits the iface, range and listen address" {
  shared
  export HPS_CONFIG_BASE="$CFG"
  unset HPS_SYSTEM_REGISTRY
  source "$ROOT/lib/hps-registry.sh"
  source "$ROOT/lib/functions.d/create-config-dnsmasq.sh"
  mkdir -p "$TEST_DIR/svc" "$TEST_DIR/tftp"
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/svc" ;;
      tftp)             echo "$TEST_DIR/tftp" ;;
      config_base)      echo "$HPS_CONFIG_BASE" ;;
      active_cluster)   system_registry get ACTIVE_CLUSTER ;;
      *) return 1 ;;
    esac
  }
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/svc/dnsmasq.conf"
  grep -qx 'interface=ens9' "$conf"
  grep -qx 'listen-address=10.100.1.1' "$conf"
  grep -qx 'dhcp-range=10.100.1.100,10.100.1.199,1h' "$conf"
  grep -qx 'domain=lab.hps' "$conf"
  grep -qx 'dhcp-boot=tag:ipxe,http://10.100.1.1/cgi-bin/boot_manager.sh?cmd=init' "$conf"
}

@test "dnsmasq falls back to the computed range when no explicit range is stored" {
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  unset HPS_SYSTEM_REGISTRY
  source "$ROOT/lib/hps-registry.sh"
  source "$ROOT/lib/functions.d/create-config-dnsmasq.sh"
  mkdir -p "$TEST_DIR/svc" "$TEST_DIR/tftp" "$TEST_DIR/cfg/clusters/c1/cluster.db"
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/svc" ;;
      tftp)             echo "$TEST_DIR/tftp" ;;
      config_base)      echo "$HPS_CONFIG_BASE" ;;
      active_cluster)   echo c1 ;;
      *) return 1 ;;
    esac
  }
  generate_dhcp_range_simple() { echo "192.0.2.2,192.0.2.21,1h"; }
  cluster_registry c1 set network_dhcp_ip 192.0.2.1
  cluster_registry c1 set network_dhcp_iface ens9
  cluster_registry c1 set network_cidr 192.0.2.0/24
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  grep -qx 'dhcp-range=192.0.2.2,192.0.2.21,1h' "$TEST_DIR/svc/dnsmasq.conf"
}
