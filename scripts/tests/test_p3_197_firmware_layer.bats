#!/usr/bin/env bats
#
# The audit image's firmware as a layer of its own (owner go-ahead 2026-11-11):
#   - wiring: the audit image carries no firmware in its store, mounts the
#     layer before udev and points firmware_class at it; the layer derivation
#     exists and node images have none;
#   - nix/build.sh publishes the layer once under <out>/firmware/, shared by
#     pins, and names it in the audit boot.json (extra_initrds) and SHA256SUMS;
#   - nixos_boot_lines emits one initrd line per entry; a boot.json without
#     extra_initrds (every older pin) boots as before;
#   - hps-pins verify / prune / list and nixos-prune-pins.sh with layers.
# The Perl unit tests are t/197-firmware-layer.t, run from here as well.

# shellcheck disable=SC2030,SC2031  # exports in setup and in tests are per test
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-197.XXXXXX")"
  export TEST_DIR
  SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ROOT="$SRC"
  AUDIT="$SRC/nix/modules/hps-audit.nix"
  LAYER_NIX="$SRC/nix/pkgs/hps-firmware-layer.nix"
  BUILD="$SRC/nix/build.sh"
  PINS="$SRC/bin/hps-pins"
  export NIX_LOG="$TEST_DIR/nix.log"
  export FAKE_STORE="$TEST_DIR/store"
  export OUT="$TEST_DIR/out"
  export CACHE="$TEST_DIR/cache"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$FAKE_STORE" "$OUT"

  export HPS_CONFIG_BASE="$TEST_DIR/config"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/config/system.db"
  export HPS_RESOURCES="$TEST_DIR"
  export HPS_PINS_NO_SYSLOG=1
  mkdir -p "$HPS_CONFIG_BASE/clusters/lab/cluster.db" "$HPS_CONFIG_BASE/clusters/lab/hosts"
  ln -s "$OUT" "$TEST_DIR/nixos"

  # Fake nix: like test_p1_40's, and the audit profile also gets firmware.cpio
  # from a store path named after FW_TAG (one tag = one layer content).
  cat > "$TEST_DIR/bin/nix" <<'SHIM'
#!/bin/bash
echo "$*" >> "$NIX_LOG"
sub=""
for a in "$@"; do
  case "$a" in build|flake|copy) sub="$a"; break ;; esac
done
case "$sub" in
  flake)
    echo '{"locks":{"nodes":{"nixpkgs":{"locked":{"rev":"0123456789abcdef0123456789abcdef01234567"}}}}}'
    ;;
  build)
    inst=""; link=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out-link) link="$2"; shift 2 ;;
        *'#'*) inst="$1"; shift ;;
        *) shift ;;
      esac
    done
    profile="${inst##*#}"
    if [[ "$profile" == ipxe ]]; then
      store="$FAKE_STORE/hps-ipxe"
      mkdir -p "$store"
      for n in snponly.efi ipxe.efi undionly.kpxe; do echo "ipxe-$n" > "$store/$n"; done
      echo '{"version":"2.0.0","files":["snponly.efi","ipxe.efi","undionly.kpxe"],"nixpkgs_rev":"0123456789abcdef0123456789abcdef01234567"}' > "$store/ipxe.json"
      ln -sfn "$store" "$link"
      exit 0
    fi
    store="$FAKE_STORE/hps-netboot-$profile-${BUILD_TAG:-1}"
    rm -rf "$store"
    mkdir -p "$store"
    echo "kernel-$profile-${BUILD_TAG:-1}" > "$store/bzImage"
    echo "initrd-$profile-${BUILD_TAG:-1}" > "$store/initrd"
    extra=""
    if [[ "$profile" == audit && -z "${FAKE_NO_LAYER:-}" ]]; then
      fw="$FAKE_STORE/$(printf '%032d' "${FW_TAG:-1}")-hps-firmware-layer-test"
      mkdir -p "$fw"
      [[ -f "$fw/firmware.cpio" ]] || echo "firmware-layer-${FW_TAG:-1}" > "$fw/firmware.cpio"
      ln -s "$fw/firmware.cpio" "$store/firmware.cpio"
      extra=",\"firmware_layer\":\"${FAKE_LAYER_NAME:-firmware.cpio}\""
    fi
    printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/aaaa-nixos-system-%s-%s/init","cmdline":"initrd=initrd console=ttyS1","nixpkgs_rev":"0123456789abcdef0123456789abcdef01234567","nixos_version":"26.05","profile":"%s"%s}\n' \
      "$profile" "${BUILD_TAG:-1}" "$profile" "$extra" > "$store/boot.json"
    ln -sfn "$store" "$link"
    ;;
  copy) : ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/nix"
  cat > "$TEST_DIR/bin/nix-store" <<'SHIM'
