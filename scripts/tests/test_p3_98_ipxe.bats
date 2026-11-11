#!/usr/bin/env bats
#
# IPS-09: a current, pinned iPXE built in the flake, published with the pin,
# verified by HPS::Pins and selected by the IPS bring-up. nix is a PATH shim
# (no nix on this host): the flake is checked as text, build.sh's publishing
# and the bring-up selection are exercised for real against the shim's output.
# Nothing here builds iPXE; the supervisor runs the flake check and the build.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-98.XXXXXX")"
  export TEST_DIR
  export NIX_LOG="$TEST_DIR/nix.log"
  export FAKE_STORE="$TEST_DIR/store"
  export OUT="$TEST_DIR/out"
  export CACHE="$TEST_DIR/cache"
  SRC="${BATS_TEST_DIRNAME}/../.."
  BUILD="$SRC/nix/build.sh"
  PINS="$SRC/bin/hps-pins"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$FAKE_STORE" "$OUT"

  # Registry and resources, all under the test dir.
  export HPS_CONFIG_BASE="$TEST_DIR/config"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/config/system.db"
  export HPS_RESOURCES="$TEST_DIR"
  export HPS_PINS_NO_SYSLOG=1
  export HPS_ONBOARD_NETCONF_CMD=""
  mkdir -p "$HPS_CONFIG_BASE/clusters/lab/cluster.db" "$HPS_CONFIG_BASE/clusters/lab/hosts"
  reg_set system ACTIVE_CLUSTER lab
  mkdir -p "$OUT"
  ln -s "$OUT" "$TEST_DIR/nixos"

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
    store="$FAKE_STORE/hps-netboot-$profile"
    mkdir -p "$store"
    echo "kernel-$profile-${BUILD_TAG:-1}" > "$store/bzImage"
    echo "initrd-$profile-${BUILD_TAG:-1}" > "$store/initrd"
    printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/aaaa-nixos-system-%s-%s/init","cmdline":"initrd=initrd","nixpkgs_rev":"0123456789abcdef0123456789abcdef01234567","nixos_version":"26.05","profile":"%s"}\n' \
      "$profile" "${BUILD_TAG:-1}" "$profile" > "$store/boot.json"
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
  echo "path '$2' was modified! expected hash 'sha256:x', got 'sha256:y'" >&2
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
    elsif ($kind eq "os")      { $r->os_set($key, "kernel", $v) }
    else                       { $r->host_set($kind, $key, $v) }
  ' "$1" "$2" "$3"
}

# shellcheck disable=SC2120  # the optional date argument is for callers that need another day
build_pin() {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date "${1:-20261109}"
  [ "$status" -eq 0 ]
  PIN="$(cat "$OUT/latest")"
}

# --- flake text -------------------------------------------------------------

@test "flake: an ipxe package and check built from pkgs.ipxe with exactly the three targets" {
  F="$SRC/flake.nix"
  grep -q 'pkgs.ipxe.override' "$F"
  grep -q 'enableDefaultPlatformTargets = false' "$F"
  grep -q '"bin-x86_64-efi/snponly.efi" = null' "$F"
  grep -q '"bin-x86_64-efi/ipxe.efi" = null' "$F"
  grep -q '"bin/undionly.kpxe" = null' "$F"
  grep -q 'firmwareBinary = "ipxe.efi"' "$F"
  grep -q 'ipxe = ipxeArtefacts;' "$F"
  # one checks.${system} set (a dynamic attribute may be defined only once)
  [ "$(grep -cE '^ *checks\.\$\{system\}' "$F")" -eq 1 ]
  grep -A3 'checks.\${system} = {' "$F" | grep -q 'ipxe = ipxeArtefacts;'
  run grep -c '" = null;' "$F"
  [ "$output" -eq 3 ]
}

@test "flake: no embedded script and no extra option, so nothing secret is built in" {
  run ! grep -q 'embedScript' "$SRC/flake.nix"
  run ! grep -q 'additionalOptions' "$SRC/flake.nix"
}

