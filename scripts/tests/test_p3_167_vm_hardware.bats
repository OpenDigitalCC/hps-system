#!/usr/bin/env bats
#
# Scale test phase 1: vm-define per-NIC fabric VLANs (--vlan-pvid, --vlan-tagged,
# recorded in the domain metadata), --nic-model, --disk-bus, --smbios; vm-start
# applies the recorded VLANs to each NIC's tap with `bridge vlan`. virsh comes
# from p3_20_helpers; `ip` and `bridge` are shims here.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-167.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  mkdir -p "$TEST_DIR/vlans"
  # ip -d link show dev <br>: br-fab is a VLAN-aware bridge, everything else a plain one,
  # br-none does not exist.
  cat > "$TEST_DIR/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
case "$5" in
  br-fab | br-fab2) echo "5: $5: <BROADCAST,MULTICAST,UP> mtu 9000 state UP"; echo "    bridge forward_delay 1500 vlan_filtering 1 vlan_protocol 802.1Q" ;;
  br-none) exit 1 ;;
  *) echo "5: $5: <BROADCAST,MULTICAST,UP> mtu 1500 state UP"; echo "    bridge forward_delay 1500 vlan_filtering 0 vlan_protocol 802.1Q" ;;
esac
SHIM
  # bridge vlan show dev <tap>: new taps are in VLAN 1 (the default pvid) until deleted.
  cat > "$TEST_DIR/bin/bridge" <<'SHIM'
#!/usr/bin/env bash
echo "bridge $*" >> "$SHIM_LOG"
v="$TEST_DIR/vlans/$4"
if [[ "$2" == show ]]; then
  [[ -e "$v" ]] || printf '%s 1 PVID Egress Untagged\n' "$4" > "$v"
  printf 'port              vlan-id\n'
  cat "$v"
  exit 0
fi
[[ -e "$v" ]] || printf '%s 1 PVID Egress Untagged\n' "$4" > "$v"
if [[ "$2" == del ]]; then
  : > "$v"
elif [[ "$2" == add ]]; then
  [[ "${FAKE_BRIDGE_FAIL:-}" != add ]] || { echo "RTNETLINK answers: Operation not supported" >&2; exit 2; }
  echo "$4 $6" >> "$v"
fi
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/ip" "$TEST_DIR/bin/bridge"
}

teardown() {
  rm -rf "$TEST_DIR"
}

nd() {
  bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 "$@"
}

bridge_cmds() {
  grep '^bridge ' "$SHIM_LOG" | grep -v ' show '
}

#--- vm-define: VLANs

@test "vm-define records pvid and tagged per NIC in the metadata and prints no VLAN config in the interface" {
  run nd --net br-fab --vlan-pvid 110 --vlan-tagged 111,112 --net br-fab --vlan-pvid 7
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  grep -qF "<hps:nic index='0' pvid='110' tagged='111,112'/>" "$x"
  grep -qF "<hps:nic index='1' pvid='7'/>" "$x"
  run ! grep -q "<vlan" "$x"
}

@test "a NIC without VLAN options has no metadata entry and no ip call is needed on a plain bridge" {
  run nd --net br-prov --net br-fab --vlan-pvid 5
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  run ! grep -q "hps:nic index='0'" "$x"
  grep -qF "<hps:nic index='1' pvid='5'/>" "$x"
}

@test "a NIC on a fabric bridge without --vlan-pvid is refused (3), nothing defined" {
  run nd --net br-fab
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs --vlan-pvid"* ]]
  [ ! -e "$STATE/xml.n1" ]
  run nd --net br-fab --vlan-tagged 5
  [ "$status" -eq 3 ]
  run nd --net br-prov --net br-fab --vlan-pvid 5 --net br-fab2
  [ "$status" -eq 3 ]
}

@test "a plain bridge or a missing one does not need a pvid" {
  run nd --net br-prov --net br-none
  [ "$status" -eq 0 ]
}

@test "bad VLAN values are refused (3): pvid range and text, tagged text, range, duplicate, pvid in tagged" {
  for v in 0 4095 abc 01 -1; do
    run nd --net br-prov --vlan-pvid "$v"
    [ "$status" -eq 3 ]
  done
  for t in 0 4095 a 5,,6 5, ,5 5,5 '5 6'; do
    run nd --net br-prov --vlan-pvid 9 --vlan-tagged "$t"
    [ "$status" -eq 3 ]
  done
  run nd --net br-prov --vlan-pvid 9 --vlan-tagged 8,9
  [ "$status" -eq 3 ]
  [[ "$output" == *"also the pvid"* ]]
  [ ! -e "$STATE/xml.n1" ]
}

