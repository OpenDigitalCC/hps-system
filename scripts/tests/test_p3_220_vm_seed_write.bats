#!/usr/bin/env bats
#
# Scale test probes: vm-seed-write puts a cloud-init NoCloud seed (stdin JSON)
# on the boot disk vm-image-write filled. partx, blkid, mount, umount and
# install are shims: the "partition" is a directory tree under $STATE/rootfs
# that mount copies in and umount copies back.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-220.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  export HPS_RUN="$TEST_DIR/run"
  mkdir -p "$STATE/rootfs/etc" "$STATE/rootfs/var/lib"
  seed_shims
}

teardown() {
  rm -rf "$TEST_DIR"
}

seed_shims() {
  cat > "$TEST_DIR/bin/partx" <<'SHIM'
#!/usr/bin/env bash
echo "partx $*" >> "$SHIM_LOG"
[[ -e "$STATE/no-partition" ]] && exit 1
echo "  262144 6027264"
SHIM
  cat > "$TEST_DIR/bin/blkid" <<'SHIM'
#!/usr/bin/env bash
echo "blkid $*" >> "$SHIM_LOG"
cat "$STATE/fstype" 2> /dev/null || echo ext4
SHIM
  cat > "$TEST_DIR/bin/mount" <<'SHIM'
#!/usr/bin/env bash
echo "mount $*" >> "$SHIM_LOG"
dir="${*: -1}"
cp -a "$STATE/rootfs/." "$dir/"
SHIM
  cat > "$TEST_DIR/bin/umount" <<'SHIM'
#!/usr/bin/env bash
echo "umount $*" >> "$SHIM_LOG"
dir="${*: -1}"
rm -rf "$STATE/rootfs"
mkdir -p "$STATE/rootfs"
cp -a "$dir/." "$STATE/rootfs/"
find "$dir" -mindepth 1 -delete
SHIM
  # install: the real one, without -o/-g (the tests do not run as root).
  cat > "$TEST_DIR/bin/install" <<'SHIM'
#!/usr/bin/env bash
echo "install $*" >> "$SHIM_LOG"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o | -g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

SEED_DIR=var/lib/cloud/seed/nocloud

seed_json() {
  printf '%s' '{"user_data":"#cloud-config\nhostname: p1\n","network_config":"version: 2\n"}'
}

@test "writes user-data, network-config and a default meta-data; last line SEED with the sizes" {
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/rootfs/$SEED_DIR/user-data")" = "$(printf '#cloud-config\nhostname: p1')" ]
  [ "$(cat "$STATE/rootfs/$SEED_DIR/network-config")" = "version: 2" ]
  [ "$(cat "$STATE/rootfs/$SEED_DIR/meta-data")" = "$(printf 'instance-id: vm1\nlocal-hostname: vm1')" ]
  [ "${lines[-1]}" = "SEED vm1 written user-data=27 meta-data=37 network-config=11" ]
  [ "$(stat -c %a "$STATE/rootfs/$SEED_DIR/user-data")" = 600 ]
}

@test "finds partition 1 read-only (partx -g), checks ext4 at its offset, mounts at the offset and unmounts" {
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 0 ]
  grep -qF "partx -g -n 1 -o START,SECTORS -- $DISK" "$SHIM_LOG"
  grep -qF "blkid -p -O $((262144 * 512)) -o value -s TYPE -- $DISK" "$SHIM_LOG"
  grep -qE "^mount -t ext4 -o loop,offset=$((262144 * 512)),sizelimit=$((6027264 * 512)),nodev,nosuid,noexec -- $DISK " "$SHIM_LOG"
  grep -q '^umount ' "$SHIM_LOG"
  [ "$(awk '{print $1}' "$SHIM_LOG" | paste -sd' ' -)" = "virsh partx blkid mount install install install install umount" ]
  [ ! -e "$HPS_RUN/seed.$$" ]
  run ls "$HPS_RUN"
  [ -z "$output" ]
}

@test "--partition picks another partition" {
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" --partition 2 < <(seed_json)
  [ "$status" -eq 0 ]
  grep -qF "partx -g -n 2 " "$SHIM_LOG"
}

