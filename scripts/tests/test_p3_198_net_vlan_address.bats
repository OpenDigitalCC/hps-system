#!/usr/bin/env bats
#
# Scale test phase 2: net-vlan-address gives a node an address on a tagged VLAN
# (storage A/B, transit) through a systemd-networkd .network file, the VLAN
# link made with `ip link add` after networkd has the file. Stateful `ip` and
# `networkctl` shims: links under $T/links/<name>/ (mac, kind, id, parent,
# master, mtu, addrs); networkctl reload/reconfigure (and ip link add) apply the
# 05-hps-vlan-*.network files the way networkd would, unless FAKE_NETWORKD=dead.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-vlan-address"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-198.XXXXXX")"
  mkdir -p "$T/bin" "$T/links" "$T/net"
  export T
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_NETWORK_DIR="$T/net"
  export HPS_NET_WAIT=1
  export HPS_NET_STEP=0.1
  printf 'console=ttyS1 hps.ips=10.11.0.1 hps.mac=52:54:00:00:01:53 hps.profile=STORAGE\n' > "$T/cmdline"
  export HPS_CMDLINE="$T/cmdline"
  mklink eth0 52:54:00:00:01:53 1500
  mklink eth1 52:54:00:00:02:53 1500
  write_shims
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

# mklink <name> <mac> <mtu> [kind] [id] [parent] [master]
mklink() {
  local d="$T/links/$1"
  mkdir -p "$d"
  printf '%s' "$2" > "$d/mac"
  printf '%s' "$3" > "$d/mtu"
  [[ -z "${4:-}" ]] || printf '%s' "$4" > "$d/kind"
  [[ -z "${5:-}" ]] || printf '%s' "$5" > "$d/id"
  [[ -z "${6:-}" ]] || printf '%s' "$6" > "$d/parent"
  [[ -z "${7:-}" ]] || printf '%s' "$7" > "$d/master"
  : >> "$d/addrs"
}

write_shims() {
  cat > "$T/bin/fake-networkd-apply" <<'SHIM'
#!/usr/bin/env bash
# fake-networkd-apply <link>: what networkd does with a 05-hps-vlan file.
[[ "${FAKE_NETWORKD:-}" == dead ]] && exit 0
f="$HPS_NETWORK_DIR/05-hps-vlan-$1.network"
d="$T/links/$1"
[[ -f "$f" && -d "$d" ]] || exit 0
a=$(sed -n 's/^Address=//p' "$f")
m=$(sed -n 's/^MTUBytes=//p' "$f")
grep -qxF "$a" "$d/addrs" || echo "$a" >> "$d/addrs"
[[ -z "$m" ]] || printf '%s' "$m" > "$d/mtu"
SHIM
  cat > "$T/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
emit() {
  local n="$1" d="$T/links/$1"
  jq -n --arg n "$n" --arg mac "$(cat "$d/mac")" --arg mtu "$(cat "$d/mtu")" \
    --arg kind "$(cat "$d/kind" 2>/dev/null || true)" --arg id "$(cat "$d/id" 2>/dev/null || true)" \
    --arg parent "$(cat "$d/parent" 2>/dev/null || true)" --arg master "$(cat "$d/master" 2>/dev/null || true)" '
    {ifname: $n, address: $mac, mtu: ($mtu|tonumber)}
    + (if $master != "" then {master: $master} else {} end)
    + (if $parent != "" then {link: $parent} else {} end)
    + (if $kind != "" then {linkinfo: ({info_kind: $kind} + (if $id != "" then {info_data: {id: ($id|tonumber)}} else {} end))} else {} end)'
}
emit_addr() {
  local n="$1"
  jq -n --arg n "$n" --rawfile a "$T/links/$n/addrs" '
    {ifname: $n, addr_info: [$a | split("\n")[] | select(. != "") | split("/") | {local: .[0], prefixlen: (.[1]|tonumber)}]}'
}
all() { ls "$T/links"; }
case "$*" in
  "-j -d link show")
    for l in $(all); do emit "$l"; done | jq -s . ;;
  "-j -d link show dev "*)
    [[ -d "$T/links/$6" ]] || { echo "Device \"$6\" does not exist." >&2; exit 1; }
    emit "$6" | jq -s . ;;
  "-j -4 addr show")
    for l in $(all); do emit_addr "$l"; done | jq -s . ;;
  "-j -4 addr show dev "*)
    [[ -d "$T/links/$6" ]] || exit 1
    emit_addr "$6" | jq -s . ;;
  "link add link "*)
    [[ "${FAKE_LINK_ADD_RC:-0}" -eq 0 ]] || exit "$FAKE_LINK_ADD_RC"
    p="$4" s="$6" v="${10}"
    d="$T/links/$s"
    mkdir -p "$d"
    cp "$T/links/$p/mac" "$d/mac"
    cp "$T/links/$p/mtu" "$d/mtu"
    printf vlan > "$d/kind"
    printf '%s' "$v" > "$d/id"
    printf '%s' "$p" > "$d/parent"
    : > "$d/addrs"
    fake-networkd-apply "$s" ;;
  "link set dev "*" mtu "*)
    printf '%s' "$6" > "$T/links/$4/mtu" ;;
  "addr del "*)
    grep -vxF "$3" "$T/links/$5/addrs" > "$T/links/$5/addrs.new" || true
    mv "$T/links/$5/addrs.new" "$T/links/$5/addrs" ;;
  *) echo "ip shim: unhandled: $*" >&2; exit 1 ;;
