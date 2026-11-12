#!/usr/bin/env bats
#
# VXLAN workload networks: net-vxlan-ensure builds vxlan<vni> (local transit
# address, dstport 4789, nolearning) in the layout bridge, one all-zero MAC FDB
# entry per peer, MTUs set, links up; idempotent, and a changed peer list
# replaces the entries exactly. Stateful `ip` and `bridge` shims: links under
# $T/links/<name>/ (kind, mtu, state, master, id, local, port, learning,
# addrs), FDB entries under $T/fdb/<link> (one dst per line).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-vxlan-ensure"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-201.XXXXXX")"
  mkdir -p "$T/bin" "$T/links" "$T/net" "$T/fdb"
  export T
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_NETWORK_DIR="$T/net"
  mklink eth0 1500 up
  mklink eth0.112 9000 up vlan
  echo 10.11.2.12/24 > "$T/links/eth0.112/addrs"
  write_shims
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

# mklink <name> <mtu> <up|down> [kind] [master]
mklink() {
  local d="$T/links/$1"
  mkdir -p "$d"
  printf '%s' "$2" > "$d/mtu"
  printf '%s' "$3" > "$d/state"
  [[ -z "${4:-}" ]] || printf '%s' "$4" > "$d/kind"
  [[ -z "${5:-}" ]] || printf '%s' "$5" > "$d/master"
  : >> "$d/addrs"
}

# mkvxlan <vni> <local> <port> <learning> [master]
mkvxlan() {
  mklink "vxlan$1" 8950 up vxlan "${5:-}"
  printf '%s' "$1" > "$T/links/vxlan$1/id"
  printf '%s' "$2" > "$T/links/vxlan$1/local"
  printf '%s' "$3" > "$T/links/vxlan$1/port"
  printf '%s' "$4" > "$T/links/vxlan$1/learning"
  : > "$T/fdb/vxlan$1"
}

