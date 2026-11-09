#!/usr/bin/env bash
#===============================================================================
# cluster-bootstrap.sh
# --------------------
# Create and activate an HPS cluster without prompts.
#
# Writes the registry a human run of cli/cluster-configure.sh would write
# (initialise_cluster, the scripts/cluster-config.d fragments 010/015/020/050/
# 070/090, commit_changes, set_active_cluster) by calling the same functions,
# then runs scripts/pre-start-checks.sh and prints the keys written.
#
# Usage:
#   cluster-bootstrap.sh --name <cluster> --dhcp-iface <if> --network <cidr> \
#       --ips-ip <ip> --dhcp-range <start>-<end> [--dns-domain <d>] \
#       [--description <s>] [--storage-network <cidr>] \
#       [--time-upstream "<servers>"] [--force]
#
# Time: nodes take time only from the IPS (cluster key network_time_server =
# the IPS address; the node images consult no public pool). The IPS runs
# chrony and serves its own clock at stratum 10. --time-upstream sets the
# cluster key network_time_upstream, a space-separated list of NTP servers or
# pools the IPS itself syncs from (create_config_chrony writes one
# "server <name> iburst" line each). Empty by default: no upstream, the lab
# has no NTP egress.
#
# Environment:
#   HPS_BASE         base path (default /srv); hps.conf lives here
#   HPS_SYSTEM_PATH  hps-system tree (default: the tree this script is in)
#   HPS_CONFIG_BASE, HPS_RESOURCES, HPS_LOG
#                    relocate one path when hps.conf is first created
#
# The interface name is checked for syntax only: whether it exists is only
# knowable inside the container, on the host network.
#
# Exit: 0 done, 1 refused or failed, 2 bad usage.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_NAME=""
ARG_IFACE=""
ARG_NETWORK=""
ARG_IPS_IP=""
ARG_RANGE=""
ARG_DOMAIN="cluster.local"
ARG_DESC=""
ARG_STORAGE=""
ARG_TIME_UPSTREAM=""
ARG_FORCE=0

# Filled by validation
RANGE_START=""
RANGE_END=""
NET_CIDR=""
NET_PREFIX=""
NET_LO=0
NET_HI=0

usage() {
  cat <<'EOF'
Usage: cluster-bootstrap.sh --name <cluster> --dhcp-iface <if> --network <cidr>
         --ips-ip <ip> --dhcp-range <start>-<end> [--dns-domain <d>]
         [--description <s>] [--storage-network <cidr>]
         [--time-upstream "<servers>"] [--force]

  --name             cluster name (DNS label: letters, digits, hyphens)
  --dhcp-iface       interface dnsmasq answers on (syntax checked only)
  --network          cluster network, network address form (A.B.C.0/N)
  --ips-ip           IPS address, inside --network
  --dhcp-range       first and last lease address, inside --network, not
                     containing --ips-ip
  --dns-domain       default cluster.local
  --description      default: the cluster name
  --storage-network  optional, A.B.0.0/N (N 16-28), one storage network
  --time-upstream    NTP servers/pools the IPS syncs from, space separated
                     (cluster key network_time_upstream); default empty = the
                     IPS serves its own clock. Nodes always use the IPS only.
  --force            overwrite an existing cluster (keys are rewritten,
                     other keys and hosts are kept)
EOF
}

fail() {
  echo "cluster-bootstrap: $*" >&2
  exit 1
}

bad_usage() {
  echo "cluster-bootstrap: $*" >&2
  usage >&2
  exit 2
}

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)            ARG_NAME="${2:?--name needs a value}"; shift 2 ;;
      --dhcp-iface)      ARG_IFACE="${2:?--dhcp-iface needs a value}"; shift 2 ;;
      --network)         ARG_NETWORK="${2:?--network needs a value}"; shift 2 ;;
      --ips-ip)          ARG_IPS_IP="${2:?--ips-ip needs a value}"; shift 2 ;;
      --dhcp-range)      ARG_RANGE="${2:?--dhcp-range needs a value}"; shift 2 ;;
      --dns-domain)      ARG_DOMAIN="${2:?--dns-domain needs a value}"; shift 2 ;;
      --description)     ARG_DESC="${2:?--description needs a value}"; shift 2 ;;
      --storage-network) ARG_STORAGE="${2:?--storage-network needs a value}"; shift 2 ;;
      --time-upstream)   ARG_TIME_UPSTREAM="${2?--time-upstream needs a value (may be empty)}"; shift 2 ;;
      --force)           ARG_FORCE=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *)                 bad_usage "unknown argument: $1" ;;
    esac
  done
  [[ -n "$ARG_NAME" ]]    || bad_usage "--name is required"
  [[ -n "$ARG_IFACE" ]]   || bad_usage "--dhcp-iface is required"
  [[ -n "$ARG_NETWORK" ]] || bad_usage "--network is required"
  [[ -n "$ARG_IPS_IP" ]]  || bad_usage "--ips-ip is required"
  [[ -n "$ARG_RANGE" ]]   || bad_usage "--dhcp-range is required"
  [[ -n "$ARG_DESC" ]]    || ARG_DESC="$ARG_NAME"
  return 0
}