#!/bin/bash
echo "nix-store $*" >> "$NIX_LOG"
if [[ "$1" == --verify-path && -n "${FAKE_VERIFY_BAD:-}" && "$2" == *"$FAKE_VERIFY_BAD"* ]]; then
  echo "path '$2' was modified!" >&2
  exit 1
fi
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/nix-store"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# reg_set <host MAC | system | cluster> <key> <value>, through HPS::Registry.
reg_set() {
  perl -I"$SRC/lib/perl" -MHPS::Registry -e '
    my ($kind, $key, $v) = @ARGV;
    my $r = HPS::Registry->new;
    if ($kind eq "system")     { $r->system_set($key, $v) }
    elsif ($kind eq "cluster") { $r->cluster_set("lab", $key, $v) }
    else                       { $r->host_set($kind, $key, $v) }
  ' "$1" "$2" "$3"
}

# build_pin <date> [build tag] [firmware tag]: one build.sh run; sets PIN.
build_pin() {
  BUILD_TAG="${2:-1}" FW_TAG="${3:-1}" run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date "$1"
  [ "$status" -eq 0 ]
  PIN="$(cat "$OUT/latest")"
}

layer_name() {
  printf '%032d-hps-firmware-layer-test.cpio' "${1:-1}"
}

#--- wiring -------------------------------------------------------------------

@test "perl unit tests for the firmware layer (HPS::Pins, HPS::CnhPublish) pass" {
  run prove -I "$SRC/lib/perl" "$SRC/t/197-firmware-layer.t"
  [ "$status" -eq 0 ]
}

@test "the audit image's own store carries no firmware: hardware.firmware forced empty" {
  grep -q '^  hardware.firmware = lib.mkForce \[ \];' "$AUDIT"
  grep -q '^  hardware.enableRedistributableFirmware = lib.mkForce false;' "$AUDIT"
  # no linux-firmware in any hardware.firmware definition
  run grep -E '^[^#]*hardware\.firmware *=.*linux-firmware' "$AUDIT"
  [ "$status" -eq 1 ]
  run grep -E '^[^#]*enableAllFirmware *= *true' "$AUDIT"
  [ "$status" -eq 1 ]
}

@test "the firmware layer derivation exists and the audit image exposes it" {
  [ -f "$LAYER_NIX" ]
  grep -q 'compressFirmwareZstd linux-firmware' "$LAYER_NIX"
  grep -q -- '-comp zstd -Xcompression-level 6' "$LAYER_NIX"
  grep -q "printf 'firmware.squashfs\\\\0'" "$LAYER_NIX"
  grep -q -- 'cpio --quiet -o -H newc' "$LAYER_NIX"
  grep -q 'firmware.cpio' "$LAYER_NIX"
  grep -q 'pkgs.callPackage ../pkgs/hps-firmware-layer.nix' "$AUDIT"
  grep -q 'system.build.hpsFirmwareLayer = firmwareLayer;' "$AUDIT"
}

@test "the audit initrd mounts the layer before udev and firmware_class points at it" {
  grep -q 'what = "/firmware.squashfs";' "$AUDIT"
  grep -q 'firmwareDir = "/run/hps-firmware";' "$AUDIT"
  grep -q 'type = "squashfs";' "$AUDIT"
  grep -q 'before = \[ "sysinit.target" "systemd-udev-trigger.service" \];' "$AUDIT"
  grep -q 'after = \[ "systemd-modules-load.service" \];' "$AUDIT"
  grep -q 'boot.kernelParams = \[ "firmware_class.path=${firmwareDir}" \];' "$AUDIT"
  # NixOS's udevd activation rewrites the path; ours runs after it
  grep -q 'deps = \[ "udevd" \];' "$AUDIT"
  grep -q 'echo -n ${firmwareDir} > /sys/module/firmware_class/parameters/path' "$AUDIT"
}

@test "flake: a profile with a layer links firmware.cpio and names it in boot.json" {
  grep -q 'firmwareLayer = cfg.system.build.hpsFirmwareLayer or null;' "$SRC/flake.nix"
  grep -q 'firmware_layer = "firmware.cpio";' "$SRC/flake.nix"
  grep -q 'ln -s ${firmwareLayer}/firmware.cpio "$out/firmware.cpio"' "$SRC/flake.nix"
  grep -q 'firmware-layer = self.nixosConfigurations.audit.config.system.build.hpsFirmwareLayer;' "$SRC/flake.nix"
}

