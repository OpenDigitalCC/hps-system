#!/usr/bin/env bats
#
# The image builder's node scripts (docs/BUILDER.md): builder-disk-prepare
# (format a blank device once, mount it), hps-builder-mount (boot: mount by
# label, never format), builder-build (fetch and check the source, start the
# build unit), hps-builder-run (the build itself, with nix and build.sh
# stubbed) and builder-status.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers
load p3_202_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-202.XXXXXX")"
  export TEST_DIR
  p3_202_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- builder-disk-prepare -------------------------------------------------------

@test "disk-prepare: a blank device is formatted ext4 labelled hps-builder, mounted, its directories made, the server started" {
  p3_202_blank vdb
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BUILDER-DISK $HPS_DEV/vdb formatted=yes mount=$MNT" ]
  grep -qxF "mkfs.ext4 -q -L hps-builder -m 0 -- $HPS_DEV/vdb" "$SHIM_LOG"
  grep -qxF "mount -t ext4 -o noatime -- $HPS_DEV/vdb $MNT" "$SHIM_LOG"
  for d in root out cache src inputs state tmp; do
    [ -d "$MNT/$d" ]
  done
  grep -qxF "systemctl start hps-builder-http.service" "$SHIM_LOG"
  # every command is logged on stderr
  [[ "$output" == *"+ mkfs.ext4 -q -L hps-builder"* ]]
}

@test "disk-prepare: a prepared disk is mounted and never formatted again; a second run changes nothing" {
  p3_202_blank vdb
  printf 'DEVNAME=%s\nLABEL=hps-builder\nTYPE=ext4\n' "$HPS_DEV/vdb" > "$STATE/sig.vdb"
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BUILDER-DISK $HPS_DEV/vdb formatted=no mount=$MNT" ]
  run ! grep -q mkfs "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BUILDER-DISK $HPS_DEV/vdb formatted=no mount=$MNT" ]
  run ! grep -qE '^(mkfs|mount )' "$SHIM_LOG"
}

@test "disk-prepare: a device with any other signature is refused and nothing is written" {
  local sig
  p3_202_blank vdb
  for sig in 'TYPE=ext4\nLABEL=hps-cnh' 'TYPE=zfs_member\nLABEL=lab' 'PTTYPE=gpt' 'TYPE=linux_raid_member'; do
    printf "DEVNAME=x\n$sig\n" > "$STATE/sig.vdb"
    : > "$SHIM_LOG"
    run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
    [ "$status" -eq 3 ]
    [[ "$output" == *"refused"* ]]
    run ! grep -qE '^(mkfs|mount )' "$SHIM_LOG"
  done
  echo 8 > "$STATE/sigrc.vdb"
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ambivalent"* ]]
}

@test "disk-prepare: a by-id path is taken; other device names and options are refused or usage" {
  p3_202_blank disk/by-id/virtio-builder0
  run bash "$S/builder-disk-prepare" "$HPS_DEV/disk/by-id/virtio-builder0"
  [ "$status" -eq 0 ]
  local d
  for d in "$HPS_DEV/vdb1" "$HPS_DEV/nvme0n1" "$HPS_DEV/disk/by-id/../vdb" /etc/passwd "$HPS_DEV/vdq"; do
    run bash "$S/builder-disk-prepare" "$d"
    [ "$status" -eq 3 ]
  done
  run bash "$S/builder-disk-prepare"
  [ "$status" -eq 2 ]
  run bash "$S/builder-disk-prepare" --force
  [ "$status" -eq 2 ]
}

@test "disk-prepare: a mount point mounted from another device, or holding files, is refused before any format" {
  p3_202_blank vdb
  p3_202_blank vdc
  p3_171_mount "$MNT" "$HPS_DEV/vdc"
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already mounted from $HPS_DEV/vdc"* ]]
  run ! grep -q mkfs "$SHIM_LOG"
  rm -f "$STATE/mounts"
  mkdir -p "$MNT/out"
  echo x > "$MNT/out/stray"
  run bash "$S/builder-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already holds files"* ]]
  run ! grep -q mkfs "$SHIM_LOG"
}

# --- hps-builder-mount ------------------------------------------------------------

@test "mount: no disk labelled hps-builder mounts nothing and succeeds" {
  run bash "$B/hps-builder-mount.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no disk labelled hps-builder"* ]]
  run ! grep -q '^mount ' "$SHIM_LOG"
}

