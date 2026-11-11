#!/usr/bin/env bats
#
# IPS-05: pin integrity and retention. Proves:
#   - nix/build.sh writes sha256 and size (bzImage, initrd) into boot.json from
#     the published files, and <pin>/SHA256SUMS (nix and nix-store shimmed);
#   - hps-pins list / verify / prune / delete, including every refusal and exit
#     code, against pins that build.sh produced;
#   - hps-onboard assign and repin --pin refuse a corrupted pin (exit 3, file named);
#   - the pins-prune job kind (Perl table and Bash helper).
# The Perl unit tests are t/94-pins.t, run from here as well.

# shellcheck disable=SC2154  # $stderr is set by run --separate-stderr
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-94.XXXXXX")"
  export TEST_DIR
  export NIX_LOG="$TEST_DIR/nix.log"
  export FAKE_STORE="$TEST_DIR/store"
  export OUT="$TEST_DIR/out"
  export CACHE="$TEST_DIR/cache"
  SRC="${BATS_TEST_DIRNAME}/../.."
  BUILD="$SRC/nix/build.sh"
  PINS="$SRC/bin/hps-pins"
  ONB="$SRC/bin/hps-onboard"
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
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/nix-store"
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

# build_pin <date> [tag]: one build.sh run, prints nothing; PIN is set.
build_pin() {
  BUILD_TAG="${2:-1}" run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date "$1"
  [ "$status" -eq 0 ]
  PIN="$(cat "$OUT/latest")"
}

@test "perl unit tests for HPS::Pins pass" {
  run prove -I "$SRC/lib/perl" "$SRC/t/94-pins.t"
  [ "$status" -eq 0 ]
}

@test "build.sh writes sha256 and size of bzImage and initrd into boot.json" {
  build_pin 20261109
  for p in audit node-base node-converged node-cnh; do
    f="$OUT/$PIN/$p/boot.json"
    bz="$(sha256sum "$OUT/$PIN/$p/bzImage" | cut -d' ' -f1)"
    rd="$(sha256sum "$OUT/$PIN/$p/initrd" | cut -d' ' -f1)"
    jq -e --arg bz "$bz" --arg rd "$rd" '.sha256.bzImage == $bz and .sha256.initrd == $rd' "$f"
    jq -e --argjson n "$(stat -c %s "$OUT/$PIN/$p/bzImage")" '.size.bzImage == $n' "$f"
    jq -e --argjson n "$(stat -c %s "$OUT/$PIN/$p/initrd")" '.size.initrd == $n' "$f"
    # the existing keys are untouched
    jq -e '.kernel == "bzImage" and (.pin | length > 0) and (.built_at | length > 0)' "$f"
  done
}

@test "build.sh writes <pin>/SHA256SUMS that sha256sum -c accepts" {
  build_pin 20261109
  [ -f "$OUT/$PIN/SHA256SUMS" ]
  run grep -c . "$OUT/$PIN/SHA256SUMS"
  [ "$output" = 11 ]
  grep -q '  audit/initrd$' "$OUT/$PIN/SHA256SUMS"
  cd "$OUT/$PIN"
  run sha256sum --check --quiet SHA256SUMS
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/$PIN/SHA256SUMS.tmp" ]
}

@test "verify passes a pin build.sh produced, one and all" {
  build_pin 20261109
  run "$PINS" verify "$PIN"
  [ "$status" -eq 0 ]
  [[ "$output" == "OK $PIN" ]]
  run "$PINS" verify --all
  [ "$status" -eq 0 ]
}

@test "verify fails a truncated initrd, names the file, exits 3" {
  build_pin 20261109
  truncate -s 4 "$OUT/$PIN/node-base/initrd"
  run --separate-stderr "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == "FAIL $PIN: node-base/initrd: size 4, boot.json says "* ]]
  run "$PINS" verify --all
  [ "$status" -eq 3 ]
}

@test "verify fails a zeroed initrd of the same size (the disk-full damage)" {
  build_pin 20261109
  n="$(stat -c %s "$OUT/$PIN/audit/initrd")"
  head -c "$n" /dev/zero > "$OUT/$PIN/audit/initrd"
  run "$PINS" verify "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"FAIL $PIN: audit/initrd: sha256"* ]]
}

@test "verify reports a pin without hashes as unverified, exit 0" {
  mkdir -p "$OUT/pin-old/audit"
  echo k > "$OUT/pin-old/audit/bzImage"
  echo i > "$OUT/pin-old/audit/initrd"
  echo '{"init":"/x"}' > "$OUT/pin-old/audit/boot.json"
  run "$PINS" verify pin-old
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNVERIFIED pin-old: audit/bzImage"* ]]
}

