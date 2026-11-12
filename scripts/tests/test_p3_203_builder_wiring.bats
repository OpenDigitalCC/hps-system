#!/usr/bin/env bats
#
# Wiring of the image builder (docs/BUILDER.md): structural checks over the
# Nix (evaluated by `nix flake check` in the builder, not here), the host
# profile and role mapping, the egress proxy on the command line, script
# hygiene, and nix/build.sh proving every published file on disk with O_DIRECT
# (IPS-33 #3, #3b).

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SD="$ROOT/node-manager/nixos-26/scripts"
BD="$ROOT/node-manager/nixos-26/boot"
BLD="$ROOT/nix/modules/profiles/builder.nix"
CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
SCRIPTS="builder-disk-prepare builder-build builder-status"
BOOT="hps-builder-mount.sh hps-builder-run.sh"

nix_code() {
  grep -v '^[[:space:]]*#' "$1"
}

@test "the profile is the node base, role BLD, nothing of om3, storage, compute or podman" {
  grep -q 'imports = \[ ../hps-node.nix \];' "$BLD"
  grep -q '^  hps.roles = "BLD";' "$BLD"
  run ! bash -c "nix_code() { grep -v '^[[:space:]]*#' \"\$1\"; }; nix_code '$BLD' | grep -E 'hps-opensvc|storage\\.nix|compute\\.nix|converged\\.nix|libvirtd|podman|zpool'"
}

@test "every builder script is allowlisted under profile node in the builder profile only" {
  local s
  for s in $SCRIPTS; do
    grep -qxF "      $s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$BLD"
    grep -qxF "      $s.options.profile = \"node\";" "$BLD"
    run ! grep -q "$s" "$CTRL"
    run ! grep -q "$s" "$ROOT/nix/modules/profiles/container-host.nix"
  done
  [ "$(grep -cE '^      [a-z-]+\.source = ' "$BLD")" -eq 3 ]
}

@test "the boot units: hps-builder-mount before the server; the server reads out/ only, when the disk is mounted, on the opened port" {
  grep -q 'source = bootDir + "/hps-builder-mount.sh";' "$BLD"
  grep -q 'source = bootDir + "/hps-builder-run.sh";' "$BLD"
  mblock=$(sed -n '/systemd.services.hps-builder-mount = {/,/^  };/p' "$BLD")
  [[ "$mblock" == *'before = [ "hps-builder-http.service" ];'* ]]
  [[ "$mblock" == *'Type = "oneshot";'* ]]
  hblock=$(sed -n '/systemd.services.hps-builder-http = {/,/^  };/p' "$BLD")
  [[ "$hblock" == *'ConditionPathIsMountPoint = "/var/lib/hps-builder";'* ]]
  [[ "$hblock" == *'DynamicUser = true;'* ]]
  [[ "$hblock" == *'ProtectSystem = "strict";'* ]]
  [[ "$hblock" == *'ReadOnlyPaths = [ "/var/lib/hps-builder/out" ];'* ]]
  [[ "$hblock" == *'darkhttpd /var/lib/hps-builder/out --port ${toString httpPort} --no-listing'* ]]
  grep -q '^  httpPort = 8090;' "$BLD"
  grep -q 'networking.firewall.allowedTCPPorts = \[ httpPort \];' "$BLD"
}

@test "the tools the scripts and the runner call are on the system path" {
  local p
  for p in e2fsprogs util-linux coreutils curl jq gnutar gzip findutils darkhttpd; do
    sed -n '/environment.systemPackages = with pkgs; \[/,/\];/p' "$BLD" | grep -qE "^    $p( |$)"
  done
}

@test "the flake builds node-builder from the profile and build.sh publishes it by default" {
  grep -qF 'node-builder = [ ./nix/modules/profiles/builder.nix ];' "$ROOT/flake.nix"
  grep -q '^PROFILES="audit node-base node-converged node-cnh node-builder"$' "$ROOT/nix/build.sh"
}

