#!/usr/bin/env bats
#
# osvc_hb counts only the peers that were delivered an om3 configuration. The
# node list the IPS gives every node (cmd=cluster_nodes, osvc_cluster_node_list)
# holds delivered hosts only (host key osvc_delivered_at, set by hps-osvc deliver),
# so om3 does not expect a paired host that never got a configuration (on the lab:
# sch-001, bld-001, cnh-004), which could never beat. A delivered peer that stops
# beating is still stale, and CRITICAL below quorum.
# om is a shim printing a status fixture built from the node list, as om3 would
# report the peers of that list.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/node-manager/nixos-26/plugins"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-301.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/om" <<'SH'
#!/usr/bin/env bash
cat "$TEST_DIR/status.json"
SH
  chmod +x "$TEST_DIR/bin/om"
  export HPS_OM="$TEST_DIR/bin/om"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/cluster-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  hps_get_config() { [[ "$1" == active_cluster ]] && echo "lab"; }
  cluster_registry() { return 0; }
  hps_log() { :; }
  # Hosts: tch-001..tch-004 are paired and delivered; sch-001, bld-001 and cnh-004
  # are paired and never delivered (the lab trial nodes).
  list_cluster_hosts() { printf '%s\n' a1 a2 a3 a4 b1 b2 b3; }
  host_registry() {
    local mac=$1 op=$2 key=$3
    [[ "$op" == get ]] || return 1
    case "$key" in
      ctrl_exec_paired_at) return 0 ;;
      osvc_delivered_at) case "$mac" in a1 | a2 | a3 | a4) echo 1700000000 ;; *) return 1 ;; esac ;;
      HOSTNAME) case "$mac" in a1) echo tch-001 ;; a2) echo tch-002 ;; a3) echo tch-003 ;; a4) echo tch-004 ;;
                b1) echo sch-001 ;; b2) echo bld-001 ;; b3) echo cnh-004 ;; esac ;;
      IP) case "$mac" in a1) echo 10.0.0.1 ;; a2) echo 10.0.0.2 ;; a3) echo 10.0.0.3 ;; a4) echo 10.0.0.4 ;;
                b1) echo 10.0.0.5 ;; b2) echo 10.0.0.6 ;; b3) echo 10.0.0.7 ;; esac ;;
      *) return 1 ;;
    esac
  }
  export -f hps_get_config cluster_registry hps_log list_cluster_hosts host_registry
}

teardown() {
  rm -rf "$TEST_DIR"
}

# status_for <self> <stale names (space separated, may be empty)>: the om daemon
# status of <self>, whose peers are the other nodes of the node list the IPS gives.
status_for() {
  local self=$1 stale=" ${2:-} " kind name ip peers="" beating
  while read -r kind name ip; do
    [[ "$kind" == node && "$name" != "$self" ]] || continue
    beating=true
    [[ "$stale" == *" $name "* ]] && beating=false
    peers+="${peers:+,}\"$name\":{\"is_beating\":$beating}"
  done < <(osvc_cluster_node_list)
  printf '{"daemon":{"nodename":"%s"},"cluster":{"node":{"%s":{"daemon":{"heartbeat":{"streams":[{"id":"hb#1.rx","peers":{%s}},{"id":"hb#1.tx","peers":{%s}}]}}}}}}\n' \
    "$self" "$self" "$peers" "$peers" > "$TEST_DIR/status.json"
}

@test "the node list holds delivered hosts only" {
  run -0 osvc_cluster_node_list
  [[ "$output" == *"node tch-001 10.0.0.1"* ]]
  [[ "$output" == *"node tch-004 10.0.0.4"* ]]
  [[ "$output" != *sch-001* ]]
  [[ "$output" != *bld-001* ]]
  [[ "$output" != *cnh-004* ]]
}

@test "a delivered host leaves no peer for the check to find stale: OK with the undelivered hosts paired" {
  status_for tch-001 ""
  run "$P/check_osvc_hb"
  [ "$status" -eq 0 ]
  [ "$output" = "OSVC_HB OK - 3 of 3 peers beating | peers=3 beating=3 stale=0" ]
}

@test "control: peers that never beat in the list read WARNING, then CRITICAL once they cost the quorum (the fault this removes)" {
  # the delivered four plus the three undelivered hosts, which never beat
  peers='"tch-002":{"is_beating":true},"tch-003":{"is_beating":true},"tch-004":{"is_beating":true},"sch-001":{"is_beating":false},"bld-001":{"is_beating":false},"cnh-004":{"is_beating":false}'
  printf '{"daemon":{"nodename":"tch-001"},"cluster":{"node":{"tch-001":{"daemon":{"heartbeat":{"streams":[{"peers":{%s}}]}}}}}}\n' "$peers" > "$TEST_DIR/status.json"
  run "$P/check_osvc_hb"
  [ "$status" -eq 1 ]
  # with one more undelivered host the quorum is lost
  peers="$peers"',"x-001":{"is_beating":false}'
  printf '{"daemon":{"nodename":"tch-001"},"cluster":{"node":{"tch-001":{"daemon":{"heartbeat":{"streams":[{"peers":{%s}}]}}}}}}\n' "$peers" > "$TEST_DIR/status.json"
  run "$P/check_osvc_hb"
  [ "$status" -eq 2 ]
}

@test "a delivered peer that stops beating is still stale: WARNING for one" {
  status_for tch-001 "tch-003"
  run "$P/check_osvc_hb"
  [ "$status" -eq 1 ]
  [[ "$output" == "OSVC_HB WARNING - 2 of 3 peers beating; stale: tch-003 |"* ]]
}

@test "delivered peers that stop beating are CRITICAL below quorum" {
  status_for tch-001 "tch-002 tch-003"
  run "$P/check_osvc_hb"
  [ "$status" -eq 2 ]
  [[ "$output" == "OSVC_HB CRITICAL - 1 of 3 peers beating, below quorum (2 of 4 nodes, 3 needed); stale: tch-002 tch-003 |"* ]]
}

@test "delivering a host adds it to the list, an undelivered one stays out" {
  host_registry() {
    local mac=$1 op=$2 key=$3
    [[ "$op" == get ]] || return 1
    case "$mac:$key" in
      a1:ctrl_exec_paired_at | b1:ctrl_exec_paired_at | a1:osvc_delivered_at) return 0 ;;
      a1:HOSTNAME) echo tch-001 ;;
      b1:HOSTNAME) echo sch-001 ;;
      a1:IP) echo 10.0.0.1 ;;
      b1:IP) echo 10.0.0.5 ;;
      *) return 1 ;;
    esac
  }
  list_cluster_hosts() { printf '%s\n' a1 b1; }
  run -0 osvc_cluster_node_list
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "node tch-001 10.0.0.1" ]
}
