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
#       [--static-range <start>-<end>] [--reserve <ip>[,<ip>...]] \
#       [--description <s>] [--storage-network <cidr>] \
#       [--network-add <name>:<cidr>[:vlan=<id>][:bridge=<br>][:purpose=workload|storage][:nic=<mac>]]... \
#       [--time-upstream "<servers>"] [--force]
#
# Static addresses: hosts assigned by hps-onboard get their address from the
# static pool, cluster keys network_static_start/_end, never from the DHCP
# range and never next to the IPS. Default pool: from the IPS address + 9 up to
# the DHCP range start - 1 (IPS .1 and DHCP .100-.199 in a /24 give .10-.99).
# network_reserved lists addresses the allocator must skip (--reserve), such
# as one an outside device already uses on the cluster network.
#
# Network layout: --network-add (repeatable) defines a workload or storage
# network. The implicit 'provisioning' network is the --network above and is
# already configured. All additions are written as ONE JSON cluster key,
# network_layout: {"<name>": {"cidr":..., "vlan":<id>|null, "bridge":...,
# "purpose":"workload"|"storage", "nic":<mac> (optional)}}. Nodes build the
# bridges for the networks attached to them (net-bridge-ensure); HPS never
# configures a switch. Names ^[a-z][a-z0-9-]*$, VLAN ids 1-4094 and bridge
# names unique, no CIDR overlapping another or --network/--storage-network.
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
ARG_STATIC=""
ARG_RESERVE=""
ARG_FORCE=0
ARG_NETS=()
LAYOUT_JSON=""

# Filled by validation
RANGE_START=""
RANGE_END=""
STATIC_START=""
STATIC_END=""
RESERVED=""
NET_CIDR=""
NET_PREFIX=""
NET_LO=0
NET_HI=0

usage() {
  cat <<'EOF'
Usage: cluster-bootstrap.sh --name <cluster> --dhcp-iface <if> --network <cidr>
         --ips-ip <ip> --dhcp-range <start>-<end> [--dns-domain <d>]
         [--static-range <start>-<end>] [--reserve <ip>[,<ip>...]]
         [--description <s>] [--storage-network <cidr>]
         [--network-add <name>:<cidr>[:vlan=<id>][:bridge=<br>][:purpose=workload|storage][:nic=<mac>]]...
         [--time-upstream "<servers>"] [--force]

  --name             cluster name (DNS label: letters, digits, hyphens)
  --dhcp-iface       interface dnsmasq answers on (syntax checked only)
  --network          cluster network, network address form (A.B.C.0/N)
  --ips-ip           IPS address, inside --network
  --dhcp-range       first and last lease address, inside --network, not
                     containing --ips-ip
  --static-range     pool for static host addresses (cluster keys
                     network_static_start/_end): inside --network, not
                     overlapping --dhcp-range, not containing --ips-ip.
                     Default: from --ips-ip + 9 up to the --dhcp-range start
                     - 1 (10.100.1.0/24, IPS .1, DHCP .100-.199 gives
                     .10-.99); refused when that is empty
  --reserve          addresses the allocator must skip, comma separated,
                     inside --network (cluster key network_reserved,
                     space separated); default none
  --dns-domain       default cluster.local
  --description      default: the cluster name
  --storage-network  optional, A.B.0.0/N (N 16-28), one storage network
  --network-add      repeatable. A workload/storage network for the network
                     layout (cluster key network_layout, one JSON object):
                     <name>:<cidr>[:vlan=<id>][:bridge=<br>][:purpose=...]
                     [:nic=<mac>]. name ^[a-z][a-z0-9-]*$ (not 'provisioning',
                     the implicit network of --network); cidr in network-address
                     form (prefix 8-30); vlan 1-4094; bridge default br-<name>
                     (max 15 characters); purpose workload (default) or storage;
                     nic: a physical NIC the untagged bridge takes (no vlan).
                     VLAN ids and bridge names are unique; no CIDR overlaps
                     --network, --storage-network or another addition.
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
      --static-range)    ARG_STATIC="${2:?--static-range needs a value}"; shift 2 ;;
      --reserve)         ARG_RESERVE="${2:?--reserve needs a value}"; shift 2 ;;
      --dns-domain)      ARG_DOMAIN="${2:?--dns-domain needs a value}"; shift 2 ;;
      --description)     ARG_DESC="${2:?--description needs a value}"; shift 2 ;;
      --storage-network) ARG_STORAGE="${2:?--storage-network needs a value}"; shift 2 ;;
      --network-add)     ARG_NETS+=("${2:?--network-add needs a value}"); shift 2 ;;
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

