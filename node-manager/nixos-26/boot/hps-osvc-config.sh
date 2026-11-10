#!/usr/bin/env bash
#
# hps-osvc-config - write the OpenSVC (om3) node configuration for this boot.
#
# Runs as ExecStartPre of opensvc-daemon (nix/modules/hps-opensvc.nix), after
# hps-node-init has set the transient hostname from the registry. The image
# holds no per-node or per-cluster value: everything comes from the IPS.
#
#   cluster name, paired nodes (name, ip)   IPS cmd=cluster_nodes
#   osvc_* cluster keys                     IPS cmd=cluster_variable
#   cluster secret                          $HPS_RUN_DIR/osvc-cluster-secret,
#                                           written by the allowlisted script
#                                           osvc-secret-set (delivered over
#                                           ctrl-exec by hps-osvc on the IPS)
#
# Files written (RAM root, root-only):
#   $OSVC_ETC/cluster.conf   [cluster] name, nodes, secret
#   $OSVC_ETC/node.conf      [listener] port; [hb#1] type, interval, timeout and,
#                            for unicast, one addr@<node> per cluster node
#   $HPS_RUN_DIR/opensvc.env OSVC_DAEMON_ARGS for the unit (log level)
#
# Keys read, with the value used when the IPS has none:
#   osvc_listener_port 1215, osvc_hb_type unicast, osvc_hb_interval 5,
#   osvc_hb_timeout 15, osvc_log_level info.
#   Log level: om3 sets it by command-line flag only; debug adds --debug,
#   info is the default, warn and error are not selectable at start (the unit
#   runs at info).
# osvc_web_ui, osvc_web_port, osvc_templates_url and osvc_packages_url have no
# om3 equivalent HPS uses and are not read.
#
# Exit: 0 written, 1 a read or write failed, 3 refused (no secret yet, this
# node not in the IPS node list, an unusable value).
#
# Overrides for tests: HPS_CMDLINE (file), HPS_RUN_DIR, OSVC_ETC, HPS_HOSTNAME.

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_RUN_DIR:=/run/hps}"
: "${OSVC_ETC:=/etc/opensvc}"

IPS=""
CLUSTER=""
SELF=""
NODES=()
ADDRS=()
LISTENER_PORT=1215
HB_TYPE=unicast
HB_INTERVAL=5
HB_TIMEOUT=15
LOG_LEVEL=info

log() {
  printf '[hps-osvc-config] %s\n' "$*" >&2
}

refuse() {
  log "refused: $*"
  exit 3
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

cmdline_value() {
  local key="$1" word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

discover_ips() {
  local ips
  ips=$(cmdline_value hps.ips || true)
  if [[ -z "$ips" ]]; then
    log "hps.ips absent from the command line; using the default gateway"
    ips=$(run ip -j route | jq -r '[.[] | select(.dst == "default")][0].gateway // empty')
  fi
  [[ -n "$ips" ]] || refuse "no IPS address (hps.ips= or a default gateway)"
  IPS="$ips"
}

current_hostname() {
  local full
  if [[ -v HPS_HOSTNAME ]]; then
    full="$HPS_HOSTNAME"
  else
    log "+ hostname"
    full=$(hostname)
  fi
  SELF="${full,,}"
  if [[ -z "$SELF" || "$SELF" == "localhost" || "$SELF" == "(none)" ]]; then
    refuse "no registry hostname yet ('${full}')"
  fi
}

# fetch <query>: print the CGI body. Returns 0 found, 4 HTTP error status
# (key absent), 1 any other failure.
fetch() {
  local out rc
  set +e
  out=$(run curl -fsS "http://${IPS}/cgi-bin/boot_manager.sh?$1")
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    printf '%s' "$out"
    return 0
  fi
  if [[ $rc -eq 22 ]]; then
    return 4
  fi
  log "curl exited $rc reading $1 from $IPS"
  return 1
}

# key_or_default <name> <default>: the cluster key's value, else the default.
key_or_default() {
  local val rc=0
  val=$(fetch "cmd=cluster_variable&name=$1") || rc=$?
  if [[ $rc -eq 0 && -n "$val" ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  if [[ $rc -ne 0 && $rc -ne 4 ]]; then
    exit 1
  fi
  printf '%s\n' "$2"
}

load_keys() {
  LISTENER_PORT=$(key_or_default osvc_listener_port 1215)
  HB_TYPE=$(key_or_default osvc_hb_type unicast)
  HB_INTERVAL=$(key_or_default osvc_hb_interval 5)
  HB_TIMEOUT=$(key_or_default osvc_hb_timeout 15)
  LOG_LEVEL=$(key_or_default osvc_log_level info)
  [[ "$LISTENER_PORT" =~ ^[0-9]{4,5}$ ]] || refuse "osvc_listener_port '$LISTENER_PORT' is not a port"
  [[ "$HB_INTERVAL" =~ ^[0-9]{1,2}$ ]] || refuse "osvc_hb_interval '$HB_INTERVAL' is not seconds"
  [[ "$HB_TIMEOUT" =~ ^[0-9]{1,3}$ ]] || refuse "osvc_hb_timeout '$HB_TIMEOUT' is not seconds"
  case "$HB_TYPE" in
    unicast | multicast) ;;
    *) refuse "osvc_hb_type '$HB_TYPE' is not unicast or multicast" ;;
  esac
  case "$LOG_LEVEL" in
    debug | info | warn | error) ;;
    *) refuse "osvc_log_level '$LOG_LEVEL' is not debug, info, warn or error" ;;
  esac
  if [[ "$LISTENER_PORT" != 1215 ]]; then
    log "warning: osvc_listener_port is $LISTENER_PORT; the node firewall opens 1215 only (hps-opensvc.nix)"
  fi
}