write_shims() {
  cat > "$T/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
L="$T/links"
f() { cat "$L/$1/$2" 2>/dev/null || true; }
emit() {
  local n="$1"
  jq -n --arg n "$n" --arg mtu "$(f "$n" mtu)" --arg st "$(f "$n" state)" --arg kind "$(f "$n" kind)" \
    --arg master "$(f "$n" master)" --arg id "$(f "$n" id)" --arg local "$(f "$n" local)" \
    --arg port "$(f "$n" port)" --arg learning "$(f "$n" learning)" '
    {ifname: $n, mtu: ($mtu|tonumber), flags: (["BROADCAST"] + (if $st == "up" then ["UP"] else [] end))}
    + (if $master != "" then {master: $master} else {} end)
    + (if $kind != "" then {linkinfo: ({info_kind: $kind}
        + (if $kind == "vxlan" then {info_data: {id: ($id|tonumber), local: $local, port: ($port|tonumber),
             learning: ($learning == "true")}} else {} end))} else {} end)'
}
emit_addr() {
  jq -n --arg n "$1" --arg mtu "$(f "$1" mtu)" --rawfile a "$L/$1/addrs" '
    {ifname: $n, mtu: ($mtu|tonumber), addr_info: [$a | split("\n")[] | select(. != "") | split("/") | {local: .[0], prefixlen: (.[1]|tonumber)}]}'
}
case "$*" in
  "-j -4 addr show")
    for d in "$L"/*; do emit_addr "$(basename "$d")"; done | jq -s . ;;
  "-j -d link show")
    for d in "$L"/*; do emit "$(basename "$d")"; done | jq -s . ;;
  "-j -d link show dev "*)
    [[ -d "$L/$6" ]] || { echo "Device \"$6\" does not exist." >&2; exit 1; }
    emit "$6" | jq -s . ;;
  "link add name "*" type bridge")
    mkdir -p "$L/$4"; echo bridge > "$L/$4/kind"; echo 1500 > "$L/$4/mtu"; echo down > "$L/$4/state"; : > "$L/$4/addrs" ;;
  "link add "*" type vxlan "*)
    [[ "${FAKE_VXLAN_ADD_RC:-0}" -eq 0 ]] || exit "$FAKE_VXLAN_ADD_RC"
    n="$3"; shift 5
    mkdir -p "$L/$n"; echo vxlan > "$L/$n/kind"; echo 1500 > "$L/$n/mtu"; echo down > "$L/$n/state"
    echo true > "$L/$n/learning"; : > "$L/$n/addrs"; : > "$T/fdb/$n"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        id) echo "$2" > "$L/$n/id"; shift 2 ;;
        local) echo "$2" > "$L/$n/local"; shift 2 ;;
        dstport) echo "$2" > "$L/$n/port"; shift 2 ;;
        nolearning) echo false > "$L/$n/learning"; shift ;;
        *) echo "ip shim: vxlan option $1" >&2; exit 98 ;;
      esac
    done ;;
  "link del dev "*)
    rm -rf "${L:?}/$4" "$T/fdb/$4" ;;
  "link set dev "*" addrgenmode none") ;;
  "link set dev "*" mtu "*) echo "$6" > "$L/$4/mtu" ;;
  "link set dev "*" master "*) echo "$6" > "$L/$4/master" ;;
  "link set dev "*" up") echo up > "$L/$4/state" ;;
  *) echo "ip shim: unhandled: $*" >&2; exit 99 ;;
esac
SHIM
  cat > "$T/bin/bridge" <<'SHIM'
#!/usr/bin/env bash
echo "bridge $*" >> "$SHIM_LOG"
case "$*" in
  "-j fdb show dev "*)
    # the link's own MAC entry (as the kernel lists it), then the all-zero ones
    { jq -n --arg d "$5" '{mac: "aa:bb:cc:dd:ee:01", master: "br-x", state: "permanent", ifname: $d}'
      while IFS= read -r dst; do
        [[ -n "$dst" ]] && jq -n --arg dst "$dst" '{mac: "00:00:00:00:00:00", dst: $dst, state: "permanent", flags: []}'
      done < "$T/fdb/$5"; } | jq -s . ;;
  "fdb append 00:00:00:00:00:00 dev "*" dst "*)
    grep -qxF "$7" "$T/fdb/$5" || echo "$7" >> "$T/fdb/$5" ;;
  "fdb del 00:00:00:00:00:00 dev "*" dst "*)
    grep -vxF "$7" "$T/fdb/$5" > "$T/fdb/$5.new" || true
    mv "$T/fdb/$5.new" "$T/fdb/$5" ;;
  *) echo "bridge shim: unhandled: $*" >&2; exit 99 ;;
esac
SHIM
  cat > "$T/bin/networkctl" <<'SHIM'
#!/usr/bin/env bash
echo "networkctl $*" >> "$SHIM_LOG"
SHIM
  # iptables: chains as files under $T/ipt/<chain> (one rule per line);
  # nixos-fw exists unless NO_FW is set.
  mkdir -p "$T/ipt"
  [[ -n "${NO_FW:-}" ]] || : > "$T/ipt/nixos-fw"
  cat > "$T/bin/iptables" <<'SHIM'
#!/usr/bin/env bash
echo "iptables $*" >> "$SHIM_LOG"
[[ "$1" == -w ]] && shift
op="$1"; chain="$2"; shift 2
case "$op" in
  -n) [[ -f "$T/ipt/$1" ]] ;;
  -N) : > "$T/ipt/$chain" ;;
  -C) [[ -f "$T/ipt/$chain" ]] && grep -qxF -- "$*" "$T/ipt/$chain" ;;
  -A) echo "$*" >> "$T/ipt/$chain" ;;
  -I) shift; { echo "$*"; cat "$T/ipt/$chain"; } > "$T/ipt/$chain.new" && mv "$T/ipt/$chain.new" "$T/ipt/$chain" ;;
  *) exit 2 ;;
esac
SHIM
  chmod +x "$T"/bin/*
}

fdb() { sort "$T/fdb/$1" | tr '\n' ' '; }
lf() { cat "$T/links/$1/$2"; }
changes() { grep -E '^(ip link (add|del|set)|bridge fdb (append|del)|networkctl)' "$SHIM_LOG" || true; }

ARGS=(1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.14 --peer 10.11.2.15 --mtu 8950)

# --- usage (exit 2) -------------------------------------------------------------

@test "1: usage errors exit 2 and change nothing" {
  for args in "" "1100" "1100 br-client" "1100 br-client --local 10.11.2.12" \
      "0 br-client --local 10.11.2.12 --mtu 8950" "16777216 br-client --local 10.11.2.12 --mtu 8950" \
      "x br-client --local 10.11.2.12 --mtu 8950" "1100 client --local 10.11.2.12 --mtu 8950" \
      "1100 br-ABC --local 10.11.2.12 --mtu 8950" "1100 br-client --local 10.11.2 --mtu 8950" \
      "1100 br-client --local 10.11.2.300 --mtu 8950" "1100 br-client --local 10.11.2.12 --mtu 500" \
      "1100 br-client --local 10.11.2.12 --mtu 9001" "1100 br-client --local 10.11.2.12 --mtu 8950 --mtu 8950" \
      "1100 br-client --local 10.11.2.12 --local 10.11.2.13 --mtu 8950" \
      "1100 br-client --local 10.11.2.12 --peer 10.11.2.12 --mtu 8950" \
      "1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.13 --mtu 8950" \
      "1100 br-client --local 10.11.2.12 --peer nas --mtu 8950" "1100 br-client --local 10.11.2.12 --peer" \
      "1100 br-client --local 10.11.2.12 --mtu 8950 --bogus" "1100;rm br-client --local 10.11.2.12 --mtu 8950"; do
    # shellcheck disable=SC2086  # the words are the arguments
    run "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "args: $args -> $status $output"; return 1; }
  done
  [ ! -s "$SHIM_LOG" ]
  [ -z "$(ls "$T/net")" ]
}

# --- the normal path -------------------------------------------------------------

@test "2: builds vxlan1100 in br-client: local, dstport 4789, nolearning, one zero-MAC entry per peer, MTUs, up" {
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "net-vxlan-ensure: vxlan1100 (vni 1100, local 10.11.2.12 via eth0.112, 3 peer(s)) in br-client mtu 8950: created" ]
  grep -qx 'ip link add vxlan1100 type vxlan id 1100 local 10.11.2.12 dstport 4789 nolearning' "$SHIM_LOG"
  grep -qx 'ip link add name br-client type bridge' "$SHIM_LOG"
  [ "$(lf vxlan1100 learning)" = false ]
  [ "$(lf vxlan1100 port)" = 4789 ]
  [ "$(lf vxlan1100 master)" = br-client ]
  [ "$(lf vxlan1100 mtu)" = 8950 ]
  [ "$(lf br-client mtu)" = 8950 ]
  [ "$(lf vxlan1100 state)" = up ]
  [ "$(lf br-client state)" = up ]
  [ "$(fdb vxlan1100)" = "10.11.2.13 10.11.2.14 10.11.2.15 " ]
  grep -qx 'bridge fdb append 00:00:00:00:00:00 dev vxlan1100 dst 10.11.2.13' "$SHIM_LOG"
  # no address on either link; addrgenmode none on both
  [ ! -s "$T/links/br-client/addrs" ]
  grep -qx 'ip link set dev br-client addrgenmode none' "$SHIM_LOG"
  grep -qx 'ip link set dev vxlan1100 addrgenmode none' "$SHIM_LOG"
}

@test "3: networkd is told to leave both links alone, before they are made" {
  "$SCRIPT" "${ARGS[@]}"
  f="$T/net/05-hps-br-client.network"
  grep -qx 'Name=br-client vxlan1100' "$f"
  grep -qx 'Unmanaged=yes' "$f"
  run grep -nE '^(networkctl reload|ip link add)' "$SHIM_LOG"
  [[ "${lines[0]}" == *"networkctl reload" ]]
}

@test "4: a second run with the same peers changes nothing" {
  "$SCRIPT" "${ARGS[@]}"
  : > "$SHIM_LOG"
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *": unchanged" ]]
  [ -z "$(changes)" ]
}

@test "5: a changed peer list replaces the FDB entries exactly" {
  "$SCRIPT" "${ARGS[@]}"
  : > "$SHIM_LOG"
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --peer 10.11.2.14 --peer 10.11.2.16 --mtu 8950
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"2 peer(s)) in br-client mtu 8950: updated" ]]
  [ "$(fdb vxlan1100)" = "10.11.2.14 10.11.2.16 " ]
  grep -qx 'bridge fdb del 00:00:00:00:00:00 dev vxlan1100 dst 10.11.2.13' "$SHIM_LOG"
  grep -qx 'bridge fdb del 00:00:00:00:00:00 dev vxlan1100 dst 10.11.2.15' "$SHIM_LOG"
  grep -qx 'bridge fdb append 00:00:00:00:00:00 dev vxlan1100 dst 10.11.2.16' "$SHIM_LOG"
  run ! grep -q 'dst 10.11.2.14' "$SHIM_LOG"
  run ! grep -q 'link add' "$SHIM_LOG"
}

@test "6: no peers (a host alone on the transit) removes every entry" {
  "$SCRIPT" "${ARGS[@]}"
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --mtu 8950
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"0 peer(s)"* ]]
  [ -z "$(fdb vxlan1100)" ]
}

@test "7: a lost setup (reboot, links down, MTU reset) is rebuilt" {
  "$SCRIPT" "${ARGS[@]}"
  echo down > "$T/links/vxlan1100/state"
  echo 1500 > "$T/links/br-client/mtu"
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *": updated" ]]
  [ "$(lf vxlan1100 state)" = up ]
  [ "$(lf br-client mtu)" = 8950 ]
}

@test "8: an existing vxlan1100 with another local address, port or learning is made again" {
  mklink br-client 8950 up bridge
  mkvxlan 1100 10.11.2.99 4789 false br-client
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -qx 'ip link del dev vxlan1100' "$SHIM_LOG"
  [ "$(lf vxlan1100 local)" = 10.11.2.12 ]
  [ "$(fdb vxlan1100)" = "10.11.2.13 10.11.2.14 10.11.2.15 " ]
  rm -rf "$T/links/vxlan1100"
  mkvxlan 1100 10.11.2.12 8472 false br-client
  : > "$SHIM_LOG"
  "$SCRIPT" "${ARGS[@]}"
  grep -qx 'ip link del dev vxlan1100' "$SHIM_LOG"
  rm -rf "$T/links/vxlan1100"
  mkvxlan 1100 10.11.2.12 4789 true br-client
  : > "$SHIM_LOG"
  "$SCRIPT" "${ARGS[@]}"
  grep -qx 'ip link del dev vxlan1100' "$SHIM_LOG"
  [ "$(lf vxlan1100 learning)" = false ]
}

@test "9: an existing bridge is used as it is" {
  mklink br-client 8950 up bridge
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  run ! grep -q 'type bridge' "$SHIM_LOG"
  [ "$(lf vxlan1100 master)" = br-client ]
}

# --- refusals (exit 3), nothing changed ---------------------------------------

@test "10: the local address not on this host is refused" {
  run "$SCRIPT" 1100 br-client --local 10.11.2.20 --peer 10.11.2.13 --mtu 8950
  [ "$status" -eq 3 ]
  [[ "$output" == *"local address 10.11.2.20 is not on this host"* ]]
  [ -z "$(changes)" ]
  [ -z "$(ls "$T/net")" ]
}

@test "11: a transit link without room for the VXLAN header is refused" {
  echo 1500 > "$T/links/eth0.112/mtu"
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"eth0.112 carries 10.11.2.12 with MTU 1500; VXLAN MTU 8950 needs at least 9000"* ]]
  [ -z "$(changes)" ]
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --mtu 1450
  [ "$status" -eq 0 ]
}

@test "12: vxlan1100 as another kind, another VNI's name clash, or in another bridge is refused" {
  mklink vxlan1100 1500 up dummy
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"vxlan1100 exists and is a 'dummy' link"* ]]
  rm -rf "$T/links/vxlan1100"
  mkvxlan 1100 10.11.2.12 4789 false
  printf 1200 > "$T/links/vxlan1100/id"
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"exists with VNI '1200', not 1100"* ]]
  rm -rf "$T/links/vxlan1100"
  mkvxlan 1100 10.11.2.12 4789 false br-other
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"vxlan1100 is a member of bridge br-other, not br-client"* ]]
  [ -z "$(changes)" ]
}

@test "13: br-client as something other than a bridge, or already carrying another VXLAN, is refused" {
  mklink br-client 1500 up dummy
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"br-client exists and is a 'dummy' link, not a bridge"* ]]
  rm -rf "$T/links/br-client"
  mklink br-client 8950 up bridge
  mkvxlan 1200 10.11.2.12 4789 false br-client
  run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"bridge br-client already carries vxlan1200"* ]]
  [ -z "$(changes)" ]
}

# --- failures (exit 1) -----------------------------------------------------------

@test "14: ip link add failing is exit 1" {
  FAKE_VXLAN_ADD_RC=2 run "$SCRIPT" "${ARGS[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not create vxlan1100"* ]]
}

# --- wiring ------------------------------------------------------------------------

@test "15: allowlisted in hps-ctrl-exec.nix (every node image) under profile node" {
  f="$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -qF 'net-vxlan-ensure.source = mkScript "net-vxlan-ensure" (scriptsDir + "/net-vxlan-ensure");' "$f"
  grep -qF 'net-vxlan-ensure.options.profile = "node";' "$f"
  [ -x "$SCRIPT" ]
}

@test "16: every command is logged; no library is sourced" {
  run ! grep -nE '^\s*(source|\.) ' "$SCRIPT"
  "$SCRIPT" "${ARGS[@]}" 2> "$T/err"
  grep -q '^+ ip link add vxlan1100 type vxlan id 1100 local 10.11.2.12 dstport 4789 nolearning' "$T/err"
  grep -q '^+ bridge fdb append 00:00:00:00:00:00 dev vxlan1100 dst 10.11.2.15' "$T/err"
  grep -q '^+ ip link set dev vxlan1100 master br-client' "$T/err"
  grep -q "^\[net-vxlan-ensure\] + write $T/net/05-hps-br-client.network" "$T/err"
}

@test "firewall: VXLAN from each peer to the local address is accepted, once" {
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.14 --mtu 8950
  [ "$status" -eq 0 ]
  grep -qxF -- '-p udp --dport 4789 -j hps-vxlan' "$T/ipt/nixos-fw"
  grep -qxF -- '-s 10.11.2.13/32 -d 10.11.2.12/32 -p udp --dport 4789 -j nixos-fw-accept' "$T/ipt/hps-vxlan"
  grep -qxF -- '-s 10.11.2.14/32 -d 10.11.2.12/32 -p udp --dport 4789 -j nixos-fw-accept' "$T/ipt/hps-vxlan"
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.14 --mtu 8950
  [ "$status" -eq 0 ]
  [[ "$output" == *": unchanged" ]]
  [ "$(wc -l < "$T/ipt/hps-vxlan")" -eq 2 ]
  [ "$(grep -c hps-vxlan "$T/ipt/nixos-fw")" -eq 1 ]
}

@test "firewall: a new peer is added; without nixos-fw nothing is touched" {
  "$SCRIPT" 1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --mtu 8950
  run "$SCRIPT" 1100 br-client --local 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.15 --mtu 8950
  [ "$status" -eq 0 ]
  grep -qxF -- '-s 10.11.2.15/32 -d 10.11.2.12/32 -p udp --dport 4789 -j nixos-fw-accept' "$T/ipt/hps-vxlan"
  rm -rf "$T/ipt"; mkdir -p "$T/ipt"
  run "$SCRIPT" 1101 br-client2 --local 10.11.2.12 --peer 10.11.2.13 --mtu 8950
  [ "$status" -eq 0 ]
  [ ! -e "$T/ipt/hps-vxlan" ]
}