@test "node images (base, converged, cnh) get no firmware and no layer" {
  run grep -rlE 'hardware\.firmware|hpsFirmwareLayer|hps-firmware-layer|linux-firmware' \
    "$SRC/nix/modules/hps-common.nix" "$SRC/nix/modules/hps-node.nix" "$SRC/nix/modules/profiles"
  [ "$status" -eq 1 ]
}

#--- build.sh -----------------------------------------------------------------

@test "build.sh publishes the layer once under firmware/, not in the pin" {
  build_pin 20261109
  fw="$OUT/firmware/$(layer_name 1)"
  [ -f "$fw" ]
  [ ! -L "$fw" ]
  [ "$(cat "$fw")" = "firmware-layer-1" ]
  [ -z "$(find "$OUT/$PIN" -name '*.cpio')" ]
  [ -z "$(find "$OUT/firmware" -name '.*')" ]
}

@test "the audit boot.json names the layer in extra_initrds with its sha256 and size" {
  build_pin 20261109
  f="$OUT/$PIN/audit/boot.json"
  fw="$OUT/firmware/$(layer_name 1)"
  sha="$(sha256sum "$fw" | cut -d' ' -f1)"
  jq -e --arg p "firmware/$(layer_name 1)" --arg sha "$sha" --argjson n "$(stat -c %s "$fw")" \
    '.extra_initrds == [{path: $p, sha256: $sha, size: $n}]' "$f"
  jq -e 'has("firmware_layer") | not' "$f"
  # the other keys are as before
  jq -e '.initrd == "initrd" and (.sha256.initrd | length == 64)' "$f"
  for p in node-base node-converged node-cnh; do
    jq -e 'has("extra_initrds") | not' "$OUT/$PIN/$p/boot.json"
  done
}

@test "SHA256SUMS lists the layer as ../firmware/<file> and sha256sum -c accepts it" {
  build_pin 20261109
  grep -q "  ../firmware/$(layer_name 1)\$" "$OUT/$PIN/SHA256SUMS"
  run grep -c . "$OUT/$PIN/SHA256SUMS"
  [ "$output" = 12 ]
  cd "$OUT/$PIN"
  run sha256sum --check --quiet SHA256SUMS
  [ "$status" -eq 0 ]
}

@test "a second pin with the same layer shares the file and does not rewrite it" {
  build_pin 20261109 1 1
  first="$PIN"
  inode="$(stat -c %i "$OUT/firmware/$(layer_name 1)")"
  build_pin 20261110 2 1
  [ "$PIN" != "$first" ]
  [ "$(find "$OUT/firmware" -type f | wc -l)" -eq 1 ]
  [ "$(stat -c %i "$OUT/firmware/$(layer_name 1)")" = "$inode" ]
  grep -q 'firmware layer unchanged' <<< "$output"
  jq -e --arg p "firmware/$(layer_name 1)" '.extra_initrds[0].path == $p' "$OUT/$first/audit/boot.json"
  jq -e --arg p "firmware/$(layer_name 1)" '.extra_initrds[0].path == $p' "$OUT/$PIN/audit/boot.json"
}

@test "a published layer that differs from the store is replaced" {
  build_pin 20261109
  echo damaged > "$OUT/firmware/$(layer_name 1)"
  build_pin 20261109
  [ "$(cat "$OUT/firmware/$(layer_name 1)")" = "firmware-layer-1" ]
}

@test "a new layer is a new file and a new pin, even with the same systems" {
  build_pin 20261109 1 1
  first="$PIN"
  build_pin 20261109 1 2
  [ "$PIN" != "$first" ]
  [ -f "$OUT/firmware/$(layer_name 1)" ]
  [ -f "$OUT/firmware/$(layer_name 2)" ]
  jq -e --arg p "firmware/$(layer_name 2)" '.extra_initrds[0].path == $p' "$OUT/$PIN/audit/boot.json"
}

@test "without a layer the pin is computed as before (old builds keep their pin names)" {
  FAKE_NO_LAYER=1 build_pin 20261109
  suffix="$(for p in audit node-base node-converged node-cnh; do
    printf '%s /nix/store/aaaa-nixos-system-%s-1/init\n' "$p" "$p"
  done | sha256sum | cut -c1-7)"
  [ "$PIN" = "nixos-26.05-20261109-0123456-$suffix" ]
  [ ! -e "$OUT/firmware" ]
  jq -e 'has("extra_initrds") | not' "$OUT/$PIN/audit/boot.json"
}

