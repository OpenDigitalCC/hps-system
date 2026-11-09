#!/usr/bin/env bats
#
# CS-3.1: node-manager/nixos-26/scripts/net-bridge-ensure and net-status, run
# against a stateful `ip` shim and a `curl` shim that serves the host key nets
# and the cluster key network_layout. Proves: VLAN sub-interface + bridge,
# untagged bridge (with and without a layout nic), idempotency, refusal of a
# network not in the layout BEFORE any ip change, no address ever configured,
# the networkd Unmanaged files, and that the boot NIC is never modified.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-bridge-ensure"
  STATUS="$ROOT/node-manager/nixos-26/scripts/net-status"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-01.XXXXXX")"
  mkdir -p "$T/bin" "$T/links" "$T/net"
  export T
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_NETWORK_DIR="$T/net"
  printf 'console=ttyS1 hps.ips=192.0.2.1 hps.mac=aa:bb:cc:00:00:01 hps.profile=CONVERGED\n' > "$T/cmdline"
  export HPS_CMDLINE="$T/cmdline"
  new_link eth0 aa:bb:cc:00:00:01 up
  new_link eth1 aa:bb:cc:00:00:02 down
  cat > "$T/layout" <<'JSON'
{
  "odoo": {"cidr": "10.40.0.0/24", "vlan": 40, "bridge": "br-odoo", "purpose": "workload"},
  "db":   {"cidr": "10.41.0.0/24", "vlan": 41, "bridge": "br-db",   "purpose": "storage"},
  "flat": {"cidr": "10.42.0.0/24", "vlan": null, "bridge": "br-flat", "purpose": "workload"},
  "phys": {"cidr": "10.43.0.0/24", "vlan": null, "bridge": "br-phys", "purpose": "workload", "nic": "aa:bb:cc:00:00:02"},
  "bad":  {"cidr": "10.44.0.0/24", "vlan": null, "bridge": "br-bad",  "purpose": "workload", "nic": "aa:bb:cc:00:00:01"}
}
JSON
  write_shims
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

# new_link <name> <mac> <up|down>
new_link() {
  mkdir -p "$T/links/$1"
  printf '%s' "$2" > "$T/links/$1/mac"
  printf '%s' "$3" > "$T/links/$1/state"
}

