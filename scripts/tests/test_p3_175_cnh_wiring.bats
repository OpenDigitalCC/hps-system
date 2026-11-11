#!/usr/bin/env bats
#
# CS-3.11: wiring of the container host. Structural checks over the Nix (it is
# evaluated by `nix flake check` in the builder, not here), the role and
# profile mapping, the script hygiene, and hps-cnh-publish -> cnh-ips-bootstrap
# end to end.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SD="$ROOT/node-manager/nixos-26/scripts"
BD="$ROOT/node-manager/nixos-26/boot"
CNH="$ROOT/nix/modules/profiles/container-host.nix"
CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
SCRIPTS="cnh-disk-prepare cnh-image-load cnh-ips-bootstrap cnh-ips-cluster-bootstrap cnh-ips-run cnh-ips-stop cnh-ips-operator-init"
BOOT="hps-cnh-mount.sh hps-ips-launch.sh"

# joined <file>: without comment lines, backslash continuations joined.
joined() {
  grep -v '^[[:space:]]*#' "$1" | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta'
}

# nix_code <file>: the file without comment lines.
nix_code() {
  grep -v '^[[:space:]]*#' "$1"
}

@test "the profile is the node base plus om3, role CNH, and nothing of the compute or storage roles" {
  grep -q 'imports = \[ ../hps-node.nix ../hps-opensvc.nix \];' "$CNH"
  grep -q '^  hps.roles = "CNH";' "$CNH"
  run ! bash -c "grep -v '^[[:space:]]*#' '$CNH' | grep -E 'storage\\.nix|compute\\.nix|converged\\.nix|libvirtd|services\\.target|extraPools|zpool'"
}

@test "podman is on with the netavark backend and overlay storage in /var/lib/containers; no docker socket" {
  nix_code "$CNH" | grep -q 'virtualisation.podman = {'
  nix_code "$CNH" | grep -q 'enable = true;'
  nix_code "$CNH" | grep -q 'dockerSocket.enable = false;'
  nix_code "$CNH" | grep -q 'network_backend = "netavark";'
  nix_code "$CNH" | grep -q 'graphroot = "/var/lib/containers/storage";'
  nix_code "$CNH" | grep -q 'driver = "overlay";'
}

@test "every CNH script is allowlisted under profile node in the CNH profile only" {
  local s
  for s in $SCRIPTS; do
    grep -qxF "      $s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$CNH"
    grep -qxF "      $s.options.profile = \"node\";" "$CNH"
    run ! grep -q "$s" "$CTRL"
    run ! grep -F "$s.options.input" "$CNH"
  done
  grep -q 'services.ctrl-exec-agent.scripts = {' "$CNH"
  grep -q 'scriptsDir = ../../../node-manager/nixos-26/scripts;' "$CNH"
  [ "$(grep -cE '^      [a-z-]+\.source = ' "$CNH")" -eq "$(grep -cE '^      [a-z-]+\.options\.profile = "node";' "$CNH")" ]
}

@test "the boot units: hps-cnh-mount before hps-ips; hps-ips gated on ips.env, Restart=always, launcher start/stop/stop-post" {
  grep -q 'source = ../../../node-manager/nixos-26/boot/hps-cnh-mount.sh;' "$CNH"
  grep -q 'source = ../../../node-manager/nixos-26/boot/hps-ips-launch.sh;' "$CNH"
  block=$(sed -n '/systemd.services.hps-ips = {/,/^  };/p' "$CNH")
  [[ "$block" == *'ConditionPathExists = "/var/lib/hps-ips/ips.env";'* ]]
  [[ "$block" == *'Restart = "always";'* ]]
  [[ "$block" == *'requires = [ "hps-cnh-mount.service" ];'* ]]
  [[ "$block" == *'/etc/hps/hps-ips-launch start"'* ]]
  [[ "$block" == *'/etc/hps/hps-ips-launch stop"'* ]]
  [[ "$block" == *'/etc/hps/hps-ips-launch stop-post"'* ]]
  mblock=$(sed -n '/systemd.services.hps-cnh-mount = {/,/^  };/p' "$CNH")
  [[ "$mblock" == *'"hps-ips.service"'* ]]
  [[ "$mblock" == *'Type = "oneshot";'* ]]
}