@test "a damaged layer store path fails the build before latest is written" {
  FAKE_VERIFY_BAD=hps-firmware-layer run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed verification"* ]]
  [ ! -e "$OUT/latest" ]
  [ -z "$(find "$OUT" -name '*.cpio')" ]
}

@test "a firmware_layer that names no file, or no plain file name, fails the build" {
  FAKE_LAYER_NAME=missing.cpio run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"names firmware_layer missing.cpio"* ]]
  [ ! -e "$OUT/latest" ]
  FAKE_LAYER_NAME=../x run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a plain file name"* ]]
}

#--- boot lines -----------------------------------------------------------------

boot_setup() {
  load p1_50_helpers
  # shellcheck source=/dev/null
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  ipxe_header() { printf '#!ipxe\n'; }
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
}

# two_initrd_manifest <pin> <extra_initrds json>
two_initrd_manifest() {
  local dir="$TEST_DIR/res/nixos/$1/audit"
  mkdir -p "$dir"
  printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/abc-system/init","cmdline":"initrd=initrd console=ttyS1","profile":"audit","pin":"%s","extra_initrds":%s}\n' \
    "$1" "$2" > "$dir/boot.json"
}

@test "boot lines: a two-initrd boot.json gives the image initrd, then the layer" {
  boot_setup
  name="$(layer_name 1)"
  mkdir -p "$TEST_DIR/res/nixos/firmware"
  echo fw > "$TEST_DIR/res/nixos/firmware/$name"
  two_initrd_manifest p1 "[{\"path\":\"firmware/$name\",\"sha256\":\"x\",\"size\":3}]"
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == "kernel http://10.0.0.1/nixos/p1/audit/bzImage initrd=initrd console=ttyS1 init=/nix/store/abc-system/init initrd=$name hps.ips=10.0.0.1 "* ]]
  [ "${lines[1]}" = "initrd http://10.0.0.1/nixos/p1/audit/initrd" ]
  [ "${lines[2]}" = "initrd http://10.0.0.1/nixos/firmware/$name" ]
  [ "${lines[3]}" = "boot" ]
}

@test "boot lines: today's single-initrd boot.json boots exactly as before" {
  boot_setup
  p1_50_manifest p1 audit "initrd=initrd console=ttyS1"
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[1]}" = "initrd http://10.0.0.1/nixos/p1/audit/initrd" ]
  [ "${lines[2]}" = "boot" ]
  [ "$(grep -o 'initrd=' <<< "${lines[0]}" | wc -l)" -eq 1 ]
  # an empty list is the same as none
  two_initrd_manifest p2 '[]'
  run nixos_boot_lines "$MAC" audit p2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "boot lines refuse a layer that is not published, or a path outside firmware/" {
  boot_setup
  two_initrd_manifest p1 '[{"path":"firmware/gone.cpio"}]'
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 1 ]
  grep -q "extra initrd $TEST_DIR/res/nixos/firmware/gone.cpio is missing" "$TEST_DIR/hps.log"
  run nixos_emit_boot "$MAC" audit p1
  [[ "$output" == *"FAIL: NixOS boot unavailable"* ]]
  [[ "$output" != *"kernel "* ]]
  for bad in '../p1/audit/initrd' '/etc/passwd' 'other/x.cpio' 'firmware/../x' 'firmware/'; do
    two_initrd_manifest p1 "[{\"path\":\"$bad\"}]"
    run nixos_boot_lines "$MAC" audit p1
    [ "$status" -eq 1 ]
  done
  two_initrd_manifest p1 '[{}]'
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 1 ]
  two_initrd_manifest p1 '"firmware/x.cpio"'
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 1 ]
  grep -q 'extra_initrds is not a list' "$TEST_DIR/hps.log"
}

@test "ipxe_boot_audit serves both initrds in one script (imgfree first)" {
  boot_setup
  name="$(layer_name 1)"
  mkdir -p "$TEST_DIR/res/nixos/firmware"
  echo fw > "$TEST_DIR/res/nixos/firmware/$name"
  two_initrd_manifest p1 "[{\"path\":\"firmware/$name\"}]"
  printf 'p1' > "$TEST_DIR/cluster/nixos_default_pin"
  run ipxe_boot_audit "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'imgfree\nkernel http://10.0.0.1/nixos/p1/audit/bzImage '* ]]
  [[ "$output" == *$'\ninitrd http://10.0.0.1/nixos/p1/audit/initrd\ninitrd http://10.0.0.1/nixos/firmware/'"$name"$'\nboot'* ]]
}

#--- pins ---------------------------------------------------------------------