#-------------------------------------------------------------------------------
# Pure validators (no HPS libraries needed, so a bad call writes nothing)
#-------------------------------------------------------------------------------
valid_ipv4() {
  local ip="$1" octet
  local -a octets
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]] || return 1
  done
  return 0
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ipv4() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# cidr_bounds <cidr> <min-prefix> <max-prefix>
# Prints "<network-int> <broadcast-int> <prefix>"; fails unless the address is
# the network address of a prefix within the allowed range.
cidr_bounds() {
  local cidr="$1" minp="$2" maxp="$3"
  local addr prefix mask net bc
  [[ "$cidr" =~ ^[0-9.]+/(0|[1-9][0-9]?)$ ]] || return 1
  addr="${cidr%/*}"
  prefix="${cidr#*/}"
  valid_ipv4 "$addr" || return 1
  (( prefix >= minp && prefix <= maxp )) || return 1
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  net=$(( $(ipv4_to_int "$addr") & mask ))
  bc=$(( net | (~mask & 0xFFFFFFFF) ))
  (( net == $(ipv4_to_int "$addr") )) || return 1
  echo "$net $bc $prefix"
}

validate_name() {
  [[ "$ARG_NAME" =~ ^[a-zA-Z]([a-zA-Z0-9-]?[a-zA-Z0-9])*$ ]] \
    || fail "invalid cluster name '$ARG_NAME': start with a letter; letters, digits, single hyphens"
  (( ${#ARG_NAME} <= 63 )) || fail "cluster name too long (max 63)"
  [[ "$ARG_NAME" != *--* ]] || fail "cluster name cannot contain consecutive hyphens"
}

validate_iface() {
  [[ "$ARG_IFACE" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,14}$ ]] \
    || fail "invalid interface name '$ARG_IFACE' (1-15 characters: letters, digits, _ . : @ -)"
  echo "cluster-bootstrap: note: interface '$ARG_IFACE' checked for syntax only; it can be verified only inside the container" >&2
}

validate_domain() {
  local label
  local -a labels
  [[ "$ARG_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]] \
    || fail "invalid DNS domain '$ARG_DOMAIN'"
  IFS=. read -r -a labels <<< "$ARG_DOMAIN"
  for label in "${labels[@]}"; do
    (( ${#label} <= 63 )) || fail "DNS label '$label' too long (max 63)"
  done
}

validate_description() {
  local bs=$'\\' dq='"'
  [[ "$ARG_DESC" != *"$dq"* && "$ARG_DESC" != *"$bs"* && "$ARG_DESC" != *$'\n'* ]] \
    || fail "description cannot contain double quotes, backslashes or newlines"
}

validate_network() {
  local bounds
  bounds=$(cidr_bounds "$ARG_NETWORK" 8 30) \
    || fail "invalid --network '$ARG_NETWORK': expected network-address CIDR such as 192.0.2.0/24 (prefix 8-30, host bits zero)"
  read -r NET_LO NET_HI NET_PREFIX <<< "$bounds"
  NET_CIDR="$ARG_NETWORK"
}

# Each upstream is a host name or address (letters, digits, dots, hyphens).
validate_time_upstream() {
  local name
  for name in $ARG_TIME_UPSTREAM; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "invalid --time-upstream entry '$name'"
  done
}

# Address must be a usable host address of the cluster network.
in_network() {
  local n
  n=$(ipv4_to_int "$1")
  (( n > NET_LO && n < NET_HI ))
}

validate_ips_ip() {
  validate_time_upstream
  valid_ipv4 "$ARG_IPS_IP" || fail "invalid --ips-ip '$ARG_IPS_IP'"
  in_network "$ARG_IPS_IP" || fail "--ips-ip $ARG_IPS_IP is not a usable host address inside $NET_CIDR"
}

validate_range() {
  local s e ips
  [[ "$ARG_RANGE" =~ ^([0-9.]+)-([0-9.]+)$ ]] \
    || fail "invalid --dhcp-range '$ARG_RANGE': expected <start>-<end>"
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[2]}"
  valid_ipv4 "$RANGE_START" || fail "invalid range start '$RANGE_START'"
  valid_ipv4 "$RANGE_END"   || fail "invalid range end '$RANGE_END'"
  in_network "$RANGE_START" || fail "range start $RANGE_START is not inside $NET_CIDR"
  in_network "$RANGE_END"   || fail "range end $RANGE_END is not inside $NET_CIDR"
  s=$(ipv4_to_int "$RANGE_START")
  e=$(ipv4_to_int "$RANGE_END")
  (( s <= e )) || fail "range start $RANGE_START is after range end $RANGE_END"
  ips=$(ipv4_to_int "$ARG_IPS_IP")
  if (( ips >= s && ips <= e )); then
    fail "--dhcp-range $ARG_RANGE contains the IPS address $ARG_IPS_IP"
  fi
}

validate_storage() {
  local bounds s_lo s_hi
  [[ -z "$ARG_STORAGE" ]] && return 0
  bounds=$(cidr_bounds "$ARG_STORAGE" 16 28) \
    || fail "invalid --storage-network '$ARG_STORAGE': expected A.B.0.0/N (network address, N 16-28)"
  read -r s_lo s_hi _ <<< "$bounds"
  [[ "$ARG_STORAGE" == *.0.0/* ]] \
    || fail "--storage-network must be of the form A.B.0.0/N (the layout the storage VLAN code generates)"
  if (( s_lo <= NET_HI && NET_LO <= s_hi )); then
    fail "--storage-network $ARG_STORAGE overlaps --network $NET_CIDR"
  fi
}

validate_args() {
  validate_name
  validate_iface
  validate_domain
  validate_description
  validate_network
  validate_ips_ip
  validate_range
  validate_storage
}

#-------------------------------------------------------------------------------
# HPS library bootstrap (as run-hps.sh does: tier 1, then functions.sh)
#-------------------------------------------------------------------------------
load_hps() {
  export HPS_BASE="${HPS_BASE:-/srv}"
  export HPS_SYSTEM_PATH="${HPS_SYSTEM_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"

  [[ -f "$HPS_SYSTEM_PATH/lib/hps-system.sh" ]] \
    || fail "bootstrap library not found: $HPS_SYSTEM_PATH/lib/hps-system.sh"

  # shellcheck source=/dev/null
  source "$HPS_SYSTEM_PATH/lib/hps-system.sh"

  # The dependency check (supervisord, wget, ...) belongs to run-hps.sh; this
  # script needs only the paths and the system registry.
  hps_ensure_base_path || fail "cannot prepare $HPS_BASE"
  hps_ensure_config || fail "cannot create hps.conf"
  hps_ensure_directories || fail "cannot create base directories"
  hps_ensure_system_registry || fail "cannot create the system registry"

  # shellcheck source=/dev/null
  source "$HPS_SYSTEM_PATH/lib/functions.sh" || fail "cannot load function libraries"
}

#-------------------------------------------------------------------------------
# The configuration, in the order and with the keys of the cluster-config.d
# fragments. Entries are "key:value" as commit_changes expects.
#-------------------------------------------------------------------------------
pending_description() {
  CLUSTER_CONFIG_PENDING+=("DESCRIPTION:$ARG_DESC")
}

pending_dns_domain() {
  CLUSTER_CONFIG_PENDING+=("network_dns_domain:$ARG_DOMAIN")
}

pending_dhcp() {
  local size
  size=$(( $(ipv4_to_int "$RANGE_END") - $(ipv4_to_int "$RANGE_START") + 1 ))
  CLUSTER_CONFIG_PENDING+=("network_dhcp_enabled:true")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_iface:$ARG_IFACE")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_ip:$ARG_IPS_IP")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_cidr:$ARG_IPS_IP/$NET_PREFIX")
  CLUSTER_CONFIG_PENDING+=("network_cidr:$NET_CIDR")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_rangesize:$size")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_range_start:$RANGE_START")
  CLUSTER_CONFIG_PENDING+=("network_dhcp_range_end:$RANGE_END")
}

pending_storage() {
  local base prefix subnet gateway netmask
  if [[ -z "$ARG_STORAGE" ]]; then
    CLUSTER_CONFIG_PENDING+=("network_storage_count:0")
    return 0
  fi
  base="${ARG_STORAGE%%.0.0/*}"
  prefix="${ARG_STORAGE#*/}"
  subnet=$(network_calculate_subnet "$base" 0 "$prefix") \
    || fail "cannot compute the storage subnet for $ARG_STORAGE"
  [[ "$subnet" == "$ARG_STORAGE" ]] \
    || fail "storage subnet computed as $subnet, expected $ARG_STORAGE"
  gateway="${subnet%/*}"
  gateway="${gateway%.*}.1"
  netmask=$(cidr_to_netmask "$prefix") || fail "cannot compute the storage netmask"
  CLUSTER_CONFIG_PENDING+=("network_storage_count:1")
  CLUSTER_CONFIG_PENDING+=("network_storage_mtu:1500")
  CLUSTER_CONFIG_PENDING+=("network_storage_base_vlan:31")
  CLUSTER_CONFIG_PENDING+=("network_storage_subnet_base:$base")
  CLUSTER_CONFIG_PENDING+=("network_storage_subnet_cidr:$prefix")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_subnet:$subnet")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_gateway:$gateway")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_netmask:$netmask")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_domain:storage1.$ARG_DOMAIN")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_allocated:false")
}

# 070 defaults: the IPS provides syslog, DNS and NTP.
pending_system_services() {
  CLUSTER_CONFIG_PENDING+=("network_syslog_server:$ARG_IPS_IP")
  CLUSTER_CONFIG_PENDING+=("network_name_server:$ARG_IPS_IP")
  CLUSTER_CONFIG_PENDING+=("network_time_server:$ARG_IPS_IP")
  CLUSTER_CONFIG_PENDING+=("network_time_upstream:$ARG_TIME_UPSTREAM")
}

# 090 defaults (the "customize? n" path).
pending_opensvc() {
  CLUSTER_CONFIG_PENDING+=("osvc_log_level:info")
  CLUSTER_CONFIG_PENDING+=("osvc_listener_port:1215")
  CLUSTER_CONFIG_PENDING+=("osvc_web_ui:yes")
  CLUSTER_CONFIG_PENDING+=("osvc_web_port:1214")
  CLUSTER_CONFIG_PENDING+=("osvc_hb_interval:5")
  CLUSTER_CONFIG_PENDING+=("osvc_hb_timeout:15")
  CLUSTER_CONFIG_PENDING+=("osvc_templates_url:")
  CLUSTER_CONFIG_PENDING+=("osvc_packages_url:")
  CLUSTER_CONFIG_PENDING+=("osvc_hb_type:unicast")
}

build_pending() {
  CLUSTER_CONFIG_PENDING=()
  pending_description
  pending_dns_domain
  pending_dhcp
  pending_storage
  pending_system_services
  pending_opensvc
}

#-------------------------------------------------------------------------------
# Writing
#-------------------------------------------------------------------------------
# --force: drop storage keys so a run without --storage-network does not keep
# the previous run's VLANs. Everything else (hosts, generated secrets) stays.
clear_storage_keys() {
  local key
  while IFS= read -r key; do
    [[ "$key" == network_storage_* ]] || continue
    hps_log info "bootstrap: delete $key (cluster $ARG_NAME)"
    cluster_registry "$ARG_NAME" delete "$key"
  done < <(cluster_registry "$ARG_NAME" list)
}

create_or_reuse_cluster() {
  if cluster_registry exists "$ARG_NAME"; then
    (( ARG_FORCE == 1 )) || fail "cluster '$ARG_NAME' already exists; use --force to rewrite its keys"
    hps_log info "bootstrap: cluster $ARG_NAME exists, rewriting keys (--force)"
    clear_storage_keys
    return 0
  fi
  initialise_cluster "$ARG_NAME" || fail "initialise_cluster failed for '$ARG_NAME'"
}

activate_cluster() {
  hps_log info "bootstrap: set ACTIVE_CLUSTER=$ARG_NAME"
  set_active_cluster "$ARG_NAME" || fail "cannot set ACTIVE_CLUSTER"
}

run_pre_start_checks() {
  local checks="$HPS_SYSTEM_PATH/scripts/pre-start-checks.sh"
  local logfile
  [[ -f "$checks" ]] || fail "pre-start checks not found: $checks"
  if bash "$checks"; then
    echo "pre-start checks: passed"
    return 0
  fi
  logfile=$(hps_get_config cluster_log 2>/dev/null) || logfile=""
  echo "pre-start checks: FAILED (registry left as written)" >&2
  [[ -n "$logfile" && -f "$logfile" ]] && tail -n 30 "$logfile" >&2
  return 1
}

print_summary() {
  local key value
  echo
  printf '%-36s %s\n' "KEY" "VALUE"
  printf '%-36s %s\n' "ACTIVE_CLUSTER (system)" "$(get_active_cluster_name)"
  for key in CLUSTER_NAME CREATED STATUS "${SUMMARY_KEYS[@]}"; do
    value=$(cluster_registry "$ARG_NAME" get "$key" 2>/dev/null) || value="(unset)"
    printf '%-36s %s\n' "$key" "$value"
  done
  echo
  echo "cluster '$ARG_NAME' bootstrapped under $(hps_get_config config_base)"
}

main() {
  local item
  parse_args "$@"
  validate_args
  load_hps

  export CLUSTER_NAME="$ARG_NAME"
  build_pending
  SUMMARY_KEYS=()
  for item in "${CLUSTER_CONFIG_PENDING[@]}"; do
    SUMMARY_KEYS+=("${item%%:*}")
  done

  create_or_reuse_cluster
  commit_changes || fail "commit_changes failed"
  activate_cluster
  run_pre_start_checks || exit 1
  print_summary
}

main "$@"