write_shims() {
  cat > "$T/bin/ip" <<'SHIM'
#!/usr/bin/env bash
L="$T/links"
echo "ip $*" >> "$SHIM_LOG"
emit() {
  local n="$1" d="$T/links/$1"
  jq -n --arg n "$n" --arg mac "$(cat "$d/mac" 2>/dev/null || true)" \
    --arg st "$(cat "$d/state" 2>/dev/null || echo down)" \
    --arg master "$(cat "$d/master" 2>/dev/null || true)" \
    --arg kind "$(cat "$d/kind" 2>/dev/null || true)" \
    --arg id "$(cat "$d/id" 2>/dev/null || true)" \
    --arg parent "$(cat "$d/parent" 2>/dev/null || true)" \
    --arg addr "$(cat "$d/addr" 2>/dev/null || true)" '
    {ifname: $n, flags: (["BROADCAST"] + (if $st == "up" then ["UP"] else [] end)),
     operstate: (if $st == "up" then "UP" else "DOWN" end)}
    + (if $mac != "" then {address: $mac} else {} end)
    + (if $master != "" then {master: $master} else {} end)
    + (if $parent != "" then {link: $parent} else {} end)
    + (if $kind != "" then {linkinfo: ({info_kind: $kind} + (if $id != "" then {info_data: {id: ($id|tonumber)}} else {} end))} else {} end)
    + {addr_info: (if $addr != "" then [{local: ($addr|split("/")[0]), prefixlen: 24}] else [] end)}'
}
if [[ "$1" == "-j" && "$2" == "route" ]]; then
  echo '[{"dst":"default","gateway":"192.0.2.1","dev":"eth0"}]'
  exit 0
fi
if [[ "$1" == "-j" ]]; then
  shift
  [[ "$1" == "-d" ]] && shift
  what="$1"; [[ "$2" == "show" ]] || exit 1
  shift 2
  if [[ "$1" == "dev" ]]; then
    [[ -d "$L/$2" ]] || { echo "Device \"$2\" does not exist." >&2; exit 1; }
    emit "$2" | jq -s .
    exit 0
  fi
  for d in "$L"/*; do emit "$(basename "$d")"; done | jq -s .
  exit 0
fi
[[ -z "${FAKE_IP_FAIL:-}" ]] || { echo "ip: fake failure" >&2; exit 1; }
if [[ "$1" == "link" && "$2" == "add" ]]; then
  shift 2
  parent=""
  if [[ "$1" == "link" ]]; then parent="$2"; shift 2; fi
  [[ "$1" == "name" ]] && shift
  name="$1"; shift
  mkdir -p "$L/$name"
  echo down > "$L/$name/state"
  [[ -z "$parent" ]] || echo "$parent" > "$L/$name/parent"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      type) echo "$2" > "$L/$name/kind"; shift 2 ;;
      id) echo "$2" > "$L/$name/id"; shift 2 ;;
      addrgenmode) echo "$2" > "$L/$name/addrgenmode"; shift 2 ;;
      *) shift ;;
    esac
  done
  exit 0
fi
if [[ "$1" == "link" && "$2" == "set" && "$3" == "dev" ]]; then
  dev="$4"; shift 4
  [[ -d "$L/$dev" ]] || exit 1
  case "$1" in
    master) echo "$2" > "$L/$dev/master" ;;
    up) echo up > "$L/$dev/state" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
echo "ip shim: unhandled: $*" >&2
exit 99
SHIM
  cat > "$T/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
url="${*: -1}"
[[ -z "${FAKE_CURL_RC:-}" ]] || exit "$FAKE_CURL_RC"
case "$url" in
  *cmd=host_variable\&name=nets)
    [[ -f "$T/nets" ]] || exit 22
    cat "$T/nets" ;;
  *cmd=cluster_variable\&name=network_layout)
    [[ -f "$T/layout" ]] || exit 22
    cat "$T/layout" ;;
  *) exit 22 ;;
esac
SHIM
  chmod +x "$T/bin/ip" "$T/bin/curl"
}

attach() {
  printf '%s' "$1" > "$T/nets"
}

ip_changes() {
  grep -E '^ip link (add|set)' "$SHIM_LOG" || true
}

@test "a VLAN network gets <bootnic>.<vlan> enslaved to its bridge, both up" {
  attach '["odoo"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/links/br-odoo/kind")" = "bridge" ]
  [ "$(cat "$T/links/br-odoo/state")" = "up" ]
  [ "$(cat "$T/links/eth0.40/kind")" = "vlan" ]
  [ "$(cat "$T/links/eth0.40/id")" = "40" ]
  [ "$(cat "$T/links/eth0.40/parent")" = "eth0" ]
  [ "$(cat "$T/links/eth0.40/master")" = "br-odoo" ]
  [ "$(cat "$T/links/eth0.40/state")" = "up" ]
  grep -q '^ip link add link eth0 name eth0.40 addrgenmode none type vlan id 40$' "$SHIM_LOG"
  [[ "$output" == *"network odoo: bridge br-odoo ready (vlan 40 on eth0)"* ]]
}

@test "two networks, given as a comma string, are both built" {
  attach 'odoo,db'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$T/links/br-odoo" ]
  [ -d "$T/links/br-db" ]
  [ "$(cat "$T/links/eth0.41/master")" = "br-db" ]
}

@test "a second run changes nothing (idempotent)" {
  attach '["odoo","flat","phys"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(ip_changes)" ]
}

@test "an untagged network is the bridge alone" {
  attach '["flat"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/links/br-flat/state")" = "up" ]
  [ ! -e "$T/links/eth0.0" ]
  [ ! -e "$T/links/br-flat/master" ]
  [ "$(ip_changes | grep -c 'link add')" -eq 1 ]
  ! grep -q 'master' "$SHIM_LOG"
}

@test "a layout nic joins the untagged bridge; the boot NIC does not" {
  attach '["phys"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/links/eth1/master")" = "br-phys" ]
  [ "$(cat "$T/links/eth1/state")" = "up" ]
  [ ! -e "$T/links/eth0/master" ]
}

@test "a layout nic that is the boot NIC is refused and nothing changes" {
  attach '["bad"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"boot NIC"* ]]
  [ -z "$(ip_changes)" ]
}

@test "a network not in the layout is refused before any change, even after valid ones" {
  attach '["odoo","nosuch"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"network 'nosuch' is not in the network layout"* ]]
  [ -z "$(ip_changes)" ]
  [ ! -e "$T/links/br-odoo" ]
  [ -z "$(ls "$T/net")" ]
}

@test "attached networks with no layout key are refused" {
  attach '["odoo"]'
  rm "$T/layout"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no network_layout"* ]]
  [ -z "$(ip_changes)" ]
}

@test "no host key nets: nothing to do, no layout read, no ip change" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no networks attached"* ]]
  ! grep -q 'network_layout' "$SHIM_LOG"
  [ -z "$(ip_changes)" ]
}

@test "an empty nets list does nothing" {
  attach '[]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(ip_changes)" ]
}

@test "an IPS that cannot be reached fails (exit 1), it is not read as 'none attached'" {
  FAKE_CURL_RC=7 run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$(ip_changes)" ]
}

@test "an interface already named like the bridge but not a bridge is refused" {
  attach '["odoo"]'
  mkdir -p "$T/links/br-odoo"
  echo dummy > "$T/links/br-odoo/kind"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a bridge"* ]]
}

@test "a sub-interface with the right name but another vlan id is refused" {
  attach '["odoo"]'
  mkdir -p "$T/links/eth0.40"
  echo vlan > "$T/links/eth0.40/kind"
  echo 99 > "$T/links/eth0.40/id"
  echo eth0 > "$T/links/eth0.40/parent"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not vlan 40 on eth0"* ]]
}

@test "a vlan sub-interface name longer than 15 characters is refused" {
  attach '["odoo"]'
  mv "$T/links/eth0" "$T/links/enp130s0f0np0"
  sed -i 's/ hps.mac=.*//' "$T/cmdline"
  printf 'hps.ips=192.0.2.1 hps.mac=aa:bb:cc:00:00:01\n' > "$T/cmdline"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"longer than the 15 characters"* ]]
  [ -z "$(ip_changes)" ]
}