load_nodes() {
  local body kind a b
  body=$(fetch "cmd=cluster_nodes") || exit 1
  while read -r kind a b; do
    case "$kind" in
      cluster) CLUSTER="$a" ;;
      node)
        [[ "$a" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || refuse "node name '$a' is not usable"
        [[ "$b" =~ ^[0-9.]+$ ]] || refuse "node '$a' has no usable address ('$b')"
        NODES+=("$a")
        ADDRS+=("$b")
        ;;
      "") ;;
      *) log "ignoring unknown line '$kind'" ;;
    esac
  done <<< "$body"
  [[ "$CLUSTER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "cluster name '$CLUSTER' is not usable"
  [[ ${#NODES[@]} -gt 0 ]] || refuse "the IPS lists no paired nodes"
}

check_self() {
  local n
  for n in "${NODES[@]}"; do
    if [[ "$n" == "$SELF" ]]; then
      return 0
    fi
  done
  refuse "this node ('$SELF') is not in the IPS node list (${NODES[*]})"
}

# write_file <path> <mode> <content>: atomically, logged.
write_file() {
  local path="$1" mode="$2" body="$3"
  log "+ write $path (mode $mode)"
  ( umask 077; printf '%s\n' "$body" > "$path.tmp" )
  chmod "$mode" "$path.tmp"
  mv -f "$path.tmp" "$path"
}

write_cluster_conf() {
  local secret_file="$HPS_RUN_DIR/osvc-cluster-secret" csec
  [[ -s "$secret_file" ]] || refuse "no cluster secret at $secret_file (hps-osvc deliver has not run for this node)"
  csec=$(cat "$secret_file")
  [[ "$csec" =~ ^[0-9a-f]{32,}$ ]] || refuse "the cluster secret at $secret_file is not hex"
  write_file "$OSVC_ETC/cluster.conf" 0600 "[cluster]
name = $CLUSTER
nodes = ${NODES[*]}
secret = $csec"
}

write_node_conf() {
  local body i
  body="[listener]
port = $LISTENER_PORT

[hb#1]
type = $HB_TYPE
interval = $HB_INTERVAL
timeout = $HB_TIMEOUT"
  if [[ "$HB_TYPE" == unicast ]]; then
    for i in "${!NODES[@]}"; do
      body="${body}
addr@${NODES[$i]} = ${ADDRS[$i]}"
    done
  fi
  write_file "$OSVC_ETC/node.conf" 0600 "$body"
}

write_unit_env() {
  local args=""
  if [[ "$LOG_LEVEL" == debug ]]; then
    args="--debug"
  fi
  write_file "$HPS_RUN_DIR/opensvc.env" 0644 "OSVC_DAEMON_ARGS=$args"
}

main() {
  if [[ $# -ne 0 ]]; then
    log "takes no arguments"
    exit 2
  fi
  current_hostname
  discover_ips
  load_keys
  load_nodes
  check_self
  run mkdir -p "$OSVC_ETC" "$HPS_RUN_DIR"
  write_cluster_conf
  write_node_conf
  write_unit_env
  log "cluster $CLUSTER: ${#NODES[@]} node(s), this node $SELF, hb $HB_TYPE, listener $LISTENER_PORT"
}

main "$@"