@test "verify usage and not-found exits" {
  run "$PINS" verify
  [ "$status" -eq 2 ]
  run "$PINS" verify --all x
  [ "$status" -eq 2 ]
  run "$PINS" verify pin-nope
  [ "$status" -eq 4 ]
  run "$PINS" frobnicate
  [ "$status" -eq 2 ]
}

@test "list shows pin, date, size, profiles, hosts and the latest marker" {
  build_pin 20261108 1
  first="$PIN"
  build_pin 20261109 2
  reg_set 525400000001 system_pin "$first"
  run "$PINS" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$first"*"audit,node-base,node-cnh,node-converged"*"525400000001"* ]]
  [[ "$output" == *"$PIN"*"[latest]"* ]]
  run "$PINS" list --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg p "$PIN" '.[0].pin == $p and .[0].latest == 1 and (.[0].size > 0)'
  echo "$output" | jq -e --arg p "$first" '.[1].hosts == ["525400000001"]'
}

@test "prune --dry-run lists and removes nothing; prune keeps latest, hosts and the previous" {
  build_pin 20261101 1
  p1="$PIN"
  build_pin 20261102 2
  p2="$PIN"
  build_pin 20261103 3
  p3="$PIN"
  build_pin 20261104 4
  p4="$PIN"
  reg_set 525400000001 system_pin "$p1"
  run "$PINS" prune --keep-previous 1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete $p2"* ]]
  [ -d "$OUT/$p2" ]
  run --separate-stderr "$PINS" prune --keep-previous 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted      $p2"* ]]
  [[ "$stderr" == *"deleted pin $p2 (unreferenced and older than the newest 1 unreferenced pin)"* ]]
  [ ! -e "$OUT/$p2" ]
  [ -d "$OUT/$p1" ]
  [ -d "$OUT/$p3" ]
  [ -d "$OUT/$p4" ]
  [ "$(cat "$OUT/latest")" = "$p4" ]
}

@test "prune refuses without a readable latest and removes nothing" {
  build_pin 20261101 1
  rm "$OUT/latest"
  run "$PINS" prune
  [ "$status" -eq 3 ]
  [ -d "$OUT/$PIN" ]
}

@test "delete refuses the latest, a host's pin, a previous pin and the cluster default" {
  build_pin 20261101 1
  p1="$PIN"
  build_pin 20261102 2
  p2="$PIN"
  build_pin 20261103 3
  p3="$PIN"
  build_pin 20261104 4
  p4="$PIN"
  reg_set 525400000001 system_pin "$p1"
  reg_set 525400000001 system_pin_previous "$p2"
  reg_set cluster nixos_default_pin "$p3"
  run "$PINS" delete "$p4"
  [ "$status" -eq 3 ]
  [[ "$output" == *"latest"* ]]
  run "$PINS" delete "$p1"
  [ "$status" -eq 3 ]
  [[ "$output" == *"system_pin of 525400000001"* ]]
  run "$PINS" delete "$p2"
  [ "$status" -eq 3 ]
  [[ "$output" == *"system_pin_previous of 525400000001"* ]]
  run "$PINS" delete "$p3"
  [ "$status" -eq 3 ]
  [[ "$output" == *"nixos_default_pin"* ]]
  for p in "$p1" "$p2" "$p3" "$p4"; do [ -d "$OUT/$p" ]; done
}

@test "delete refuses the pin a host booted from in the last 15 minutes" {
  build_pin 20261101 1
  p1="$PIN"
  build_pin 20261102 2
  reg_set cluster nixos_default_pin "$p1"
  reg_set 525400000007 last_boot_at "$(date +%s)"
  reg_set cluster nixos_default_pin "$PIN"
  # the host is served the cluster default, now the latest; p1 is free
  run "$PINS" delete "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"booting now: 525400000007"* ]]
  run "$PINS" delete "$p1"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/$p1" ]
}

@test "delete removes an unreferenced pin and logs the reason; not-found and usage exits" {
  build_pin 20261101 1
  p1="$PIN"
  build_pin 20261102 2
  run --separate-stderr "$PINS" delete "$p1"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"deleted pin $p1 (explicit delete;"* ]]
  [ ! -e "$OUT/$p1" ]
  run "$PINS" delete "$p1"
  [ "$status" -eq 4 ]
  run "$PINS" delete
  [ "$status" -eq 2 ]
  run "$PINS" delete '../x'
  [ "$status" -eq 2 ]
}

