#!/usr/bin/env bats
#
# CS-3.12a: net-bridge-ensure treats a layout network with uplink=boot (the
# bridge hps-net builds on the boot NIC) as already ensured: it checks the
# bridge exists and never touches its members, address or networkd files.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-bridge-ensure"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-81.XXXXXX")"
  mkdir -p "$T/bin" "$T/links" "$T/net"
  export T
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_NETWORK_DIR="$T/net"
  printf 'console=ttyS1 hps.ips=192.0.2.1 hps.mac=aa:bb:cc:00:00:01 hps.profile=CONVERGED hps.bridge=br-prov\n' > "$T/cmdline"
  export HPS_CMDLINE="$T/cmdline"
  cat > "$T/layout" <<'JSON'
{
  "prov": {"cidr": "10.100.1.0/24", "vlan": null, "bridge": "br-prov", "purpose": "provisioning", "uplink": "boot"},
  "flat": {"cidr": "10.42.0.0/24", "vlan": null, "bridge": "br-flat", "purpose": "workload"},
  "p2":   {"cidr": "10.45.0.0/24", "vlan": null, "bridge": "br-p2", "purpose": "provisioning"},
  "pv":   {"cidr": "10.46.0.0/24", "vlan": 46, "bridge": "br-pv", "purpose": "provisioning", "uplink": "boot"},
  "wb":   {"cidr": "10.47.0.0/24", "vlan": null, "bridge": "br-wb", "purpose": "workload", "uplink": "boot"}
}
JSON
  new_link eth0 "" "" up
  # hps-net's work: the bridge, with the boot NIC as its member and an address.
  new_link br-prov aa:bb:cc:00:00:01 bridge up
  echo br-prov > "$T/links/eth0/master"
  echo 10.100.1.55/24 > "$T/links/br-prov/addr"
  printf 'aa:bb:cc:00:00:01' > "$T/links/eth0/mac"
  write_shims
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

new_link() {
  mkdir -p "$T/links/$1"
  printf '%s' "$2" > "$T/links/$1/mac"
  [[ -z "$3" ]] || printf '%s' "$3" > "$T/links/$1/kind"
  printf '%s' "$4" > "$T/links/$1/state"
}

write_shims() {
  cat > "$T/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
emit() {
  local n="$1" d="$T/links/$1"
  jq -n --arg n "$n" --arg mac "$(cat "$d/mac" 2>/dev/null || true)" \
    --arg st "$(cat "$d/state" 2>/dev/null || echo down)" \
    --arg master "$(cat "$d/master" 2>/dev/null || true)" \
    --arg kind "$(cat "$d/kind" 2>/dev/null || true)" \
    '{ifname:$n, address:$mac, flags:(if $st=="up" then ["UP"] else [] end),
      master:(if $master=="" then null else $master end),
      linkinfo:(if $kind=="" then {} else {info_kind:$kind} end)}'
}
if [[ "$1" == "-j" && "$2" == "link" && "$3" == "show" ]]; then
  list=()
  for d in "$T"/links/*; do list+=("$(emit "${d##*/}")"); done
  printf '%s\n' "${list[@]}" | jq -s '.'
  exit 0
fi
if [[ "$1" == "-j" && "$2" == "-d" && "$3" == "link" && "$4" == "show" && "$5" == "dev" ]]; then
  [[ -d "$T/links/$6" ]] || exit 1
  emit "$6" | jq -s '.'
  exit 0
fi
if [[ "$1" == "link" && "$2" == "add" && "$3" == "name" ]]; then
  mkdir -p "$T/links/$4"
  echo bridge > "$T/links/$4/kind"
  echo down > "$T/links/$4/state"
  exit 0
fi
if [[ "$1" == "link" && "$2" == "set" && "$3" == "dev" && "$5" == "up" ]]; then
  echo up > "$T/links/$4/state"
  exit 0
fi
if [[ "$1" == "link" && "$2" == "set" && "$3" == "dev" && "$5" == "addrgenmode" ]]; then
  exit 0
fi
echo "ip shim: unhandled (a change?): $*" >&2
exit 99
SHIM
  cat > "$T/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
url="${*: -1}"
case "$url" in
  *cmd=host_variable\&name=nets) [[ -f "$T/nets" ]] || exit 22; cat "$T/nets" ;;
  *cmd=cluster_variable\&name=network_layout) cat "$T/layout" ;;
  *) exit 22 ;;
esac
SHIM
  chmod +x "$T/bin/ip" "$T/bin/curl"
}

attach() {
  printf '%s' "$1" > "$T/nets"
}

@test "an uplink=boot network: the bridge exists, reported ready, and no ip command changes anything" {
  attach '["prov"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"network prov: bridge br-prov ready (boot NIC bridge, made by hps-net)"* ]]
  run ! grep -E '^ip (-[a-z] )*(link (add|set|del)|addr|route)' "$SHIM_LOG"
}

@test "no networkd file is written for it (hps-net owns the bridge's units)" {
  attach '["prov"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(ls "$T/net")" ]
}

@test "members and address are left as they are" {
  attach '["prov"]'
  run "$SCRIPT"
  [ "$(cat "$T/links/eth0/master")" = "br-prov" ]
  [ "$(cat "$T/links/br-prov/addr")" = "10.100.1.55/24" ]
}

@test "a missing bridge is refused (3), naming hps-net and the boot_bridge key" {
  attach '["prov"]'
  rm -r "$T/links/br-prov"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"boot bridge br-prov does not exist"* ]]
  [[ "$output" == *"boot_bridge"* ]]
}

@test "an interface of that name that is not a bridge is refused (3)" {
  attach '["prov"]'
  echo dummy > "$T/links/br-prov/kind"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a bridge"* ]]
}

@test "mixed with a workload network: only the workload bridge is built" {
  attach '["prov","flat"]'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^ip link add name br-flat type bridge$' "$SHIM_LOG"
  grep -q '^ip link set dev br-flat addrgenmode none$' "$SHIM_LOG"
  run ! grep -E "^ip link (add|set).*br-prov" "$SHIM_LOG"
  [ -f "$T/net/05-hps-br-flat.network" ]
  [ ! -e "$T/net/05-hps-br-prov.network" ]
}

@test "purpose provisioning without uplink boot is still refused (3)" {
  attach '["p2"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"purpose 'provisioning' is not workload or storage"* ]]
}

@test "uplink boot with a vlan is refused (3)" {
  attach '["pv"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"takes no vlan and no nic"* ]]
}

@test "uplink boot on a workload network is refused (3)" {
  attach '["wb"]'
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"only for purpose provisioning"* ]]
}

@test "the boot NIC is still never enslaved by a layout nic" {
  attach '["flat"]'
  jq '.flat.nic = "aa:bb:cc:00:00:01"' "$T/layout" > "$T/layout.new"
  mv "$T/layout.new" "$T/layout"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"boot NIC"* ]]
}