@test "--vlan-pvid, --vlan-tagged, --nic-model before a --net, or twice for one --net, are usage errors (2)" {
  run nd --vlan-pvid 5 --net br-prov
  [ "$status" -eq 2 ]
  run nd --net br-prov --vlan-pvid 5 --vlan-pvid 6
  [ "$status" -eq 2 ]
  run nd --net br-prov --vlan-tagged 5 --vlan-tagged 6
  [ "$status" -eq 2 ]
  run nd --net br-prov --nic-model e1000e --nic-model rtl8139
  [ "$status" -eq 2 ]
  run nd --nic-model e1000e --net br-prov
  [ "$status" -eq 2 ]
  run nd --net br-prov --vlan-pvid ''
  [ "$status" -eq 2 ]
}

@test "the VLANs are part of the definition: a changed pvid is a different definition (3), same again is a no-op" {
  run nd --net br-fab --vlan-pvid 110
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run nd --net br-fab --vlan-pvid 110
  [ "$status" -eq 0 ]
  run ! grep -q '^virsh define' "$SHIM_LOG"
  run nd --net br-fab --vlan-pvid 111
  [ "$status" -eq 3 ]
}

@test "a definition without any new option keeps the hash it had before (sha256 of body, image and nothing else)" {
  run p3_20_define
  [ "$status" -eq 0 ]
  h=$(sed -n -E 's/.*<hps:spec>([0-9a-f]+)<\/hps:spec>.*/\1/p' "$STATE/xml.vm1")
  body=$(sed -n '/<name>/,/<\/devices>/p' "$STATE/xml.vm1" | sed '/<metadata>/,/<\/metadata>/d')
  want=$(printf '%s\n%s\n' "$body" "$IMG" | sha256sum)
  [ "$h" = "${want%% *}" ]
}

#--- vm-define: hardware

@test "--nic-model sets the model of the NIC before it; default virtio" {
  run nd --net br-prov --nic-model e1000e --net br-prov2 --net br-prov3 --nic-model rtl8139
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  [ "$(grep -c "<model type='e1000e'/>" "$x")" -eq 1 ]
  [ "$(grep -c "<model type='virtio'/>" "$x")" -eq 1 ]
  [ "$(grep -c "<model type='rtl8139'/>" "$x")" -eq 1 ]
  awk "/<source bridge='br-prov'\/>/{getline; print}" "$x" | grep -qF "<model type='e1000e'/>"
}

@test "--nic-model other than virtio, e1000e, rtl8139 is refused (3)" {
  run nd --net br-prov --nic-model ne2k_pci
  [ "$status" -eq 3 ]
  [[ "$output" == *"--nic-model"* ]]
}

@test "--disk-bus virtio (default): vda on virtio, no controller" {
  run p3_20_define
  [ "$status" -eq 0 ]
  grep -qF "<target dev='vda' bus='virtio'/>" "$STATE/xml.vm1"
  run ! grep -q "<controller" "$STATE/xml.vm1"
}

@test "--disk-bus scsi: a virtio-scsi controller and the disk on sda, bus scsi" {
  run p3_20_define --disk-bus scsi
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -qF "<controller type='scsi' index='0' model='virtio-scsi'/>" "$x"
  grep -qF "<target dev='sda' bus='scsi'/>" "$x"
  run ! grep -q "dev='vda'" "$x"
}

@test "--disk-bus sata: the disk on sda, bus sata, no extra controller" {
  run p3_20_define --disk-bus sata
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -qF "<target dev='sda' bus='sata'/>" "$x"
  run ! grep -q "<controller" "$x"
}

@test "--disk-bus is part of the definition; a bad value is refused (3); a non-virtio bus without a disk is refused (3)" {
  run p3_20_define
  [ "$status" -eq 0 ]
  run p3_20_define --disk-bus sata
  [ "$status" -eq 3 ]
  run nd --net br-prov --disk-bus ide
  [ "$status" -eq 3 ]
  run nd --net br-prov --disk-bus sata
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs a --disk"* ]]
}

@test "--smbios: sysinfo smbios with manufacturer, product, serial and <smbios mode='sysinfo'/> in os" {
  run nd --net br-prov --smbios "vendor=HPS Lab,product=Gen-A,serial=S1-001"
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  grep -qF "<sysinfo type='smbios'>" "$x"
  grep -qF "<entry name='manufacturer'>HPS Lab</entry>" "$x"
  grep -qF "<entry name='product'>Gen-A</entry>" "$x"
  grep -qF "<entry name='serial'>S1-001</entry>" "$x"
  s=$(grep -n "<smbios mode='sysinfo'/>" "$x" | cut -d: -f1)
  o=$(grep -n "</os>" "$x" | cut -d: -f1)
  [ "$s" -lt "$o" ]
}

