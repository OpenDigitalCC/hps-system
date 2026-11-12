#!/usr/bin/env bats
#
# Scale test phase 1: net-bridge-ensure builds a fabric network ("kind":
# "fabric", purpose emulated-switch) as an emulated switch: a VLAN-aware bridge,
# no member NIC, no address, the layout MTU (default 9000), the bridge's own port
# out of VLAN 1. Stateful `ip` and `bridge` shims; curl serves the layout.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-bridge-ensure"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-166.XXXXXX")"
  mkdir -p "$T/bin" "$T/links" "$T/net" "$T/vlans"
  export T
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_NETWORK_DIR="$T/net"
  printf 'console=ttyS1 hps.ips=192.0.2.1 hps.mac=aa:bb:cc:00:00:01 hps.profile=CONVERGED\n' > "$T/cmdline"
  export HPS_CMDLINE="$T/cmdline"
  mkdir -p "$T/links/eth0"
  printf 'aa:bb:cc:00:00:01' > "$T/links/eth0/mac"
  printf 'up' > "$T/links/eth0/state"
  printf '1500' > "$T/links/eth0/mtu"
  cat > "$T/layout" <<'JSON'
{
  "fab":   {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-fab"},
  "fab2":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-fab2", "mtu": 1600},
  "odoo":  {"cidr": "10.40.0.0/24", "vlan": 40, "bridge": "br-odoo", "purpose": "workload"},
  "client": {"kind": "vxlan", "vni": 1100, "over": "transit", "bridge": "br-client", "purpose": "workload"},
  "bad1":  {"kind": "fabric", "purpose": "workload", "bridge": "br-bad1"},
  "bad2":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-bad2", "vlan": 5},
  "bad3":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-bad3", "uplink": "boot"},
  "bad4":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-bad4", "nic": "aa:bb:cc:00:00:02"},
  "bad5":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-bad5", "mtu": 100},
  "bad6":  {"kind": "fabric", "purpose": "emulated-switch", "bridge": "br-bad6", "mtu": "big"},
  "bad7":  {"kind": "switch", "purpose": "emulated-switch", "bridge": "br-bad7"},
  "bad8":  {"purpose": "emulated-switch", "cidr": "10.1.0.0/24", "bridge": "br-bad8"},
  "bad9":  {"purpose": "workload", "cidr": "10.1.0.0/24", "bridge": "br-bad9", "mtu": 9000}
}
JSON
  write_shims
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
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
    --arg kind "$(cat "$d/kind" 2>/dev/null || true)" \
    --arg mtu "$(cat "$d/mtu" 2>/dev/null || echo 1500)" \
    --arg vf "$(cat "$d/vlanf" 2>/dev/null || echo 0)" \
    --arg master "$(cat "$d/master" 2>/dev/null || true)" \
    --arg id "$(cat "$d/id" 2>/dev/null || true)" \
    --arg parent "$(cat "$d/parent" 2>/dev/null || true)" '
    {ifname: $n, mtu: ($mtu|tonumber), flags: (["BROADCAST"] + (if $st == "up" then ["UP"] else [] end))}
    + (if $mac != "" then {address: $mac} else {} end)
    + (if $master != "" then {master: $master} else {} end)
    + (if $parent != "" then {link: $parent} else {} end)
    + (if $kind != "" then {linkinfo: ({info_kind: $kind}
        + (if $kind == "bridge" then {info_data: {vlan_filtering: ($vf|tonumber)}} else {} end)
        + (if $id != "" then {info_data: {id: ($id|tonumber)}} else {} end))} else {} end)'
}
if [[ "$1" == "-j" && "$2" == "route" ]]; then
  echo '[{"dst":"default","gateway":"192.0.2.1","dev":"eth0"}]'
  exit 0