@test "hps-pins verify checks the layer; damage names firmware/<file>" {
  reg_set system ACTIVE_CLUSTER lab
  build_pin 20261109
  run "$PINS" verify "$PIN"
  [ "$status" -eq 0 ]
  [ "$output" = "OK $PIN" ]
  fw="$OUT/firmware/$(layer_name 1)"
  printf 'XXXXXXXXXXXXXXXX' > "$fw"
  run "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"FAIL $PIN: firmware/$(layer_name 1): size 16"* ]]
  rm -f "$fw"
  run "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"FAIL $PIN: firmware/$(layer_name 1): missing"* ]]
}

@test "hps-pins list does not take firmware/ for a pin" {
  reg_set system ACTIVE_CLUSTER lab
  build_pin 20261109
  run "$PINS" list --json
  [ "$status" -eq 0 ]
  jq -e --arg pin "$PIN" '[.[].pin] == [$pin]' <<< "$output"
  run "$PINS" verify --all
  [ "$status" -eq 0 ]
}

@test "hps-pins prune keeps a layer a kept pin names and removes the unnamed one" {
  reg_set system ACTIVE_CLUSTER lab
  build_pin 20261101 1 1
  old="$PIN"
  build_pin 20261102 2 1
  build_pin 20261103 3 2
  latest="$PIN"
  touch -d '2 hours ago' "$OUT/firmware/"*.cpio
  # keep 0 previous: only latest (layer 2) stays, so layer 1 goes
  run "$PINS" prune --keep-previous 0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete firmware/$(layer_name 1) (no pin names it)"* ]]
  [[ "$output" == *"keep   firmware/$(layer_name 2) (named by $latest)"* ]]
  [ -f "$OUT/firmware/$(layer_name 1)" ]
  # a pin that names layer 1 is kept by a host: the layer stays
  reg_set 52:54:00:00:00:01 system_pin "$old"
  run "$PINS" prune --keep-previous 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   firmware/$(layer_name 1) (named by $old)"* ]]
  [ -f "$OUT/firmware/$(layer_name 1)" ]
  [ -d "$OUT/$old" ]
  # the host moves on: the pin and its layer go
  reg_set 52:54:00:00:00:01 system_pin "$latest"
  run "$PINS" prune --keep-previous 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted      firmware/$(layer_name 1) (no pin names it)"* ]]
  [ ! -e "$OUT/firmware/$(layer_name 1)" ]
  [ ! -e "$OUT/$old" ]
  [ -f "$OUT/firmware/$(layer_name 2)" ]
  run "$PINS" verify --all
  [ "$status" -eq 0 ]
}

@test "hps-pins prune keeps a just-written layer no pin names yet (a build in progress)" {
  reg_set system ACTIVE_CLUSTER lab
  build_pin 20261109
  echo partial > "$OUT/firmware/$(layer_name 9)"
  run "$PINS" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   firmware/$(layer_name 9) (written within the last 3600 s"* ]]
  [ -f "$OUT/firmware/$(layer_name 9)" ]
}

@test "hps-pins delete removes the pin and a layer only it named" {
  reg_set system ACTIVE_CLUSTER lab
  build_pin 20261101 1 1
  old="$PIN"
  build_pin 20261102 2 2
  touch -d '2 hours ago' "$OUT/firmware/"*.cpio
  run "$PINS" delete "$old"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted $old"* ]]
  [[ "$output" == *"deleted firmware/$(layer_name 1) (no pin names it)"* ]]
  [ -f "$OUT/firmware/$(layer_name 2)" ]
}

@test "nixos-prune-pins.sh never removes firmware/" {
  mkdir -p "$TEST_DIR/sys/lib"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOF2
hps_log() { :; }
hps_get_config() {
  case "\$1" in
    resources) echo "$TEST_DIR/res" ;;
    active_cluster) echo lab ;;
  esac
}
cluster_registry() { :; }
list_cluster_hosts() { :; }
host_registry() { :; }
EOF2
  mkdir -p "$TEST_DIR/res/nixos/pin-latest/audit" "$TEST_DIR/res/nixos/firmware"
  echo pin-latest > "$TEST_DIR/res/nixos/latest"
  echo fw > "$TEST_DIR/res/nixos/firmware/$(layer_name 1)"
  HPS_SYSTEM_PATH="$TEST_DIR/sys" run "$SRC/scripts/nixos-prune-pins.sh" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped   firmware (shared firmware layers"* ]]
  [ -f "$TEST_DIR/res/nixos/firmware/$(layer_name 1)" ]
}
