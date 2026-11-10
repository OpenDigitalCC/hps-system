#!/usr/bin/env bats
#
# CS-3.5: osvc_cluster_node_list (the body of the read-only CGI command
# cluster_nodes): cluster name and every paired node's name and IP.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  source "$ROOT/lib/functions.d/cluster-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"
  DOMAIN="lab.example"
  hps_get_config() { [[ "$1" == active_cluster ]] && echo "lab"; }
  cluster_registry() { [[ "$1" == lab && "$2" == get && "$3" == network_dns_domain && -n "$DOMAIN" ]] && echo "$DOMAIN"; return 0; }
  list_cluster_hosts() { printf '%s\n' aabbccddee01 aabbccddee02 aabbccddee03 aabbccddee04 aabbccddee05; }
  # 01 paired; 02 paired, upper-case name with FQDN; 03 not paired; 04 no IP; 05 bad name
  host_registry() {
    local mac=$1 op=$2 key=$3
    [[ "$op" == get ]] || return 1
    case "$mac:$key" in
      aabbccddee01:ctrl_exec_paired | aabbccddee02:ctrl_exec_paired | aabbccddee04:ctrl_exec_paired | aabbccddee05:ctrl_exec_paired) echo 1700000000 ;;
      aabbccddee01:HOSTNAME) echo tch-001 ;;
      aabbccddee02:HOSTNAME) echo SCH-001.old.example ;;
      aabbccddee03:HOSTNAME) echo tch-002 ;;
      aabbccddee04:HOSTNAME) echo tch-003 ;;
      aabbccddee05:HOSTNAME) echo 'bad_name' ;;
      aabbccddee01:IP) echo 192.0.2.12 ;;
      aabbccddee02:IP) echo 192.0.2.11 ;;
      aabbccddee03:IP) echo 192.0.2.13 ;;
      aabbccddee05:IP) echo 192.0.2.15 ;;
      *) return 1 ;;
    esac
  }
  hps_log() { :; }
  export -f hps_get_config cluster_registry list_cluster_hosts host_registry hps_log
}

@test "lists the cluster, then the paired nodes with domain, lower case, sorted" {
  run -0 osvc_cluster_node_list
  [ "${lines[0]}" = "cluster lab" ]
  [ "${lines[1]}" = "node sch-001.lab.example 192.0.2.11" ]
  [ "${lines[2]}" = "node tch-001.lab.example 192.0.2.12" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "a cluster without a DNS domain lists bare names" {
  DOMAIN=""
  run -0 osvc_cluster_node_list
  [ "${lines[1]}" = "node sch-001 192.0.2.11" ]
}

@test "unpaired hosts, hosts without an IP and unusable names are left out" {
  run -0 osvc_cluster_node_list
  [[ "$output" != *tch-002* ]]
  [[ "$output" != *tch-003* ]]
  [[ "$output" != *bad_name* ]]
}

@test "no active cluster is a failure" {
  hps_get_config() { return 1; }
  run -1 osvc_cluster_node_list
}

@test "boot_manager.sh answers cmd=cluster_nodes read-only from that function" {
  grep -q 'if \[\[ "\$cmd" == "cluster_nodes" \]\]' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'osvc_cluster_node_list' "$ROOT/http/cgi-bin/boot_manager.sh"
  # nothing in the handler writes: no registry set/unset/delete between its markers
  sed -n '/cmd" == "cluster_nodes"/,/^fi$/p' "$ROOT/http/cgi-bin/boot_manager.sh" > "$BATS_TEST_TMPDIR/handler"
  run ! grep -E 'registry .* (set|unset|delete)|keysafe' "$BATS_TEST_TMPDIR/handler"
}