@test "the tools the scripts call are on the system path" {
  local p
  for p in e2fsprogs util-linux curl jq gnutar gzip iproute2 config.networking.firewall.package config.virtualisation.podman.package; do
    sed -n '/environment.systemPackages = with pkgs; \[/,/\];/p' "$CNH" | grep -qF "$p"
  done
}

@test "the flake builds node-cnh from the profile and build.sh publishes it by default" {
  grep -qF 'node-cnh = [ ./nix/modules/profiles/container-host.nix ];' "$ROOT/flake.nix"
  grep -q '^PROFILES="audit node-base node-converged node-cnh"$' "$ROOT/nix/build.sh"
}

@test "host profile CONTAINER_HOST boots image node-cnh" {
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  [ "$(nixos_image_profile CONTAINER_HOST)" = "node-cnh" ]
  [ "$(nixos_image_profile CONVERGED)" = "node-converged" ]
  grep -q 'known: CONVERGED, CONTAINER_HOST, DEFAULT' "$ROOT/lib/functions.d/nixos-boot-functions.sh"
}

@test "the registry role list takes CNH (alone, not mixed up with others)" {
  run perl -I"$ROOT/lib/perl" -MHPS::Onboard -e '
    my $o = HPS::Onboard->new(registry => {});
    for my $t (qw(CNH SCH,CNH)) {
      $o->_validate_args({ type => $t, profile => "CONTAINER_HOST", os => "x86_64:nixos:26.05", pin => "p1" }) or die;
    }
    eval { $o->_validate_args({ type => "CNX", profile => "CONTAINER_HOST", os => "x86_64:nixos:26.05", pin => "p1" }) };
    die "CNX accepted" unless $@ && $@->message =~ /SCH, TCH, DRH, CNH/;
    print "ok\n";'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  grep -q 'hps_types=SCH,TCH,DRH,CNH' "$ROOT/lib/functions.d/os-functions.sh"
}

@test "every CNH script and boot script: executable, env shebang, set -euo pipefail, shellcheck clean, no sourcing" {
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
  for f in $(printf "$SD/%s " $SCRIPTS) $(printf "$BD/%s " $BOOT); do
    run ! grep -nE 'password|PRIVATE KEY|secret=' "$f"
    run ! grep -nE '(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$f"
    run ! grep -nEi '[a-z0-9-]+\.(com|net|org|io|eu|uk|lan|local|internal)([^a-z]|$)' "$f"
  done
}

@test "mkfs only in cnh-disk-prepare; curl only in the two fetching scripts; podman from a node script only through systemd-run; no pool, md or wipe tools" {
  local s
  for s in $SCRIPTS; do
    case "$s" in
      cnh-disk-prepare) nix_code "$SD/$s" | grep -q 'run mkfs.ext4 -q -L "\$LABEL"' ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'mkfs'" ;;
    esac
    case "$s" in
      cnh-image-load | cnh-ips-bootstrap) ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])curl '" ;;
    esac
    run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])(zpool|zfs|mdadm|wipefs|dd|sgdisk|parted)[ ]'"
    run ! bash -c "$(declare -f joined); joined '$SD/$s' | grep -E '(^[[:space:]]*|run |exec |[(])podman ' | grep -v 'systemd-run'"
  done
  # the one mkfs is behind the blank-device probe
  nix_code "$SD/cnh-disk-prepare" | grep -B12 'run mkfs.ext4' | grep -q 'if probe; then'
}