@test "mount: the one labelled ext4 disk is mounted at /var/lib/hps-builder, never formatted; mounted already is left" {
  p3_202_blank vdb
  printf 'TYPE=ext4\nLABEL=hps-builder\n' > "$STATE/sig.vdb"
  echo "$HPS_DEV/vdb" > "$STATE/labelled"
  run bash "$B/hps-builder-mount.sh"
  [ "$status" -eq 0 ]
  grep -qxF "mount -t ext4 -o noatime -- $HPS_DEV/vdb $MNT" "$SHIM_LOG"
  run ! grep -q mkfs "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$B/hps-builder-mount.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already mounted"* ]]
  run ! grep -q '^mount ' "$SHIM_LOG"
}

@test "mount: two labelled disks, or a labelled disk that is not ext4, mount nothing and fail" {
  p3_202_blank vdb
  p3_202_blank vdc
  printf '%s\n%s\n' "$HPS_DEV/vdb" "$HPS_DEV/vdc" > "$STATE/labelled"
  run bash "$B/hps-builder-mount.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 disks are labelled"* ]]
  echo "$HPS_DEV/vdb" > "$STATE/labelled"
  printf 'TYPE=xfs\nLABEL=hps-builder\n' > "$STATE/sig.vdb"
  run bash "$B/hps-builder-mount.sh"
  [ "$status" -eq 1 ]
  run ! grep -q '^mount ' "$SHIM_LOG"
}

# --- builder-build ------------------------------------------------------------------

# a_source: a minimal hps-system tree served by the fake IPS; sets SUM.
a_source() {
  mkdir -p "$TEST_DIR/srctree/nix"
  echo '{ }' > "$TEST_DIR/srctree/flake.nix"
  printf '#!/bin/bash\necho build\n' > "$TEST_DIR/srctree/nix/build.sh"
  SUM=$(p3_202_source "$TEST_DIR/srctree")
}

# a_runner: HPS_BUILDER_RUN records its arguments and environment.
a_runner() {
  export HPS_BUILDER_RUN="$TEST_DIR/bin/fake-run"
  cat > "$HPS_BUILDER_RUN" <<'SHIM'
#!/usr/bin/env bash
echo "fake-run $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$HPS_BUILDER_RUN"
}

@test "build: fetches the source straight from the IPS, checks its sha256, unpacks it and starts the build unit" {
  p3_202_prepared
  a_source
  a_runner
  run bash "$S/builder-build" "$SUM"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" =~ ^BUILDER-BUILD\ started\ id=[0-9]{8}T[0-9]{6}Z\ source=${SUM:0:16}\ upstream=no\ unit=hps-builder-build\ log=$MNT/state/build-[0-9T]+Z\.log$ ]]
  grep -qE "^curl .*--noproxy \* .*http://10\.99\.1\.1/packages/cnh/hps-system-${SUM:0:16}\.tar\.gz$" "$SHIM_LOG"
  [ -f "$MNT/src/${SUM:0:16}/flake.nix" ]
  [ "$(cat "$MNT/src/${SUM:0:16}/.sha256")" = "$SUM" ]
  grep -qE "^systemd-run --quiet --collect --unit hps-builder-build --description HPS image build [0-9T]+Z --setenv PATH=.* -- $HPS_BUILDER_RUN --id [0-9T]+Z --mode build --src $MNT/src/${SUM:0:16}$" "$SHIM_LOG"
  # an unpacked source is used again, not fetched twice
  : > "$SHIM_LOG"
  run bash "$S/builder-build" "$SUM" --profiles "node-base node-builder"
  [ "$status" -eq 0 ]
  run ! grep -q '^curl ' "$SHIM_LOG"
  grep -qF -- "--src $MNT/src/${SUM:0:16} --profiles node-base node-builder" "$SHIM_LOG"
}

@test "build: inputs are fetched from packages/builder/ and handed to the runner" {
  p3_202_prepared
  a_source
  a_runner
  mkdir -p "$TEST_DIR/ce" "$TEST_DIR/cep"
  echo '{ }' > "$TEST_DIR/ce/flake.nix"
  echo plugins > "$TEST_DIR/cep/README.md"
  ce=$(p3_202_input ctrl-exec "$TEST_DIR/ce")
  cep=$(p3_202_input ctrl-exec-plugins "$TEST_DIR/cep")
  run bash "$S/builder-build" "$SUM" --input "ctrl-exec=$ce" --input "ctrl-exec-plugins=$cep"
  [ "$status" -eq 0 ]
  grep -qF "http://10.99.1.1/packages/builder/ctrl-exec-${ce:0:16}.tar.gz" "$SHIM_LOG"
  [ -f "$MNT/inputs/ctrl-exec-${ce:0:16}/flake.nix" ]
  grep -qF -- "--input ctrl-exec=$MNT/inputs/ctrl-exec-${ce:0:16} --input ctrl-exec-plugins=$MNT/inputs/ctrl-exec-plugins-${cep:0:16}" "$SHIM_LOG"
}