@test "host profile BUILDER boots image node-builder; the role list takes BLD" {
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  [ "$(nixos_image_profile BUILDER)" = "node-builder" ]
  [ "$(nixos_image_profile CONTAINER_HOST)" = "node-cnh" ]
  run perl -I"$ROOT/lib/perl" -MHPS::Onboard -e '
    my $o = HPS::Onboard->new(registry => {});
    $o->_validate_args({ type => "BLD", profile => "BUILDER", os => "x86_64:nixos:26.05", pin => "p1" }) or die;
    print "ok\n";'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  grep -q 'hps_types=SCH,TCH,DRH,CNH,BLD' "$ROOT/lib/functions.d/os-functions.sh"
}

# --- the egress proxy on the command line --------------------------------------

boot_setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-203.XXXXXX")"
  export TEST_DIR
  load p1_50_helpers
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  source "$ROOT/lib/functions.d/os-function-helpers.sh"
  p1_50_stubs
  p1_50_manifest pin1 node-builder
  p1_50_manifest pin1 node-base
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:03
}

@test "cluster key egress_proxy becomes hps.proxy= on the builder image's command line only" {
  boot_setup
  printf 'http://10.0.0.2:3128' > "$TEST_DIR/cluster/egress_proxy"
  run nixos_boot_lines "$MAC" node-builder pin1
  [ "$status" -eq 0 ]
  [[ "$output" == *" hps.proxy=http://10.0.0.2:3128"* ]]
  run nixos_boot_lines "$MAC" node-base pin1
  [[ "$output" != *"hps.proxy"* ]]
  rm -rf "$TEST_DIR"
}

@test "no egress_proxy, or one of another shape, gives no hps.proxy=" {
  boot_setup
  run nixos_boot_lines "$MAC" node-builder pin1
  [[ "$output" != *"hps.proxy"* ]]
  local v
  for v in 'https://10.0.0.2:3128' 'http://10.0.0.2' 'http://a b:1' 'http://x:1/path' 'http://x:1;reboot'; do
    printf '%s' "$v" > "$TEST_DIR/cluster/egress_proxy"
    run nixos_boot_lines "$MAC" node-builder pin1
    [[ "$output" != *"hps.proxy"* ]]
  done
  rm -rf "$TEST_DIR"
}

# --- hygiene --------------------------------------------------------------------

@test "every builder script and boot script: executable, env shebang, set -euo pipefail, shellcheck clean, no sourcing" {
  local f
  for f in $(printf "$SD/%s " $SCRIPTS) $(printf "$BD/%s " $BOOT); do
    [ -x "$f" ]
    [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$f"
    shellcheck -s bash -S warning "$f"
    run ! bash -c "grep -v '^[[:space:]]*#' '$f' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  done
}

@test "no script holds a real address, host name, password or key" {
  local f
  for f in $(printf "$SD/%s " $SCRIPTS) $(printf "$BD/%s " $BOOT) "$BLD"; do
    run ! grep -nE 'password|PRIVATE KEY|secret=' "$f"
    # the loopback address in no_proxy is no lab address
    run ! bash -c "grep -v 127.0.0.1 '$f' | grep -nE '(^|[^0-9.])[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}([^0-9]|\$)'"
    run ! grep -nEi '[a-z0-9-]+\.(com|net|org|io|eu|uk|lan|local|internal)([^a-z]|$)' "$f"
  done
}

@test "mkfs only in builder-disk-prepare, behind the blank probe; curl only in builder-build, never through a proxy; no pool, md or wipe tools" {
  local s
  for s in $SCRIPTS; do
    case "$s" in
      builder-disk-prepare) nix_code "$SD/$s" | grep -B12 'run mkfs.ext4' | grep -q 'if probe; then' ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'mkfs'" ;;
    esac
    case "$s" in
      builder-build) nix_code "$SD/$s" | grep -E '(^|[ (])curl ' | grep -q -- "--noproxy '\*'" ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])curl '" ;;
    esac
    run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])(zpool|zfs|mdadm|wipefs|dd|sgdisk|parted)[ ]'"
  done
  run ! bash -c "grep -v '^[[:space:]]*#' '$BD/hps-builder-run.sh' | grep -E '(^|[ (])(mkfs|curl|zpool|mdadm|wipefs)[ .]'"
  # the build runs only through the transient unit
  nix_code "$SD/builder-build" | grep -q 'run systemd-run --quiet --collect --unit "\$UNIT"'
}