@test "--smbios without serial has no serial entry; without --smbios no sysinfo" {
  run nd --net br-prov --smbios "vendor=HPS Lab,product=Gen-B"
  [ "$status" -eq 0 ]
  run ! grep -q "name='serial'" "$STATE/xml.n1"
  rm -f "$STATE/xml.n1" "$STATE/dom.n1"
  run nd --net br-prov
  [ "$status" -eq 0 ]
  run ! grep -q "sysinfo\|<smbios" "$STATE/xml.n1"
}

@test "--smbios is validated: missing keys, unknown key, quotes, XML characters, commas in values, empty, too long, leading space (3)" {
  for sm in "vendor=A" "product=B" "vendor=A,product=B,color=red" "vendor=A'B,product=C" 'vendor=A"B,product=C' \
    "vendor=A<b>,product=C" "vendor=A&B,product=C" "vendor=,product=C" "vendor=A,product=" "vendor=A,vendor=B,product=C" \
    "vendor= A,product=C" "vendor=A,product=C,serial=x;y" "vendor=A,product=\$(id)" "nonsense" \
    "vendor=$(printf 'a%.0s' $(seq 1 64)),product=C"; do
    run nd --net br-prov --smbios "$sm"
    [ "$status" -eq 3 ]
  done
  [ ! -e "$STATE/xml.n1" ]
}

#--- vm-start

fabric_vm() {
  nd --net br-fab --vlan-pvid 110 --vlan-tagged 111,112 --net br-fab --vlan-pvid 120 --net br-prov
}

# running_xml: the dumpxml of a running guest: libvirt adds <target dev=> to each interface.
running_xml() {
  awk '/<interface/ {n++} {print} /<source bridge=/ {printf "      <target dev='"'"'vnet%d'"'"'/>\n", n}' "$STATE/xml.n1" > "$STATE/xml.n1.run"
  mv "$STATE/xml.n1.run" "$STATE/xml.n1"
}

@test "vm-start runs the bridge commands per fabric NIC: del vid 1, add pvid untagged, add each tagged" {
  run fabric_vm
  [ "$status" -eq 0 ]
  running_xml
  : > "$SHIM_LOG"
  run bash "$S/vm-start" n1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM n1 running" ]
  [ "$(bridge_cmds)" = "bridge vlan del dev vnet1 vid 1
bridge vlan add dev vnet1 vid 110 pvid untagged
bridge vlan add dev vnet1 vid 111
bridge vlan add dev vnet1 vid 112
bridge vlan del dev vnet2 vid 1
bridge vlan add dev vnet2 vid 120 pvid untagged" ]
}

@test "vm-start: the VLANs are applied after virsh start and the taps come from dumpxml" {
  run fabric_vm
  running_xml
  : > "$SHIM_LOG"
  run bash "$S/vm-start" n1
  [ "$status" -eq 0 ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate start domstate dumpxml" ]
  s=$(grep -n '^virsh start' "$SHIM_LOG" | cut -d: -f1)
  b=$(grep -n '^bridge vlan del' "$SHIM_LOG" | head -n 1 | cut -d: -f1)
  [ "$s" -lt "$b" ]
}

@test "vm-start: a guest with no VLAN metadata gets no bridge call; virsh calls gain only dumpxml" {
  run nd --net br-prov
  [ "$status" -eq 0 ]
  running_xml
  : > "$SHIM_LOG"
  run bash "$S/vm-start" n1
  [ "$status" -eq 0 ]
  run ! grep -q '^bridge' "$SHIM_LOG"
}

@test "vm-start: an already running guest has its VLANs re-applied; a port already clear of VLAN 1 is not deleted again" {
  run fabric_vm
  running_xml
  run bash "$S/vm-start" n1
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/vm-start" n1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM n1 running" ]
  run ! grep -q '^virsh start' "$SHIM_LOG"
  run ! grep -q 'bridge vlan del' "$SHIM_LOG"
  grep -q '^bridge vlan add dev vnet1 vid 110 pvid untagged$' "$SHIM_LOG"
}

@test "vm-start: a failing bridge command fails the start (1) with the guest left running" {
  run fabric_vm
  running_xml
  export FAKE_BRIDGE_FAIL=add
  run bash "$S/vm-start" n1
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/dom.n1")" = "running" ]
}

@test "vm-start: VLAN metadata with no tap in the XML fails (1)" {
  run fabric_vm
  [ "$status" -eq 0 ]
  run bash "$S/vm-start" n1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no tap device"* ]]
}
