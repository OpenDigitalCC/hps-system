#!/usr/bin/env bats
#
# CS-3.9: commit_changes sends the pending key:value pairs to
# bin/hps-cluster-config apply - (one implementation validates, derives and
# writes), runs update_dns_dhcp_files after a good apply, and fails with the
# errors printed when validation rejects the set. Real CLI, real registry in a
# temp dir; the logger and the DNS/DHCP generator are stubbed.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-60.XXXXXX")"
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  export HPS_CLUSTER_CONFIG_NO_SYSLOG=1
  DB="$HPS_CONFIG_BASE/clusters/lab/cluster.db"
  mkdir -p "$DB"
  export CLUSTER_NAME=lab
  DNS_CALLS="$TEST_DIR/dns-calls"
  : > "$DNS_CALLS"
  hps_log() { :; }
  cli_info() { :; }
  cli_note() { :; }
  update_dns_dhcp_files() { echo "$*" >> "$DNS_CALLS"; }
  # shellcheck source=/dev/null
  source "$ROOT/lib/functions.d/cluster-interactive-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

key() { jq -r . "$DB/$1.json"; }

@test "a good pending set is written through apply, derived keys included, then DNS/DHCP files are generated" {
  CLUSTER_CONFIG_PENDING=("DESCRIPTION:Lab cluster" "network_dns_domain:lab.example"
    "network_dhcp_cidr:10.99.1.1/24" "network_storage_count:2" "network_storage_base_vlan:31"
    "network_storage_subnet_base:10.31" "network_storage_subnet_cidr:24" "osvc_hb_type:unicast")
  run commit_changes
  [ "$status" -eq 0 ]
  [ "$(key DESCRIPTION)" = "Lab cluster" ]
  [ "$(key network_dhcp_ip)" = "10.99.1.1" ]
  [ "$(key network_cidr)" = "10.99.1.0/24" ]
  [ "$(key network_storage_vlan32_subnet)" = "10.31.1.0/24" ]
  [ "$(key network_storage_vlan31_allocated)" = "false" ]
  [ "$(wc -l < "$DNS_CALLS")" -eq 1 ]
  [ "$(cat "$DNS_CALLS")" = "lab false" ]
}

@test "the pending array is cleared after a good commit" {
  CLUSTER_CONFIG_PENDING=("osvc_log_level:debug")
  commit_changes
  [ "${#CLUSTER_CONFIG_PENDING[@]}" -eq 0 ]
  [ "$(key osvc_log_level)" = "debug" ]
}

@test "an invalid pair rejects the whole set: non-zero, errors printed, nothing written, no DNS/DHCP run" {
  CLUSTER_CONFIG_PENDING=("DESCRIPTION:Lab cluster" "osvc_listener_port:80" "osvc_hb_type:broadcast")
  run --separate-stderr commit_changes
  [ "$status" -ne 0 ]
  # shellcheck disable=SC2154
  [[ "$stderr" == *"osvc_listener_port"* ]]
  [[ "$stderr" == *"osvc_hb_type"* ]]
  [ ! -e "$DB/DESCRIPTION.json" ]
  [ ! -s "$DNS_CALLS" ]
}

@test "a rejected set stays pending so the menu can show it again" {
  CLUSTER_CONFIG_PENDING=("osvc_listener_port:80")
  commit_changes || true
  [ "${#CLUSTER_CONFIG_PENDING[@]}" -eq 1 ]
}

@test "a value containing a colon is split at the first colon only" {
  CLUSTER_CONFIG_PENDING=("osvc_templates_url:https://example.invalid:8443/t" "osvc_packages_url:")
  commit_changes
  [ "$(key osvc_templates_url)" = "https://example.invalid:8443/t" ]
  [ "$(key osvc_packages_url)" = "" ]
}

@test "a key pended twice keeps its last value, as sequential writes did" {
  CLUSTER_CONFIG_PENDING=("osvc_log_level:debug" "osvc_log_level:warn")
  commit_changes
  [ "$(key osvc_log_level)" = "warn" ]
}

@test "the keys cluster-bootstrap.sh pends beyond the menu are accepted" {
  CLUSTER_CONFIG_PENDING=("network_dhcp_cidr:10.99.1.1/24" "network_static_start:10.99.1.200"
    "network_static_end:10.99.1.220" "network_reserved:10.99.1.5 10.99.1.6" "network_time_upstream:pool.ntp.org")
  run commit_changes
  [ "$status" -eq 0 ]
  [ "$(key network_reserved)" = "10.99.1.5 10.99.1.6" ]
}

@test "an empty pending set is a successful no-op" {
  CLUSTER_CONFIG_PENDING=()
  run commit_changes
  [ "$status" -eq 0 ]
  [ ! -s "$DNS_CALLS" ]
}

@test "the CLI receives apply - --cluster NAME and key = value lines" {
  cat > "$TEST_DIR/fake-cli" <<'FAKE'
#!/usr/bin/env bash
echo "$*" > "$FAKE_ARGS"
cat > "$FAKE_STDIN"
FAKE
  chmod +x "$TEST_DIR/fake-cli"
  export HPS_CLUSTER_CONFIG_BIN="$TEST_DIR/fake-cli" FAKE_ARGS="$TEST_DIR/args" FAKE_STDIN="$TEST_DIR/stdin"
  CLUSTER_CONFIG_PENDING=("a_key:one" "b_key:two:three")
  commit_changes
  [ "$(cat "$FAKE_ARGS")" = "apply - --cluster lab" ]
  [ "$(cat "$FAKE_STDIN")" = $'a_key = one\nb_key = two:three' ]
}

@test "the CLI failing is a failed commit even when it prints nothing" {
  printf '#!/usr/bin/env bash\nexit 3\n' > "$TEST_DIR/fake-cli"
  chmod +x "$TEST_DIR/fake-cli"
  export HPS_CLUSTER_CONFIG_BIN="$TEST_DIR/fake-cli"
  CLUSTER_CONFIG_PENDING=("a_key:one")
  run commit_changes
  [ "$status" -eq 1 ]
  [ ! -s "$DNS_CALLS" ]
}