@test "dnsmasq chain contract is unchanged: snponly.efi, undionly.kpxe, cmd=init" {
  G="$SRC/lib/functions.d/create-config-dnsmasq.sh"
  grep -q '^dhcp-boot=tag:efi64,tag:!ipxe,snponly.efi$' "$G"
  grep -q '^dhcp-boot=tag:!efi64,tag:!ipxe,undionly.kpxe$' "$G"
  grep -q 'boot_manager.sh?cmd=init$' "$G"
}

# --- build.sh ---------------------------------------------------------------

@test "build.sh builds the ipxe output and publishes <pin>/ipxe with ipxe.json" {
  build_pin
  grep -q "build .*path:.*#ipxe --out-link" "$NIX_LOG"
  for f in snponly.efi ipxe.efi undionly.kpxe; do
    [ -s "$OUT/$PIN/ipxe/$f" ]
  done
  J="$OUT/$PIN/ipxe/ipxe.json"
  jq -e '.version == "2.0.0" and .pin == "'"$PIN"'" and (.built_at | length > 0)' "$J"
  jq -e '.files == ["snponly.efi","ipxe.efi","undionly.kpxe"]' "$J"
  want="$(sha256sum "$OUT/$PIN/ipxe/snponly.efi" | cut -d' ' -f1)"
  [ "$(jq -r '.sha256["snponly.efi"]' "$J")" = "$want" ]
  [ "$(jq -r '.size["undionly.kpxe"]' "$J")" = "$(stat -c %s "$OUT/$PIN/ipxe/undionly.kpxe")" ]
}

@test "build.sh lists the iPXE files in SHA256SUMS and sha256sum -c accepts it" {
  build_pin
  grep -q '  ipxe/snponly.efi$' "$OUT/$PIN/SHA256SUMS"
  grep -q '  ipxe/ipxe.efi$' "$OUT/$PIN/SHA256SUMS"
  grep -q '  ipxe/undionly.kpxe$' "$OUT/$PIN/SHA256SUMS"
  cd "$OUT/$PIN"
  run sha256sum -c SHA256SUMS
  [ "$status" -eq 0 ]
}

@test "build.sh records the iPXE version in every profile's boot.json" {
  build_pin
  for p in audit node-base node-converged node-cnh; do
    [ "$(jq -r '.ipxe.version' "$OUT/$PIN/$p/boot.json")" = "2.0.0" ]
  done
}

@test "build.sh verifies the ipxe store path and copies it to the binary cache" {
  build_pin
  grep -q "nix-store --verify-path $FAKE_STORE/hps-ipxe" "$NIX_LOG"
  grep -q "copy --to file://$CACHE $FAKE_STORE/hps-ipxe" "$NIX_LOG"
}

@test "a damaged ipxe store path fails the build: no latest" {
  FAKE_VERIFY_BAD=hps-ipxe run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed verification"* ]]
  [ ! -e "$OUT/latest" ]
}

@test "an ipxe output missing a target fails the build" {
  mv "$TEST_DIR/bin/nix" "$TEST_DIR/bin/nix.real"
  cat > "$TEST_DIR/bin/nix" <<'SHIM'
#!/bin/bash
"$(dirname "$0")/nix.real" "$@" || exit $?
for a in "$@"; do
  case "$a" in *'#ipxe') unlink "$FAKE_STORE/hps-ipxe/undionly.kpxe" ;; esac
done
SHIM
  chmod +x "$TEST_DIR/bin/nix"
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"undionly.kpxe"* ]]
  [ ! -e "$OUT/latest" ]
}

@test "build.sh is shellcheck-clean at warning level" {
  run shellcheck -S warning "$BUILD"
  [ "$status" -eq 0 ]
}

# --- HPS::Pins --------------------------------------------------------------

@test "pins: verify passes a pin with ipxe; ipxe is not listed as a profile" {
  build_pin
  run "$PINS" verify "$PIN"
  [ "$status" -eq 0 ]
  run "$PINS" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit,node-base,node-cnh,node-converged"* ]]
  [[ "$output" != *"ipxe"* ]]
}