@test "a given meta_data is written as it is; no network_config: none written, an old one removed" {
  mkdir -p "$STATE/rootfs/$SEED_DIR"
  echo old > "$STATE/rootfs/$SEED_DIR/network-config"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(printf '%s' '{"user_data":"#cloud-config\n","meta_data":"instance-id: x1\n"}')
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/rootfs/$SEED_DIR/meta-data")" = "instance-id: x1" ]
  [ ! -e "$STATE/rootfs/$SEED_DIR/network-config" ]
  [[ "${lines[-1]}" == *"network-config=-" ]]
}

@test "idempotent: a second run writes the same files" {
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 0 ]
  first=$(cat "$STATE/rootfs/$SEED_DIR/user-data")
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/rootfs/$SEED_DIR/user-data")" = "$first" ]
}

@test "bad input is refused (3) before any mount" {
  local doc
  for doc in 'not json' '[]' '{}' '{"user_data":""}' '{"user_data":5}' '{"user_data":"x","network_config":true}' \
    '{"user_data":"x","meta_data":["a"]}' '{"user_data":"x","vendor_data":"y"}'; do
    : > "$SHIM_LOG"
    run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(printf '%s' "$doc")
    [ "$status" -eq 3 ]
    run ! grep -q '^mount' "$SHIM_LOG"
  done
}

@test "a running guest blocks the write (3); a shut-off one is fine" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  [[ "$output" == *"in use"* ]]
  run ! grep -q '^mount' "$SHIM_LOG"
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 0 ]
}

@test "no such partition, or not ext4, is refused (3) and nothing is mounted" {
  touch "$STATE/no-partition"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  [[ "$output" == *"no partition 1"* ]]
  rm "$STATE/no-partition"
  echo xfs > "$STATE/fstype"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  [[ "$output" == *"not ext4"* ]]
  run ! grep -q '^mount' "$SHIM_LOG"
}

@test "a filesystem without /etc is not a root filesystem (3), and is unmounted" {
  rm -rf "$STATE/rootfs/etc"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a root filesystem"* ]]
  grep -q '^umount' "$SHIM_LOG"
}

@test "a symlink on the seed path is refused (3): the guest never redirects a write" {
  mkdir -p "$STATE/rootfs/var/lib/cloud"
  ln -s /tmp "$STATE/rootfs/var/lib/cloud/seed"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  [[ "$output" == *"symlink"* ]]
  run ! grep -q '^install' "$SHIM_LOG"
  rm "$STATE/rootfs/var/lib/cloud/seed"
  mkdir -p "$STATE/rootfs/$SEED_DIR"
  ln -s /etc/passwd "$STATE/rootfs/$SEED_DIR/user-data"
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
}

@test "usage errors exit 2; refusals of the arguments exit 3" {
  run bash "$S/vm-seed-write"
  [ "$status" -eq 2 ]
  run bash "$S/vm-seed-write" vm1
  [ "$status" -eq 2 ]
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" --bogus
  [ "$status" -eq 2 ]
  run bash "$S/vm-seed-write" vm1 --disk "$DISK" --partition 0
  [ "$status" -eq 2 ]
  run bash "$S/vm-seed-write" VM1 --disk "$DISK" < <(seed_json)
  [ "$status" -eq 3 ]
  run bash "$S/vm-seed-write" vm1 --disk /etc/hosts < <(seed_json)
  [ "$status" -eq 3 ]
  run bash "$S/vm-seed-write" vm1 --disk "$HPS_DEV/md/none" < <(seed_json)
  [ "$status" -eq 3 ]
}

@test "wiring: allowlisted under profile node with input raw, executable, shellcheck clean, no library sourcing" {
  local nix="$S/../../../nix/modules/hps-ctrl-exec.nix"
  grep -qF 'vm-seed-write.source = mkScript "vm-seed-write" (scriptsDir + "/vm-seed-write");' "$nix"
  grep -qF 'vm-seed-write.options.profile = "node";' "$nix"
  grep -qF 'vm-seed-write.options.input = "raw";' "$nix"
  [ -x "$S/vm-seed-write" ]
  [ "$(head -1 "$S/vm-seed-write")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$S/vm-seed-write"
  shellcheck -S warning "$S/vm-seed-write"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-seed-write' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  # It never writes a disk itself: no qemu-img, dd, mkfs, wipefs or partition change.
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-seed-write' | grep -E '(^|[ (])(qemu-img|dd|wipefs|mkfs[.a-z0-9]*|sfdisk|sgdisk|parted|kpartx|losetup)[ ]'"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-seed-write' | grep -E 'partx -[ad]'"
  grep -q 'vm-seed-write' "$S/../../../docs/VM-LIFECYCLE.md"
}
