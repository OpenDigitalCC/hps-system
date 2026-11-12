#!/usr/bin/env bats
#
# vm-disk-hotplug: unplug one disk of a running guest (its live <disk> element
# saved under HPS_HOTPLUG_DIR, virsh detach-device --live) and plug exactly
# that element back (attach-device --live). Stateful virsh shim: the live
# targets are lines in $STATE/blk.<vm>.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-222.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  SCRIPT="$S/vm-disk-hotplug"
  export HPS_HOTPLUG_DIR="$TEST_DIR/hotplug"
  echo running > "$STATE/domstate.s1-sch-001"
  printf 'vda\nvdb\nvdc\n' > "$STATE/blk.s1-sch-001"
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
echo "virsh $*" >> "$SHIM_LOG"
shift 2  # -c qemu:///system
case "$1" in
  domstate) cat "$STATE/domstate.$2" 2> /dev/null || { echo "error: no domain" >&2; exit 1; } ;;
  domblklist)
    printf ' Target   Source\n------------------\n'
    while read -r t; do printf ' %s      /dev/zvol/lab/enc/vm/%s-%s\n' "$t" "$2" "$t"; done < "$STATE/blk.$2" ;;
  dumpxml)
    t=$(printf '%s' "$4" | sed -E "s/.*@dev='([a-z]+)'.*/\1/")
    grep -qx "$t" "$STATE/blk.$2" || exit 0
    boot=""; [[ "$t" == vda ]] && boot="<boot order='1'/>"
    printf "<disk type='block' device='disk'><source dev='/dev/zvol/x/%s'/><target dev='%s' bus='virtio'/><serial>s-%s</serial>%s</disk>\n" "$t" "$t" "$t" "$boot" ;;
  detach-device)
    [[ -n "${FAKE_DETACH_RC:-}" ]] && exit "$FAKE_DETACH_RC"
    t=$(sed -E "s/.*target dev='([a-z]+)'.*/\1/" "$3")
    grep -vx "$t" "$STATE/blk.$2" > "$STATE/blk.new"; mv "$STATE/blk.new" "$STATE/blk.$2" ;;
  attach-device)
    t=$(sed -E "s/.*target dev='([a-z]+)'.*/\1/" "$3")
    echo "$t" >> "$STATE/blk.$2" ;;
esac
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "detach saves the disk element (with its serial) and unplugs it live" {
  run --separate-stderr bash "$SCRIPT" s1-sch-001 detach vdc
  [ "$status" -eq 0 ]
  [ "$output" = "VM-DISK s1-sch-001 vdc detached" ]
  grep -q "<serial>s-vdc</serial>" "$HPS_HOTPLUG_DIR/s1-sch-001-vdc.xml"
  grep -qxF "virsh -c qemu:///system detach-device s1-sch-001 $HPS_HOTPLUG_DIR/s1-sch-001-vdc.xml --live" "$SHIM_LOG"
  run ! grep -qx vdc "$STATE/blk.s1-sch-001"
}

@test "attach plugs back exactly the saved element and removes it" {
  bash "$SCRIPT" s1-sch-001 detach vdc 2> /dev/null
  run --separate-stderr bash "$SCRIPT" s1-sch-001 attach vdc
  [ "$status" -eq 0 ]
  [ "$output" = "VM-DISK s1-sch-001 vdc attached" ]
  grep -qx vdc "$STATE/blk.s1-sch-001"
  [ ! -e "$HPS_HOTPLUG_DIR/s1-sch-001-vdc.xml" ]
}

@test "repeat calls: already-detached, already-attached" {
  bash "$SCRIPT" s1-sch-001 detach vdb 2> /dev/null
  run --separate-stderr bash "$SCRIPT" s1-sch-001 detach vdb
  [ "$status" -eq 0 ]
  [ "$output" = "VM-DISK s1-sch-001 vdb already-detached" ]
  bash "$SCRIPT" s1-sch-001 attach vdb 2> /dev/null
  run --separate-stderr bash "$SCRIPT" s1-sch-001 attach vdb
  [ "$status" -eq 0 ]
  [ "$output" = "VM-DISK s1-sch-001 vdb already-attached" ]
}

@test "refused: the boot disk, an unknown disk, nothing saved to attach, a stopped guest" {
  run bash "$SCRIPT" s1-sch-001 detach vda
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" s1-sch-001 detach vdq
  [ "$status" -eq 3 ]
  printf 'vda\nvdb\n' > "$STATE/blk.s1-sch-001"
  run bash "$SCRIPT" s1-sch-001 attach vdc
  [ "$status" -eq 3 ]
  echo "shut off" > "$STATE/domstate.s1-sch-001"
  run bash "$SCRIPT" s1-sch-001 detach vdb
  [ "$status" -eq 3 ]
}

@test "usage 2, not defined 4, a failing detach 1 and the disk stays" {
  run bash "$SCRIPT" s1-sch-001 pull vdb
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1-sch-001 detach /dev/sdb
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" nosuch detach vdb
  [ "$status" -eq 4 ]
  FAKE_DETACH_RC=1 run bash "$SCRIPT" s1-sch-001 detach vdb
  [ "$status" -eq 1 ]
  grep -qx vdb "$STATE/blk.s1-sch-001"
}