# Static pool: explicit, or derived from the IPS address and the DHCP range.
validate_static() {
  local s e ips ds de
  ips=$(ipv4_to_int "$ARG_IPS_IP")
  ds=$(ipv4_to_int "$RANGE_START")
  de=$(ipv4_to_int "$RANGE_END")
  if [[ -n "$ARG_STATIC" ]]; then
    [[ "$ARG_STATIC" =~ ^([0-9.]+)-([0-9.]+)$ ]] \
      || fail "invalid --static-range '$ARG_STATIC': expected <start>-<end>"
    STATIC_START="${BASH_REMATCH[1]}"
    STATIC_END="${BASH_REMATCH[2]}"
    valid_ipv4 "$STATIC_START" || fail "invalid static range start '$STATIC_START'"
    valid_ipv4 "$STATIC_END"   || fail "invalid static range end '$STATIC_END'"
  else
    s=$(( ips + 9 ))
    e=$(( ds - 1 ))
    (( s <= e && e <= NET_HI )) \
      || fail "no default static range: IPS + 9 up to the DHCP range start - 1 is empty; give --static-range"
    STATIC_START=$(int_to_ipv4 "$s")
    STATIC_END=$(int_to_ipv4 "$e")
  fi
  in_network "$STATIC_START" || fail "static range start $STATIC_START is not inside $NET_CIDR"
  in_network "$STATIC_END"   || fail "static range end $STATIC_END is not inside $NET_CIDR"
  s=$(ipv4_to_int "$STATIC_START")
  e=$(ipv4_to_int "$STATIC_END")
  (( s <= e )) || fail "static range start $STATIC_START is after static range end $STATIC_END"
  if (( ips >= s && ips <= e )); then
    fail "static range $STATIC_START-$STATIC_END contains the IPS address $ARG_IPS_IP"
  fi
  if (( s <= de && ds <= e )); then
    fail "static range $STATIC_START-$STATIC_END overlaps --dhcp-range $ARG_RANGE"
  fi
}