@test "the documentation exists and names every script, the units, the tools and the keys" {
  local s
  [ -f "$ROOT/docs/BUILDER.md" ]
  for s in $SCRIPTS hps-builder-mount hps-builder-run hps-builder-http hps-pin-fetch hps-cnh-publish --source-only BUILDER node-builder BLD egress_proxy hps.proxy O_DIRECT; do
    grep -qF -- "$s" "$ROOT/docs/BUILDER.md"
  done
  grep -q 'node-builder' "$ROOT/CHANGELOG.md"
}

# --- nix/build.sh proves each published file on disk ----------------------------

# A copy of test_p1_40's harness: a PATH shim for nix and nix-store, and a dd
# shim that, while $STATE/bad.<name> holds N > 0, makes the O_DIRECT read of
# a published <name>.tmp copy give other bytes N times.
build_setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-203b.XXXXXX")"
  export TEST_DIR NIX_LOG="$TEST_DIR/nix.log" FAKE_STORE="$TEST_DIR/store" STATE="$TEST_DIR/state"
  OUT="$TEST_DIR/out"
  CACHE="$TEST_DIR/cache"
  mkdir -p "$TEST_DIR/bin" "$FAKE_STORE" "$STATE"
  export PATH="$TEST_DIR/bin:$PATH" HPS_BUILD_COPY_PAUSE=0
  cat > "$TEST_DIR/bin/nix" <<'EOF'
#!/bin/bash
echo "$*" >> "$NIX_LOG"
sub=""
for a in "$@"; do case "$a" in build|flake|copy) sub="$a"; break ;; esac; done
case "$sub" in
  flake) echo '{"locks":{"nodes":{"nixpkgs":{"locked":{"rev":"0123456789abcdef0123456789abcdef01234567"}}}}}' ;;
  build)
    inst="" link=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --out-link) link="$2"; shift 2 ;; *'#'*) inst="$1"; shift ;; *) shift ;; esac
    done
    profile="${inst##*#}"
    store="$FAKE_STORE/hps-$profile"
    mkdir -p "$store"
    if [[ "$profile" == ipxe ]]; then
      for n in snponly.efi ipxe.efi undionly.kpxe; do echo "ipxe-$n" > "$store/$n"; done
      echo '{"version":"2.0.0","files":["snponly.efi","ipxe.efi","undionly.kpxe"]}' > "$store/ipxe.json"
    else
      echo "kernel-$profile" > "$store/bzImage"
      echo "initrd-$profile" > "$store/initrd"
      printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/aaaa-%s/init","cmdline":"","nixos_version":"26.05","profile":"%s"}\n' "$profile" "$profile" > "$store/boot.json"
    fi
    ln -sfn "$store" "$link"
    ;;
esac
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/nix-store"
  cat > "$TEST_DIR/bin/dd" <<'EOF'
#!/bin/bash
echo "dd $*" >> "$NIX_LOG"
src=""
for a in "$@"; do [[ "$a" == if=* ]] && src="${a#if=}"; done
name="${src##*/}"
if [[ "$name" == *.tmp && -f "$STATE/bad.${name%.tmp}" ]]; then
  n=$(cat "$STATE/bad.${name%.tmp}")
  if [[ "$n" -gt 0 ]]; then
    echo $((n - 1)) > "$STATE/bad.${name%.tmp}"
    head -c 4 /dev/zero
    exit 0
  fi
fi
exec /usr/bin/dd "$@"
EOF
  chmod +x "$TEST_DIR/bin/"*
}