@test "pins: verify fails a damaged iPXE file and names it" {
  build_pin
  echo corrupt > "$OUT/$PIN/ipxe/snponly.efi"
  run --separate-stderr "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == "FAIL $PIN: ipxe/snponly.efi: "* ]]
}

@test "pins: verify fails a missing iPXE file and a missing ipxe.json" {
  build_pin
  unlink "$OUT/$PIN/ipxe/undionly.kpxe"
  run --separate-stderr "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ipxe/undionly.kpxe: missing"* ]]
  unlink "$OUT/$PIN/ipxe/ipxe.json"
  run --separate-stderr "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ipxe/ipxe.json: missing"* ]]
}

@test "pins: a pin without an ipxe directory still verifies" {
  build_pin
  mv "$OUT/$PIN/ipxe" "$TEST_DIR/ipxe.away"
  grep -v ' ipxe/' "$OUT/$PIN/SHA256SUMS" > "$TEST_DIR/sums"
  cp "$TEST_DIR/sums" "$OUT/$PIN/SHA256SUMS"
  run "$PINS" verify "$PIN"
  [ "$status" -eq 0 ]
}

# --- IPS bring-up -----------------------------------------------------------

bringup_setup() {
  export RES="$TEST_DIR/res"
  mkdir -p "$RES" "$TEST_DIR/sys/tftp"
  ln -s "$OUT" "$RES/nixos"
  for f in undionly.kpxe ipxe.efi snponly.efi; do
    echo "debian-$f" > "$TEST_DIR/sys/tftp/$f"
  done
  export LOG="$TEST_DIR/log"
  : > "$LOG"
  hps_log() { echo "$*" >> "$LOG"; }
  hps_get_config() {
    case "$1" in
      system_base) echo "$TEST_DIR/sys" ;;
      tftp)        echo "$TEST_DIR/tftp" ;;
      resources)   echo "$RES" ;;
    esac
  }
  export -f hps_log hps_get_config
  source "$SRC/lib/functions.d/supervisor-functions.sh"
}

@test "bring-up copies the latest pin's iPXE into the TFTP root" {
  build_pin
  bringup_setup
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  for f in snponly.efi ipxe.efi undionly.kpxe; do
    cmp "$OUT/$PIN/ipxe/$f" "$TEST_DIR/tftp/$f"
  done
  grep -q "using iPXE 2.0.0 from pin $PIN" "$LOG"
  run ! grep -q 'Debian' "$LOG"
}

@test "bring-up is idempotent and refreshes a stale TFTP file with the pin's" {
  build_pin
  bringup_setup
  supervisor_populate_tftp
  : > "$LOG"
  run supervisor_populate_tftp
  grep -q '0 file(s) copied' "$LOG"
  echo "debian-snponly.efi" > "$TEST_DIR/tftp/snponly.efi"
  : > "$LOG"
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  grep -q '1 file(s) copied' "$LOG"
  cmp "$OUT/$PIN/ipxe/snponly.efi" "$TEST_DIR/tftp/snponly.efi"
}

@test "bring-up falls back to the image's iPXE, logged, when the latest pin has none" {
  build_pin
  mv "$OUT/$PIN/ipxe" "$TEST_DIR/ipxe.away"
  bringup_setup
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/tftp/snponly.efi")" = "debian-snponly.efi" ]
  grep -q "has no ipxe/ipxe.json; using the image's iPXE (Debian)" "$LOG"
}

@test "bring-up falls back, logged, when there is no latest pin" {
  bringup_setup
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/tftp/undionly.kpxe")" = "debian-undionly.kpxe" ]
  grep -q "no latest pin; using the image's iPXE (Debian)" "$LOG"
}

@test "bring-up never serves a pin iPXE that fails its sha256: the image's is used, logged" {
  build_pin
  echo corrupt > "$OUT/$PIN/ipxe/ipxe.efi"
  bringup_setup
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/tftp/snponly.efi")" = "debian-snponly.efi" ]
  grep -q "ipxe/ipxe.efi sha256 .*using the image's iPXE (Debian)" "$LOG"
}