fi
if [[ "$1" == "-j" ]]; then
  shift
  [[ "$1" == "-d" ]] && shift
  [[ "$2" == "show" ]] || exit 1
  shift 2
  if [[ "$1" == "dev" ]]; then
    [[ -d "$L/$2" ]] || { echo "Device \"$2\" does not exist." >&2; exit 1; }
    emit "$2" | jq -s .
    exit 0
  fi
  for d in "$L"/*; do emit "$(basename "$d")"; done | jq -s .
  exit 0
fi
if [[ "$1" == "link" && "$2" == "add" ]]; then
  shift 2
  parent=""
  if [[ "$1" == "link" ]]; then parent="$2"; shift 2; fi
  [[ "$1" == "name" ]] && shift
  name="$1"; shift
  mkdir -p "$L/$name"
  [[ -z "$parent" ]] || echo "$parent" > "$L/$name/parent"
  echo down > "$L/$name/state"
  echo 1500 > "$L/$name/mtu"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      type) echo "$2" > "$L/$name/kind"; shift 2 ;;
      vlan_filtering) echo "$2" > "$L/$name/vlanf"; shift 2 ;;
      id) echo "$2" > "$L/$name/id"; shift 2 ;;
      addrgenmode) echo "$2" > "$L/$name/addrgenmode"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "$(cat "$L/$name/kind")" == bridge && "$(cat "$L/$name/vlanf" 2>/dev/null || echo 0)" == 1 ]]; then
    printf '%s 1 PVID Egress Untagged\n' "$name" > "$T/vlans/$name"
  fi
  exit 0
fi
if [[ "$1" == "link" && "$2" == "set" && "$3" == "dev" ]]; then
  dev="$4"; shift 4
  [[ -d "$L/$dev" ]] || exit 1
  case "$1" in
    up) echo up > "$L/$dev/state" ;;
    master) echo "$2" > "$L/$dev/master" ;;
    addrgenmode) echo "$2" > "$L/$dev/addrgenmode" ;;
    mtu) echo "$2" > "$L/$dev/mtu" ;;
    type) [[ "$2" == bridge && "$3" == vlan_filtering ]] || exit 1; echo "$4" > "$L/$dev/vlanf"
          [[ "$4" != 1 ]] || printf '%s 1 PVID Egress Untagged\n' "$dev" > "$T/vlans/$dev" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
echo "ip shim: unhandled: $*" >&2
exit 99
SHIM
  cat > "$T/bin/bridge" <<'SHIM'
#!/usr/bin/env bash
echo "bridge $*" >> "$SHIM_LOG"
if [[ "$1" == "vlan" && "$2" == "show" && "$3" == "dev" ]]; then
  [[ -s "$T/vlans/$4" ]] || exit 0
  printf 'port              vlan-id\n'
  cat "$T/vlans/$4"
  exit 0
fi
if [[ "$1" == "vlan" && "$2" == "del" && "$3" == "dev" && "$5" == "vid" && "$7" == "self" ]]; then
  : > "$T/vlans/$4"
  exit 0
fi
echo "bridge shim: unhandled: $*" >&2
exit 99
SHIM
  cat > "$T/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
url="${*: -1}"
case "$url" in
  *cmd=host_variable\&name=nets) cat "$T/nets" ;;
  *cmd=cluster_variable\&name=network_layout) cat "$T/layout" ;;
  *) exit 22 ;;
esac
SHIM
  chmod +x "$T/bin/ip" "$T/bin/bridge" "$T/bin/curl"
}

attach() {
  printf '%s' "$1" > "$T/nets"
}

changes() {
  grep -E '^(ip link (add|set)|bridge vlan (add|del))' "$SHIM_LOG" || true
}

@test "a fabric network is a VLAN-aware bridge: vlan_filtering 1, no address, addrgenmode none" {
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^ip link add name br-fab type bridge vlan_filtering 1$' "$SHIM_LOG"
  grep -q '^ip link set dev br-fab addrgenmode none$' "$SHIM_LOG"
  [ "$(cat "$T/links/br-fab/kind")" = "bridge" ]
  [ "$(cat "$T/links/br-fab/vlanf")" = "1" ]
  [ "$(cat "$T/links/br-fab/state")" = "up" ]
  [[ "$output" == *"network fab: bridge br-fab ready (fabric, vlan_filtering, mtu 9000)"* ]]
  run ! grep -E 'addr add|master|link add link' "$SHIM_LOG"
}

@test "the default MTU is 9000 and the layout mtu overrides it" {
  attach '["fab","fab2"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/links/br-fab/mtu")" = "9000" ]
  [ "$(cat "$T/links/br-fab2/mtu")" = "1600" ]
  grep -q '^ip link set dev br-fab mtu 9000$' "$SHIM_LOG"
  grep -q '^ip link set dev br-fab2 mtu 1600$' "$SHIM_LOG"
}

@test "the bridge's own port is taken out of VLAN 1" {
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^bridge vlan del dev br-fab vid 1 self$' "$SHIM_LOG"
  [ ! -s "$T/vlans/br-fab" ]
}

@test "no member NIC: the boot NIC and any other link is untouched" {
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$T/links/eth0/master" ]
  run ! grep -E '^ip link set dev eth0' "$SHIM_LOG"
  run ! grep -E 'link add link' "$SHIM_LOG"
}

@test "the bridge is unmanaged by networkd" {
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'Name=br-fab' "$T/net/05-hps-br-fab.network"
  grep -qx 'Unmanaged=yes' "$T/net/05-hps-br-fab.network"
}

@test "a second run changes nothing (idempotent)" {
  attach '["fab","fab2","odoo"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(changes | grep -v 'link show')" ]
}

@test "an existing bridge without vlan_filtering or the MTU is brought to it" {
  mkdir -p "$T/links/br-fab"
  printf 'bridge' > "$T/links/br-fab/kind"
  printf 'up' > "$T/links/br-fab/state"
  printf '1500' > "$T/links/br-fab/mtu"
  printf '0' > "$T/links/br-fab/vlanf"
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^ip link set dev br-fab type bridge vlan_filtering 1$' "$SHIM_LOG"
  grep -q '^ip link set dev br-fab mtu 9000$' "$SHIM_LOG"
  run ! grep -q '^ip link add' "$SHIM_LOG"
}

@test "an existing link that is not a bridge is refused (3)" {
  mkdir -p "$T/links/br-fab"
  printf 'dummy' > "$T/links/br-fab/kind"
  attach '["fab"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a bridge"* ]]
}

@test "a fabric network next to a VLAN network: both built" {
  attach '["fab","odoo"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/links/br-fab/vlanf")" = "1" ]
  [ "$(cat "$T/links/eth0.40/master")" = "br-odoo" ]
}

@test "refused (3), nothing changed: wrong purpose, vlan, uplink, nic, mtu range, mtu text, kind, kind missing, mtu on a plain network" {
  for n in bad1 bad2 bad3 bad4 bad5 bad6 bad7 bad8 bad9; do
    attach "[\"$n\"]"
    run "$SCRIPT"
    [ "$status" -eq 3 ]
    [ -z "$(changes)" ]
  done
}

@test "refusal text names the problem" {
  attach '["bad2"]'
  run "$SCRIPT"
  [[ "$output" == *"a fabric network takes no vlan, nic or uplink"* ]]
  attach '["bad5"]'
  run "$SCRIPT"
  [[ "$output" == *"mtu '100' is not 576-9216"* ]]
  attach '["bad1"]'
  run "$SCRIPT"
  [[ "$output" == *"purpose emulated-switch"* ]]
}

@test "a vxlan network is skipped: net-vxlan-ensure builds it, nothing is made here" {
  attach '["client","odoo"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"network client: vxlan, skipped (net-vxlan-ensure builds bridge br-client)"* ]]
  [ ! -e "$T/links/br-client" ]
  [ ! -e "$T/net/05-hps-br-client.network" ]
  [ "$(cat "$T/links/eth0.40/master")" = "br-odoo" ]
}