@test "no address is ever configured, and the boot NIC is never changed" {
  attach '["odoo","db","flat","phys"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qE '^ip (-[a-z] )*addr' "$SHIM_LOG"
  ! grep -qE 'link set dev eth0 ' "$SHIM_LOG"
  ! grep -qE 'link (del|delete)' "$SHIM_LOG"
  for f in "$T"/links/*/addr; do [ ! -e "$f" ]; done
}

@test "every bridge and vlan is created with IPv6 link-local generation off" {
  attach '["odoo"]'
  run "$SCRIPT"
  [ "$(cat "$T/links/br-odoo/addrgenmode")" = "none" ]
  [ "$(cat "$T/links/eth0.40/addrgenmode")" = "none" ]
}

@test "networkd is told to leave the links alone: 05-hps-<bridge>.network, Unmanaged" {
  attach '["odoo","phys"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'Name=br-odoo eth0.40' "$T/net/05-hps-br-odoo.network"
  grep -qx 'Unmanaged=yes' "$T/net/05-hps-br-odoo.network"
  grep -qx 'Name=br-phys' "$T/net/05-hps-br-phys.network"
  grep -qx 'MACAddress=aa:bb:cc:00:00:02' "$T/net/05-hps-br-phys-nic.network"
  [ ! -e "$T/net/10-hps-boot.network" ]
  ls "$T/net" | grep -qv '\.netdev$'
}

@test "the files sort before hps-net's 10- and 99- files" {
  attach '["odoo"]'
  run "$SCRIPT"
  first=$(ls "$T/net" | head -n 1)
  [[ "$first" < "10-hps-boot.network" ]]
}

@test "networkctl reload runs only when a file changed" {
  printf '#!/usr/bin/env bash\necho "networkctl $*" >> "$SHIM_LOG"\n' > "$T/bin/networkctl"
  chmod +x "$T/bin/networkctl"
  attach '["odoo"]'
  run "$SCRIPT"
  grep -q '^networkctl reload$' "$SHIM_LOG"
  : > "$SHIM_LOG"
  run "$SCRIPT"
  ! grep -q '^networkctl' "$SHIM_LOG"
}

@test "every ip command is logged as it runs" {
  attach '["odoo"]'
  run "$SCRIPT"
  [[ "$output" == *"+ ip link add name br-odoo addrgenmode none type bridge"* ]]
  [[ "$output" == *"+ ip link set dev eth0.40 master br-odoo"* ]]
}

@test "arguments are refused" {
  run "$SCRIPT" now
  [ "$status" -eq 2 ]
}

@test "hps.mac missing from the command line is refused (the boot NIC is unknown)" {
  attach '["odoo"]'
  printf 'hps.ips=192.0.2.1\n' > "$T/cmdline"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"hps.mac"* ]]
  [ -z "$(ip_changes)" ]
}

@test "net-status lists bridges with members, vlans with parent, and addresses" {
  attach '["odoo","phys"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bridge br-odoo state UP members: eth0.40"* ]]
  [[ "$output" == *"bridge br-phys state UP members: eth1"* ]]
  [[ "$output" == *"vlan eth0.40 id 40 parent eth0 bridge br-odoo state UP"* ]]
  [[ "$output" == *"=== addresses on bridges and vlans ==="*"none"* ]]
}

@test "net-status shows an address that should not be there" {
  attach '["odoo"]'
  run "$SCRIPT"
  echo 10.40.0.9/24 > "$T/links/br-odoo/addr"
  run "$STATUS"
  [[ "$output" == *"br-odoo: 10.40.0.9/24"* ]]
}

@test "net-status with nothing built says none and takes no arguments" {
  run "$STATUS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== bridges ==="*"none"* ]]
  run "$STATUS" x
  [ "$status" -eq 2 ]
}