@test "build.sh: every published file is read with O_DIRECT, the store original and the copy" {
  build_setup
  run bash "$ROOT/nix/build.sh" --out "$OUT" --cache "$CACHE" --date 20261112 --profiles "node-base node-builder"
  [ "$status" -eq 0 ]
  grep -qE "^dd if=$FAKE_STORE/hps-node-builder/initrd iflag=direct" "$NIX_LOG"
  pin=$(cat "$OUT/latest")
  grep -qE "^dd if=$OUT/$pin/node-builder/initrd.tmp iflag=direct" "$NIX_LOG"
  grep -qE "^dd if=$OUT/$pin/node-builder/initrd iflag=direct" "$NIX_LOG"
  grep -qE "^dd if=$OUT/$pin/ipxe/snponly.efi iflag=direct" "$NIX_LOG"
  rm -rf "$TEST_DIR"
}

@test "build.sh: a copy that reads back wrong is written again; boot.json and SHA256SUMS hold the store hash" {
  build_setup
  echo 2 > "$STATE/bad.initrd"
  run bash "$ROOT/nix/build.sh" --out "$OUT" --cache "$CACHE" --date 20261112 --profiles "node-builder"
  [ "$status" -eq 0 ]
  [[ "$output" == *"initrd.tmp reads back"*"(try 1 of 3)"* ]]
  [[ "$output" == *"(try 2 of 3)"* ]]
  pin=$(cat "$OUT/latest")
  want=$(sha256sum "$FAKE_STORE/hps-node-builder/initrd" | cut -d' ' -f1)
  [ "$(jq -r .sha256.initrd "$OUT/$pin/node-builder/boot.json")" = "$want" ]
  grep -qxF "$want  node-builder/initrd" "$OUT/$pin/SHA256SUMS"
  (cd "$OUT/$pin" && sha256sum -c --quiet SHA256SUMS)
  rm -rf "$TEST_DIR"
}

@test "build.sh: a copy that never reads back right fails the build; latest is not written" {
  build_setup
  echo 9 > "$STATE/bad.bzImage"
  run bash "$ROOT/nix/build.sh" --out "$OUT" --cache "$CACHE" --date 20261112 --profiles "node-builder"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never read back as the store original"* ]]
  [ ! -e "$OUT/latest" ]
  rm -rf "$TEST_DIR"
}

@test "build.sh: SHA256SUMS is written from the recorded hashes, never from a new read of the copies" {
  sums=$(sed -n '/^write_sums() {/,/^}/p' "$ROOT/nix/build.sh")
  [[ "$sums" == *'recorded_sha256 "$dir/$profile" bzImage'* ]]
  [[ "$sums" == *'recorded_sha256 "$dir/ipxe" "$f"'* ]]
  [[ "$sums" != *'file_sha256'* ]]
  [[ "$sums" != *'direct_sha256'* ]]
}

@test "egress_proxy is a catalogued cluster key that takes http://<host>:<port> only" {
  run perl -I"$ROOT/lib/perl" -MHPS::ClusterConfig -e '
    my $q = HPS::ClusterConfig::question("egress_proxy") or die "not catalogued\n";
    for my $ok ("http://10.0.0.2:3128", "http://proxy.lab:8080", "") {
      my $e = HPS::ClusterConfig::validate_value($q, $ok); die "refused $ok: $e\n" if defined $e;
    }
    for my $bad ("https://x:1", "http://x", "http://x:1/p", "x:3128") {
      die "accepted $bad\n" unless defined HPS::ClusterConfig::validate_value($q, $bad);
    }
    print "ok\n";'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  grep -q "'egress_proxy', 'cluster'" "$ROOT/lib/perl/HPS/Registry/Keys.pm"
  grep -q '^| `egress_proxy` |' "$ROOT/docs/REGISTRY-KEYS.md"
  grep -q '^| `egress_proxy` |' "$ROOT/docs/CLUSTER-CONFIG.md"
}