@test "build: a tarball whose sha256 is not the one asked for is refused, nothing unpacked, no build" {
  p3_202_prepared
  a_source
  a_runner
  other=$(printf 'f%.0s' {1..64})
  cp "$STATE/www/packages/cnh/hps-system-${SUM:0:16}.tar.gz" "$STATE/www/packages/cnh/hps-system-${other:0:16}.tar.gz"
  run bash "$S/builder-build" "$other"
  [ "$status" -eq 3 ]
  [[ "$output" == *"has sha256 $SUM, not $other"* ]]
  [ ! -e "$MNT/src/${other:0:16}" ]
  run ! grep -q '^systemd-run' "$SHIM_LOG"
}

@test "build: refused without a disk, while a build runs, without hps.ips, or with bad arguments" {
  a_source
  a_runner
  run bash "$S/builder-build" "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not mounted"* ]]
  p3_202_prepared
  echo active > "$STATE/unit-state"
  run bash "$S/builder-build" "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"a build is running"* ]]
  rm -f "$STATE/unit-state"
  echo "BOOT_IMAGE=bzImage hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  run bash "$S/builder-build" "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps.ips="* ]]
  run bash "$S/builder-build" "${SUM:0:63}"
  [ "$status" -eq 3 ]
  run bash "$S/builder-build" "$SUM" --profiles 'node-base ../x'
  [ "$status" -eq 3 ]
  run bash "$S/builder-build" "$SUM" --input "nixpkgs=$SUM"
  [ "$status" -eq 3 ]
  run bash "$S/builder-build" "$SUM" --input "ctrl-exec=$SUM" --input "ctrl-exec=$SUM"
  [ "$status" -eq 3 ]
  run bash "$S/builder-build"
  [ "$status" -eq 2 ]
  run bash "$S/builder-build" "$SUM" --bogus
  [ "$status" -eq 2 ]
  run ! grep -q '^systemd-run' "$SHIM_LOG"
}

# --- hps-builder-run ----------------------------------------------------------------

# a_build_tree: a source whose nix/build.sh records its arguments and the
# environment it got, then publishes a pin (FAKE_BUILD_RC fails it).
a_build_tree() {
  mkdir -p "$MNT/src/s1/nix"
  cat > "$MNT/src/s1/nix/build.sh" <<'EOF'
#!/bin/bash
echo "build.sh $*" >> "$SHIM_LOG"
echo "env https_proxy=${https_proxy:-} no_proxy=${no_proxy:-} NIX_REMOTE=${NIX_REMOTE:-} CTRL_EXEC_FLAKE=${CTRL_EXEC_FLAKE:-} TMPDIR=$TMPDIR" >> "$SHIM_LOG"
[[ "${FAKE_BUILD_RC:-0}" -eq 0 ]] || exit "$FAKE_BUILD_RC"
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == --out ]] && out=$2; shift; done
mkdir -p "$out/nixos-26.05-20261112-0123456-abcdef0"
echo nixos-26.05-20261112-0123456-abcdef0 > "$out/latest"
EOF
  cat > "$TEST_DIR/bin/nix" <<'SHIM'
#!/usr/bin/env bash
echo "nix $*" >> "$SHIM_LOG"
exit "${FAKE_COPY_RC:-0}"
SHIM
  cat > "$TEST_DIR/bin/nix-store" <<'SHIM'
#!/usr/bin/env bash
echo "nix-store $*" >> "$SHIM_LOG"
if [[ "$1" == --generate-binary-cache-key ]]; then
  echo "$2:c2VjcmV0" > "$3"
  echo "$2:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$4"
fi
SHIM
  chmod +x "$TEST_DIR/bin/nix" "$TEST_DIR/bin/nix-store"
  export HPS_BUILDER_NO_NS=1
  export HPS_BUILDER_SYSTEM="$TEST_DIR/system"
}

@test "run: copies the system closure into the disk store, runs the source's build.sh on the disk, records ok and the pin" {
  p3_202_prepared
  a_build_tree
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=http://10.99.1.2:3128 hps.profile=node-builder" > "$HPS_CMDLINE"
  run bash "$B/hps-builder-run.sh" --id 20261112T070000Z --src "$MNT/src/s1" --profiles "node-base" --input "ctrl-exec=$MNT/inputs/ce" --upstream
  [ "$status" -eq 0 ]
  grep -qxF "nix --extra-experimental-features nix-command flakes copy --no-check-sigs --to local?root=$MNT/root $TEST_DIR/system" "$SHIM_LOG"
  grep -qxF "build.sh --src $MNT/src/s1 --out $MNT/out --cache $MNT/repo/nix-cache --profiles node-base" "$SHIM_LOG"
  grep -qxF "env https_proxy=http://10.99.1.2:3128 no_proxy=10.99.1.1,localhost,127.0.0.1 NIX_REMOTE=local CTRL_EXEC_FLAKE=path:$MNT/inputs/ce TMPDIR=$MNT/tmp/20261112T070000Z" "$SHIM_LOG"
  jq -e '.id == "20261112T070000Z" and .state == "ok" and .rc == 0 and .pin == "nixos-26.05-20261112-0123456-abcdef0" and (.seconds | type == "number") and .finished_at != null' "$MNT/state/last.json"
  cmp "$MNT/state/last.json" "$MNT/state/20261112T070000Z.json"
  grep -q 'job 20261112T070000Z (build) ok: pin nixos-26.05-20261112-0123456-abcdef0' "$MNT/state/build-20261112T070000Z.log"
  grep -q 'egress through http://10.99.1.2:3128' "$MNT/state/build-20261112T070000Z.log"
  grep -q '^+ bash .*/nix/build.sh' "$MNT/state/build-20261112T070000Z.log"
  [ ! -e "$MNT/tmp/20261112T070000Z" ]
}

