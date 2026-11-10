#!/usr/bin/env bats
#
# CS-3.5: osvc-object-set - only the enforced keywords and the md / kvm / flag
# resource keywords; nothing that lets the daemon place or move an object.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-71.XXXXXX")"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/osvc-object-set"
  mkdir -p "$T/bin" "$T/etc"
  export OSVC_ETC="$T/etc"
  export SHIM_LOG="$T/shim.log"
  # om shim: logs; "get --kw K" prints the value stored in $T/etc/vals.K when
  # present, else the enforced value; "create" writes the object's conf file.
  cat > "$T/bin/om" <<'SH'
#!/usr/bin/env bash
echo "om $*" >> "$SHIM_LOG"
obj=$1; shift
case "$1" in
  create) touch "$OSVC_ETC/${obj#svc/}.conf" ;;
  get)
    kw=${*: -1}
    if [[ -f "$OSVC_ETC/vals.$kw" ]]; then cat "$OSVC_ETC/vals.$kw"; exit 0; fi
    case "$kw" in
      nodes) echo sch-001 ;; topology) echo failover ;; orchestrate) echo no ;;
      monitor_action|placement) echo none ;;
    esac ;;
esac
exit "${FAKE_OM_RC:-0}"
SH
  chmod +x "$T/bin/om"
  export PATH="$T/bin:$PATH"
  ENF=(nodes=sch-001 topology=failover orchestrate=no monitor_action=none placement=none)
}

teardown() {
  rm -rf "$T"
}

@test "a new object is created with all five enforced keywords in one om create" {
  run -0 bash "$SCRIPT" rig0 "${ENF[@]}" 'fs#1.type=flag'
  grep -qx 'om svc/rig0 create --kw nodes=sch-001 --kw topology=failover --kw orchestrate=no --kw monitor_action=none --kw placement=none --kw fs#1.type=flag' "$SHIM_LOG"
  [[ "$output" == *"object svc/rig0 configured"* ]]
}

@test "svc/<name> and <name> name the same object" {
  run -0 bash "$SCRIPT" svc/rig0 "${ENF[@]}"
  grep -q '^om svc/rig0 create' "$SHIM_LOG"
}

@test "a new object missing an enforced keyword is refused before om runs" {
  run -3 bash "$SCRIPT" rig0 nodes=sch-001 topology=failover orchestrate=no placement=none
  [[ "$output" == *"must set monitor_action"* ]]
  [ ! -e "$SHIM_LOG" ]
}

@test "an existing object is changed with om set --local, no create" {
  touch "$OSVC_ETC/rig0.conf"
  run -0 bash "$SCRIPT" rig0 'container#1.memory=4096' 'container#1.vcpus=2'
  grep -qx 'om svc/rig0 set --local --kw container#1.memory=4096 --kw container#1.vcpus=2' "$SHIM_LOG"
  run ! grep -q ' create ' "$SHIM_LOG"
}

@test "refuses orchestrate other than no (ha, start)" {
  local v
  for v in ha start ""; do
    run -3 bash "$SCRIPT" rig0 "orchestrate=$v"
    [ ! -e "$SHIM_LOG" ]
  done
}

@test "refuses nodes with more than one name, in every spelling" {
  local v
  for v in 'sch-001 sch-002' 'sch-001,sch-002' 'sch-001;sch-002' '*' '{sch-001,sch-002}' ''; do
    run -3 bash "$SCRIPT" rig0 "nodes=$v"
    [ ! -e "$SHIM_LOG" ]
  done
}

@test "refuses placement and monitor_action other than none, and topology other than failover" {
  run -3 bash "$SCRIPT" rig0 placement=spread
  run -3 bash "$SCRIPT" rig0 placement=nodes
  run -3 bash "$SCRIPT" rig0 monitor_action=reboot
  run -3 bash "$SCRIPT" rig0 monitor_action=crash
  run -3 bash "$SCRIPT" rig0 topology=flex
  [ ! -e "$SHIM_LOG" ]
}

@test "refuses keywords outside the allowed set" {
  local kw
  for kw in 'drpnodes=x' 'flex_min=1' 'app#1.start=x' 'fs#1.type=ext4' 'fs#1.dev=/dev/sda' \
            'disk#1.type=zfs' 'container#1.type=docker' 'disk#1.bogus=1' 'sync#1.type=rsync'; do
    run -3 bash "$SCRIPT" rig0 "$kw"
    [ ! -e "$SHIM_LOG" ] || { echo "accepted $kw"; return 1; }
  done
}

@test "accepts the md disk and kvm container keywords" {
  touch "$OSVC_ETC/rig0.conf"
  run -0 bash "$SCRIPT" rig0 'disk#1.type=md' 'disk#1.uuid=aa:bb' 'disk#1.devs=/dev/md127' 'disk#1.bitmap=internal' \
    'container#1.type=kvm' 'container#1.name=web1' 'container#1.vcpus=2' 'container#1.memory=2048' 'container#1.network=br0'
  grep -q 'disk#1.type=md' "$SHIM_LOG"
  grep -q 'container#1.type=kvm' "$SHIM_LOG"
}

@test "refuses values with spaces, quotes or shell characters" {
  touch "$OSVC_ETC/rig0.conf"
  run -3 bash "$SCRIPT" rig0 'container#1.name=a b'
  run -3 bash "$SCRIPT" rig0 'container#1.name=a"b'
  run -3 bash "$SCRIPT" rig0 'container#1.name=$(id)'
  [ ! -e "$SHIM_LOG" ]
}

@test "an object whose stored orchestrate is not no is refused after the set" {
  touch "$OSVC_ETC/rig0.conf"
  echo ha > "$OSVC_ETC/vals.orchestrate"
  run -3 bash "$SCRIPT" rig0 'container#1.memory=4096'
  [[ "$output" == *"orchestrate='ha'"* ]]
}

@test "an object whose stored nodes lists two nodes is refused after the set" {
  touch "$OSVC_ETC/rig0.conf"
  echo 'sch-001 sch-002' > "$OSVC_ETC/vals.nodes"
  run -3 bash "$SCRIPT" rig0 'container#1.memory=4096'
  [[ "$output" == *"exactly one node"* ]]
}

@test "usage: no keyword, a bad object name, a pair without =" {
  run -2 bash "$SCRIPT" rig0
  run -2 bash "$SCRIPT" 'Rig 0' nodes=sch-001
  run -2 bash "$SCRIPT" rig0 nodes
  [ ! -e "$SHIM_LOG" ]
}

@test "om failing is exit 1" {
  FAKE_OM_RC=1 run -1 bash "$SCRIPT" rig0 "${ENF[@]}"
}