esac
SHIM
  cat > "$T/bin/networkctl" <<'SHIM'
#!/usr/bin/env bash
echo "networkctl $*" >> "$SHIM_LOG"
[[ "${FAKE_NETWORKCTL_RC:-0}" -eq 0 ]] || exit "$FAKE_NETWORKCTL_RC"
case "$1" in
  reload) for l in $(ls "$T/links"); do fake-networkd-apply "$l"; done ;;
  reconfigure) fake-networkd-apply "$2" ;;
esac
SHIM
  chmod +x "$T"/bin/*
}

addrs() { cat "$T/links/$1/addrs"; }

# --- usage (exit 2) -------------------------------------------------------------

@test "1: usage errors exit 2 and change nothing" {
  for args in "" "boot" "boot 113" "boot 0 10.113.0.153/24" "boot 4095 10.113.0.153/24" "boot x 10.113.0.153/24" \
      "boot 113 10.113.0.153" "boot 113 10.113.0.300/24" "boot 113 10.113.0.153/31" "boot 113 10.113.0.153/7" \
      "boot 113 10.113.0.153/24 --mtu 100" "boot 113 10.113.0.153/24 --mtu 9217" "boot 113 10.113.0.153/24 --mtu" \
      "boot 113 10.113.0.153/24 --mtu 9000 --mtu 9000" "boot 113 10.113.0.153/24 --bogus" "-x 113 10.113.0.153/24" \
      "eth0;rm 113 10.113.0.153/24"; do
    # shellcheck disable=SC2086  # the words are the arguments
    run "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "args: $args -> $status $output"; return 1; }
  done
  [ ! -s "$SHIM_LOG" ]
  [ -z "$(ls "$T/net")" ]
}

@test "2: the network and broadcast addresses are refused (exit 3)" {
  run "$SCRIPT" boot 113 10.113.0.0/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"network address"* ]]
  run "$SCRIPT" boot 113 10.113.0.255/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"broadcast address"* ]]
  [ -z "$(ls "$T/net")" ]
}

# --- the normal path -------------------------------------------------------------

@test "3: boot: makes eth0.113 after networkd has its file, address and MTU applied, parent raised" {
  run "$SCRIPT" boot 113 10.113.0.153/24 --mtu 9000
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "net-vlan-address: eth0.113 (vlan 113 on eth0) 10.113.0.153/24 mtu 9000: created" ]
  f="$T/net/05-hps-vlan-eth0.113.network"
  [ -f "$f" ]
  grep -qx 'Name=eth0.113' "$f"
  grep -qx 'Address=10.113.0.153/24' "$f"
  grep -qx 'MTUBytes=9000' "$f"
  grep -qx 'DHCP=no' "$f"
  grep -qx 'LinkLocalAddressing=no' "$f"
  [ "$(addrs eth0.113)" = "10.113.0.153/24" ]
  [ "$(cat "$T/links/eth0.113/mtu")" = 9000 ]
  [ "$(cat "$T/links/eth0/mtu")" = 9000 ]
  # order: parent MTU, reload, then the link
  run grep -nE '^(ip link set dev eth0 mtu 9000|networkctl reload|ip link add link eth0 name eth0.113 type vlan id 113)$' "$SHIM_LOG"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"ip link set dev eth0 mtu 9000" ]]
  [[ "${lines[1]}" == *"networkctl reload" ]]
  [[ "${lines[2]}" == *"ip link add link eth0"* ]]
}

@test "4: a second run changes nothing" {
  "$SCRIPT" boot 113 10.113.0.153/24 --mtu 9000
  : > "$SHIM_LOG"
  run "$SCRIPT" boot 113 10.113.0.153/24 --mtu 9000
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *": unchanged" ]]
  run ! grep -qE 'networkctl|link add|link set|addr del' "$SHIM_LOG"
}

@test "5: a new address rewrites the file, reconfigures the link and removes the old address" {
  "$SCRIPT" boot 113 10.113.0.153/24 --mtu 9000
  : > "$SHIM_LOG"
  run "$SCRIPT" boot 113 10.113.0.154/24 --mtu 9000
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"10.113.0.154/24 mtu 9000: updated" ]]
  grep -qx 'networkctl reconfigure eth0.113' "$SHIM_LOG"
  grep -qx 'ip addr del 10.113.0.153/24 dev eth0.113' "$SHIM_LOG"
  [ "$(addrs eth0.113)" = "10.113.0.154/24" ]
  run ! grep -q 'link add' "$SHIM_LOG"
}

@test "6: file current but the address gone: reconfigured" {
  "$SCRIPT" boot 113 10.113.0.153/24
  : > "$T/links/eth0.113/addrs"
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *": reapplied" ]]
  [ "$(addrs eth0.113)" = "10.113.0.153/24" ]
}

@test "7: without --mtu no MTU is written and the parent is left alone" {
  run "$SCRIPT" boot 114 10.113.1.153/24
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"mtu unchanged: created" ]]
  run ! grep -q MTUBytes "$T/net/05-hps-vlan-eth0.114.network"
  run ! grep -q 'link set' "$SHIM_LOG"
  [ "$(cat "$T/links/eth0/mtu")" = 1500 ]
}

@test "8: a named parent; a parent already at the MTU is not touched" {
  printf 9000 > "$T/links/eth1/mtu"
  run "$SCRIPT" eth1 112 10.11.2.153/24 --mtu 9000
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "net-vlan-address: eth1.112 (vlan 112 on eth1) 10.11.2.153/24 mtu 9000: created" ]]
  run ! grep -q 'link set' "$SHIM_LOG"
}

@test "9: boot finds the physical NIC, not the hps-net bridge that carries the same MAC" {
  mklink br-boot 52:54:00:00:01:53 1500 bridge
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"(vlan 113 on eth0)"* ]]
}

# --- refusals (exit 3) -----------------------------------------------------------

@test "10: boot without hps.mac, or no NIC with that MAC: refused" {
  printf 'console=ttyS1 hps.ips=10.11.0.1\n' > "$T/cmdline"
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"hps.mac absent"* ]]
  printf 'hps.mac=52:54:00:00:09:99\n' > "$T/cmdline"
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"no physical interface carries the boot MAC"* ]]
  [ -z "$(ls "$T/net")" ]
}

@test "11: a missing parent, a VLAN parent and a too-long name are refused" {
  run "$SCRIPT" eth9 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"eth9 does not exist"* ]]
  mklink eth0.50 52:54:00:00:01:53 1500 vlan 50 eth0
  run "$SCRIPT" eth0.50 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"itself a VLAN"* ]]
  mklink enp129s0f1np1 52:54:00:00:03:53 1500
  run "$SCRIPT" enp129s0f1np1 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"longer than the 15 characters"* ]]
  [ -z "$(ls "$T/net")" ]
}

@test "12: an existing sub-interface that is a bridge member or another VLAN is refused" {
  mklink eth0.113 52:54:00:00:01:53 1500 vlan 113 eth0 br-stor
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"member of bridge br-stor"* ]]
  rm -rf "$T/links/eth0.113"
  mklink eth0.113 52:54:00:00:01:53 1500 vlan 13 eth0
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"not vlan 113 on eth0"* ]]
  [ -z "$(ls "$T/net")" ]
}

@test "13: an address already on another interface is refused" {
  echo 10.113.0.153/24 > "$T/links/eth1/addrs"
  run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"already on interface eth1"* ]]
  [ -z "$(ls "$T/net")" ]
}

# --- failures (exit 1) -----------------------------------------------------------

@test "14: networkd never applies the address: exit 1 within the wait" {
  FAKE_NETWORKD=dead run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not put 10.113.0.153/24 on eth0.113"* ]]
}

@test "15: networkctl reload failing, or ip link add failing, is exit 1" {
  FAKE_NETWORKCTL_RC=1 run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 1 ]
  [[ "$output" == *"networkctl reload exited 1"* ]]
  rm -f "$T"/net/*
  FAKE_LINK_ADD_RC=2 run "$SCRIPT" boot 113 10.113.0.153/24
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not create eth0.113"* ]]
}

# --- wiring ------------------------------------------------------------------------

@test "16: allowlisted in hps-ctrl-exec.nix (every node image) under profile node" {
  f="$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -qF 'net-vlan-address.source = mkScript "net-vlan-address" (scriptsDir + "/net-vlan-address");' "$f"
  grep -qF 'net-vlan-address.options.profile = "node";' "$f"
  [ -x "$SCRIPT" ]
}

@test "17: every command is logged; no library is sourced" {
  run ! grep -nE '^\s*(source|\.) ' "$SCRIPT"
  "$SCRIPT" boot 113 10.113.0.153/24 2> "$T/err"
  grep -q '^+ ip link add link eth0 name eth0.113 type vlan id 113' "$T/err"
  grep -q '^+ networkctl reload' "$T/err"
  grep -q "^\[net-vlan-address\] + write $T/net/05-hps-vlan-eth0.113.network" "$T/err"
}