# Reserved addresses: valid host addresses of the cluster network.
validate_reserve() {
  local ip
  local -a items
  RESERVED=""
  [[ -z "$ARG_RESERVE" ]] && return 0
  IFS=, read -r -a items <<< "$ARG_RESERVE"
  for ip in "${items[@]}"; do
    valid_ipv4 "$ip" || fail "invalid --reserve entry '$ip'"
    in_network "$ip" || fail "--reserve $ip is not inside $NET_CIDR"
    RESERVED="${RESERVED:+$RESERVED }$ip"
  done
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

# Split a --network-add spec on ":" into name, cidr and key=value fields. A
# nic MAC contains colons, so a piece without "=" belongs to the previous field.
# Sets NA_NAME, NA_CIDR and the NA_FIELDS array of "key=value".
split_network_spec() {
  local spec="$1" piece i
  local -a parts
  NA_FIELDS=()
  IFS=: read -r -a parts <<< "$spec"
  NA_NAME="${parts[0]:-}"
  NA_CIDR="${parts[1]:-}"
  for (( i = 2; i < ${#parts[@]}; i++ )); do
    piece="${parts[$i]}"
    if [[ "$piece" == *=* ]]; then
      NA_FIELDS+=("$piece")
    elif (( ${#NA_FIELDS[@]} > 0 )); then
      NA_FIELDS[${#NA_FIELDS[@]}-1]+=":$piece"
    else
      fail "invalid --network-add '$spec': '$piece' is not key=value"
    fi
  done
}

# nic=<mac> to aa:bb:cc:dd:ee:ff, or fail.
normalise_nic() {
  local raw="${1//[:-]/}"
  raw="${raw,,}"
  [[ "$raw" =~ ^[0-9a-f]{12}$ ]] || return 1
  printf '%s:%s:%s:%s:%s:%s\n' "${raw:0:2}" "${raw:2:2}" "${raw:4:2}" \
    "${raw:6:2}" "${raw:8:2}" "${raw:10:2}"
}

# Validate one --network-add spec; on success append it to LAYOUT_JSON and its
# range to the overlap lists. Arguments: spec. Uses the SEEN_* state.
validate_one_network() {
  local spec="$1" field key val bounds lo hi
  local vlan="" bridge="" purpose="workload" nic="" vlan_given=0
  split_network_spec "$spec"
  [[ "$NA_NAME" =~ ^[a-z][a-z0-9-]*$ ]] \
    || fail "invalid --network-add name '$NA_NAME' in '$spec': ^[a-z][a-z0-9-]*\$"
  [[ "$NA_NAME" != provisioning ]] \
    || fail "--network-add name 'provisioning' is the implicit network (--network); choose another"
  [[ -z "${SEEN_NAME[$NA_NAME]:-}" ]] || fail "--network-add '$NA_NAME' given twice"
  bounds=$(cidr_bounds "$NA_CIDR" 8 30) \
    || fail "invalid cidr '$NA_CIDR' for network '$NA_NAME': expected network-address CIDR (prefix 8-30, host bits zero)"
  read -r lo hi _ <<< "$bounds"
  for field in "${NA_FIELDS[@]}"; do
    key="${field%%=*}"
    val="${field#*=}"
    case "$key" in
      vlan)    vlan="$val"; vlan_given=1 ;;
      bridge)  bridge="$val" ;;
      purpose) purpose="$val" ;;
      nic)     nic="$val" ;;
      *)       fail "network '$NA_NAME': unknown field '$key' (vlan, bridge, purpose, nic)" ;;
    esac
  done
  if (( vlan_given == 1 )); then
    [[ "$vlan" =~ ^[1-9][0-9]{0,3}$ ]] \
      || fail "network '$NA_NAME': vlan '$vlan' is not an id from 1 to 4094"
    (( vlan <= 4094 )) || fail "network '$NA_NAME': vlan '$vlan' is not an id from 1 to 4094"
    [[ -z "${SEEN_VLAN[$vlan]:-}" ]] \
      || fail "network '$NA_NAME': vlan $vlan is already used by '${SEEN_VLAN[$vlan]}'"
  fi
  [[ -n "$bridge" ]] || bridge="br-$NA_NAME"
  [[ "$bridge" =~ ^[a-z][a-z0-9-]{0,14}$ ]] \
    || fail "network '$NA_NAME': bridge '$bridge' is not a valid name (^[a-z][a-z0-9-]{0,14}\$; give bridge= for a long network name)"
  [[ -z "${SEEN_BRIDGE[$bridge]:-}" ]] \
    || fail "network '$NA_NAME': bridge '$bridge' is already used by '${SEEN_BRIDGE[$bridge]}'"
  [[ "$purpose" == workload || "$purpose" == storage ]] \
    || fail "network '$NA_NAME': purpose '$purpose' is not workload or storage"
  if [[ -n "$nic" ]]; then
    [[ -z "$vlan" ]] || fail "network '$NA_NAME': nic and vlan are exclusive (a nic joins an untagged bridge)"
    nic=$(normalise_nic "$nic") || fail "network '$NA_NAME': nic is not a MAC address"
  fi
  if (( lo <= NET_HI && NET_LO <= hi )); then
    fail "network '$NA_NAME' $NA_CIDR overlaps the provisioning network $NET_CIDR"
  fi
  if [[ -n "$ARG_STORAGE" ]]; then
    local slo shi
    read -r slo shi _ <<< "$(cidr_bounds "$ARG_STORAGE" 16 28)"
    if (( lo <= shi && slo <= hi )); then
      fail "network '$NA_NAME' $NA_CIDR overlaps --storage-network $ARG_STORAGE"
    fi
  fi
  local other
  for other in "${!SEEN_RANGE[@]}"; do
    if (( lo <= ${SEEN_RANGE[$other]#*-} && ${SEEN_RANGE[$other]%-*} <= hi )); then
      fail "network '$NA_NAME' $NA_CIDR overlaps network '$other'"
    fi
  done
  SEEN_NAME[$NA_NAME]=1
  SEEN_BRIDGE[$bridge]="$NA_NAME"
  [[ -z "$vlan" ]] || SEEN_VLAN[$vlan]="$NA_NAME"
  SEEN_RANGE[$NA_NAME]="$lo-$hi"
  LAYOUT_JSON=$(jq -c --arg n "$NA_NAME" --arg c "$NA_CIDR" --argjson v "${vlan:-null}" \
    --arg b "$bridge" --arg p "$purpose" --arg nic "$nic" \
    '. + {($n): ({cidr: $c, vlan: $v, bridge: $b, purpose: $p} + (if $nic == "" then {} else {nic: $nic} end))}' \
    <<< "$LAYOUT_JSON") || fail "cannot build the network layout JSON"
}

validate_networks() {
  local spec
  declare -A SEEN_NAME=() SEEN_VLAN=() SEEN_BRIDGE=() SEEN_RANGE=()
  [[ ${#ARG_NETS[@]} -gt 0 ]] || return 0
  command -v jq > /dev/null 2>&1 || fail "--network-add needs jq"
  LAYOUT_JSON="{}"
  for spec in "${ARG_NETS[@]}"; do
    validate_one_network "$spec"
  done
}

validate_args() {
  validate_name
  validate_iface
  validate_domain
  validate_description
  validate_network
  validate_ips_ip
  validate_range
  validate_static
  validate_reserve
  validate_storage
  validate_networks
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
  CLUSTER_CONFIG_PENDING+=("network_static_start:$STATIC_START")
  CLUSTER_CONFIG_PENDING+=("network_static_end:$STATIC_END")
  CLUSTER_CONFIG_PENDING+=("network_reserved:$RESERVED")
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

# network_layout is one JSON key written after commit_changes (which handles
# "key:value" strings, not JSON objects). --force without --network-add drops a
# stale layout, as clear_storage_keys drops stale storage keys.
write_network_layout() {
  if [[ -n "$LAYOUT_JSON" ]]; then
    hps_log info "bootstrap: set network_layout (cluster $ARG_NAME)"
    cluster_registry "$ARG_NAME" set network_layout "$LAYOUT_JSON" \
      || fail "cannot write network_layout"
    return 0
  fi
  if cluster_registry "$ARG_NAME" exists network_layout > /dev/null 2>&1; then
    hps_log info "bootstrap: delete network_layout (cluster $ARG_NAME)"
    cluster_registry "$ARG_NAME" delete network_layout
  fi
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
  [[ -z "$LAYOUT_JSON" ]] || SUMMARY_KEYS+=(network_layout)

  create_or_reuse_cluster
  commit_changes || fail "commit_changes failed"
  write_network_layout
  activate_cluster
  run_pre_start_checks || exit 1
  print_summary
}

main "$@"