@test "run: a failing build is recorded failed with its exit status; without --upstream no proxy is set" {
  p3_202_prepared
  a_build_tree
  FAKE_BUILD_RC=4 run bash "$B/hps-builder-run.sh" --id 20261112T070000Z --src "$MNT/src/s1"
  [ "$status" -eq 4 ]
  jq -e '.state == "failed" and .rc == 4 and .pin == null' "$MNT/state/last.json"
  grep -q 'no upstream: no proxy set' "$MNT/state/build-20261112T070000Z.log"
  grep -q '^env https_proxy= ' "$SHIM_LOG"
  FAKE_BUILD_RC=4 run bash "$B/hps-builder-run.sh" --id 20261112T070001Z --src "$MNT/src/s1" --upstream
  grep -q 'no hps.proxy= on the kernel command line' "$MNT/state/build-20261112T070001Z.log"
}

@test "run: a failed closure copy fails the build before build.sh" {
  p3_202_prepared
  a_build_tree
  FAKE_COPY_RC=1 run bash "$B/hps-builder-run.sh" --id 20261112T070000Z --src "$MNT/src/s1"
  [ "$status" -eq 1 ]
  run ! grep -q '^build.sh' "$SHIM_LOG"
  jq -e '.state == "failed" and .rc == 1' "$MNT/state/last.json"
}

@test "run: bad arguments are usage" {
  p3_202_prepared
  a_build_tree
  run bash "$B/hps-builder-run.sh" --id 'x;y' --src "$MNT/src/s1"
  [ "$status" -eq 2 ]
  run bash "$B/hps-builder-run.sh" --id 20261112T070000Z --src "$TEST_DIR/none"
  [ "$status" -eq 2 ]
}

# --- builder-status -----------------------------------------------------------------

@test "status: no disk" {
  run bash "$S/builder-status"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BUILDER state=nodisk last=none result=none pin=- seconds=-" ]
}

@test "status: the last build, the pins with latest, the log tail" {
  p3_202_prepared
  mkdir -p "$MNT/out/nixos-a" "$MNT/out/nixos-b"
  echo nixos-b > "$MNT/out/latest"
  echo '{"id":"20261112T070000Z","state":"ok","rc":0,"pin":"nixos-b","seconds":312}' > "$MNT/state/last.json"
  printf 'line1\nline2\n' > "$MNT/state/build-20261112T070000Z.log"
  run bash "$S/builder-status" --log 1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BUILDER state=idle last=20261112T070000Z result=ok pin=nixos-b seconds=312" ]
  [[ "$output" == *"  nixos-b (latest)"* ]]
  [[ "$output" == *"  nixos-a"* ]]
  [[ "$output" == *"  line2"* ]]
  [[ "$output" != *"  line1"* ]]
}

@test "status: a running unit is running; a record left running by a gone build is failed (interrupted)" {
  p3_202_prepared
  echo '{"id":"20261112T070000Z","state":"running","rc":null,"pin":null,"seconds":5}' > "$MNT/state/last.json"
  echo active > "$STATE/unit-state"
  run bash "$S/builder-status"
  [ "${lines[-1]}" = "BUILDER state=running last=20261112T070000Z result=running pin=- seconds=5" ]
  rm -f "$STATE/unit-state"
  run bash "$S/builder-status"
  [ "${lines[-1]}" = "BUILDER state=idle last=20261112T070000Z result=failed pin=- seconds=5" ]
  [[ "$output" == *"interrupted"* ]]
}

@test "status: --log takes 0 to 2000 only" {
  run bash "$S/builder-status" --log 2001
  [ "$status" -eq 2 ]
  run bash "$S/builder-status" --log x
  [ "$status" -eq 2 ]
  run bash "$S/builder-status" --bogus
  [ "$status" -eq 2 ]
}