@test "the documentation exists and names every script, the unit and the manifest schema" {
  local s
  [ -f "$ROOT/docs/CONTAINER-HOST.md" ]
  for s in $SCRIPTS hps-cnh-mount hps-ips.service hps-cnh-publish hps-cnh-manifest/1 CONTAINER_HOST node-cnh; do
    grep -qF "$s" "$ROOT/docs/CONTAINER-HOST.md"
  done
  grep -q 'CS-3.11' "$ROOT/CHANGELOG.md"
}

# --- hps-cnh-publish -> cnh-ips-bootstrap ------------------------------------

@test "end to end: what hps-cnh-publish writes, cnh-ips-bootstrap fetches and verifies" {
  load p2_30_helpers
  load p3_171_helpers
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-175.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  local res="$STATE/www" sys="$TEST_DIR/sys" pin=nixos-26.05-20261111-0123456-abcdef0 p f bz rd
  mkdir -p "$sys/scripts" "$res/packages/ctrl-exec"
  printf '#!/bin/bash\n' > "$sys/scripts/run-hps.sh"
  printf 'ctrl-exec' > "$res/packages/ctrl-exec/ctrl-exec-latest.tar.gz"
  for p in node-base node-cnh; do
    mkdir -p "$res/nixos/$pin/$p"
    printf 'k-%s' "$p" > "$res/nixos/$pin/$p/bzImage"
    printf 'i-%s' "$p" > "$res/nixos/$pin/$p/initrd"
    bz=$(p3_171_sha "$res/nixos/$pin/$p/bzImage")
    rd=$(p3_171_sha "$res/nixos/$pin/$p/initrd")
    jq -n --arg b "$bz" --arg r "$rd" --argjson bs "$(stat -c %s "$res/nixos/$pin/$p/bzImage")" --argjson rs "$(stat -c %s "$res/nixos/$pin/$p/initrd")" '{init:"/x", sha256:{bzImage:$b, initrd:$r}, size:{bzImage:$bs, initrd:$rs}}' > "$res/nixos/$pin/$p/boot.json"
  done
  # the IPS side, as an IPS tool would run it
  run env HPS_CONFIG_BASE="$TEST_DIR/cfg" perl "$ROOT/bin/hps-cnh-publish" --resources "$res" --system "$sys" --pin "$pin"
  [ "$status" -eq 0 ]
  msum=$(printf '%s\n' "$output" | sed -n 's/^MANIFEST \([0-9a-f]\{64\}\) .*/\1/p')
  [ -n "$msum" ]
  # the CNH side, served the same tree over the curl shim
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
  mkdir -p "$I"
  p3_171_mount "$I" "$HPS_CNH_ROOT/var/lib/containers/hps-ips"
  run bash "$SD/cnh-ips-bootstrap" http://10.99.1.1 "$msum"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "BOOTSTRAP $msum files=8 fetched=8 present=0 replaced=0" ]]
  for f in node-base/bzImage node-cnh/initrd node-cnh/boot.json; do
    cmp "$res/nixos/$pin/$f" "$I/srv/hps-resources/nixos/$pin/$f"
  done
  cmp "$res/packages/ctrl-exec/ctrl-exec-latest.tar.gz" "$I/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz"
  [ -f "$I/hps-system/scripts/run-hps.sh" ]
  rm -rf "$TEST_DIR"
}

@test "hps-cnh-mount is not ordered before podman.socket (an ordering cycle with basic.target, lab 2026-11-11)" {
  run ! grep -qE 'before = \[[^]]*"podman\.socket"' "$BATS_TEST_DIRNAME/../../nix/modules/profiles/container-host.nix"
}

@test "the CNH firewall opens the IPS operator API port (7445) for the outside operator" {
  grep -qE 'networking\.firewall\.allowedTCPPorts = \[[^]]*\b7445\b' "$BATS_TEST_DIRNAME/../../nix/modules/profiles/container-host.nix"
}