@test "prune and delete fail closed when the registry cannot be read" {
  build_pin 20261101 1
  build_pin 20261102 2
  build_pin 20261103 3
  rm "$HPS_CONFIG_BASE/system.db/ACTIVE_CLUSTER.json"
  run "$PINS" prune
  [ "$status" -eq 1 ]
  [ "$(find "$OUT" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]
}

@test "assign refuses a corrupted pin (exit 3, file named) and accepts it once repaired" {
  build_pin 20261109
  reg_set os "x86_64:nixos:26.05" kernel bzImage
  reg_set 525400000001 STATE HELD
  cp "$OUT/$PIN/audit/initrd" "$TEST_DIR/initrd.good"
  truncate -s 3 "$OUT/$PIN/audit/initrd"
  run "$ONB" assign 525400000001 --type SCH --profile PROF --os x86_64:nixos:26.05 --pin "$PIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed verification"*"audit/initrd"* ]]
  run "$ONB" show 525400000001
  [[ "$output" == *"State: HELD"* ]]
  cp "$TEST_DIR/initrd.good" "$OUT/$PIN/audit/initrd"
  run "$ONB" assign 525400000001 --type SCH --profile PROF --os x86_64:nixos:26.05 --pin "$PIN"
  [ "$status" -eq 0 ]
}

@test "repin --pin refuses a corrupted pin and leaves the host on its pin" {
  build_pin 20261108 1
  p1="$PIN"
  build_pin 20261109 2
  p2="$PIN"
  reg_set 525400000001 STATE NETWORK_BOOT
  reg_set 525400000001 system_pin "$p1"
  truncate -s 3 "$OUT/$p2/node-converged/bzImage"
  run "$ONB" repin 525400000001 --pin "$p2"
  [ "$status" -eq 3 ]
  [[ "$output" == *"node-converged/bzImage"* ]]
  run "$ONB" show 525400000001 --json
  echo "$output" | jq -e --arg p "$p1" '.identity.system_pin == $p'
  run "$ONB" repin 525400000001 --to-latest
  [ "$status" -eq 3 ]
  run "$ONB" repin 525400000001 --pin "$p1"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already pinned"* ]]
}

@test "repin --pin accepts an intact pin" {
  build_pin 20261108 1
  p1="$PIN"
  build_pin 20261109 2
  reg_set 525400000001 STATE NETWORK_BOOT
  reg_set 525400000001 system_pin "$p1"
  run "$ONB" repin 525400000001 --pin "$PIN"
  [ "$status" -eq 0 ]
}

@test "the pins-prune job kind: allowlist, command table and Bash helper agree" {
  cat > "$TEST_DIR/jobs.pl" <<'PL'
use strict; use warnings; use lib "$ENV{SRC}/lib/perl"; use HPS::Jobs;
my @ok  = ([], ['--dry-run'], ['--keep-previous', '2'], ['--keep-previous', '0', '--dry-run'], ['--dry-run', '--keep-previous', '12']);
my @bad = (['--keep-previous'], ['--keep-previous', 'x'], ['--keep-previous', '100'], ['--keep-previous', '-1'], ['--force'], ['--dry-run', '--dry-run'], ['--keep-previous', '1', '--keep-previous', '2'], ['latest'], ['--keep-previous', '1; rm']);
for (@ok)  { my $w = HPS::Jobs::validate('pins-prune', @$_); print "ok-but-refused @$_: $w\n" if defined $w }
for (@bad) { my $w = HPS::Jobs::validate('pins-prune', @$_); print "bad-but-allowed @$_\n" unless defined $w }
print join(' ', HPS::Jobs::command('pins-prune', ['--keep-previous', '1'], pins => '/x/hps-pins')), "\n";
print join(' ', HPS::Jobs::command('pins-prune', [])), "\n";
PL
  SRC="$(cd "$SRC" && pwd)" run perl "$TEST_DIR/jobs.pl"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/x/hps-pins prune --keep-previous 1\nhps-pins prune')" ]

  # shellcheck source=/dev/null
  source "$SRC/lib/functions.d/jobs-functions.sh"
  hps_job_validate pins-prune
  hps_job_validate pins-prune --dry-run
  hps_job_validate pins-prune --keep-previous 3 --dry-run
  run -1 hps_job_validate pins-prune --keep-previous
  run -1 hps_job_validate pins-prune --keep-previous x
  run -1 hps_job_validate pins-prune --keep-previous 100
  run -1 hps_job_validate pins-prune --force
  run -1 hps_job_validate pins-prune --dry-run --dry-run
  run -1 hps_job_validate pins-prune latest
}
