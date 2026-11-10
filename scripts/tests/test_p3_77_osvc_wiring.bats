#!/usr/bin/env bats
#
# CS-3.5: wiring and hygiene of the OpenSVC build: flake pin, package, module,
# allowlist, and the rules (no global start, no secret in the image).

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SD="$ROOT/node-manager/nixos-26/scripts"
NIX="$ROOT/nix/modules/hps-ctrl-exec.nix"
SCRIPTS="osvc-status osvc-object-set osvc-object-start osvc-object-stop osvc-object-delete osvc-freeze osvc-thaw osvc-secret-set osvc-rig-probe"

@test "the flake pins om3 to a release tag as a non-flake input and exports pkgs.om3 through an overlay" {
  grep -qE 'url = "github:opensvc/om3/v[0-9]+\.[0-9]+\.[0-9]+-?[a-z0-9]*";' "$ROOT/flake.nix"
  grep -q 'flake = false;' "$ROOT/flake.nix"
  grep -q 'om3-src' "$ROOT/flake.nix"
  grep -q 'overlays.default = om3Overlay;' "$ROOT/flake.nix"
  grep -q 'nixpkgs.overlays = \[ om3Overlay \]' "$ROOT/flake.nix"
  grep -q 'om3 = (pkgs.extend om3Overlay).om3;' "$ROOT/flake.nix"
}

@test "the package is a buildGoModule of cmd/om with a real vendorHash" {
  grep -q 'buildGoModule' "$ROOT/nix/pkgs/om3.nix"
  grep -q 'subPackages = \[ "cmd/om" \]' "$ROOT/nix/pkgs/om3.nix"
  grep -qE 'vendorHash = "sha256-[A-Za-z0-9+/]{43}=";' "$ROOT/nix/pkgs/om3.nix"
  run ! grep -q 'fakeHash' <(grep -v '^#' "$ROOT/nix/pkgs/om3.nix" | grep -v '^ *#')
}

@test "the converged profile imports the OpenSVC module, which a container-host profile can reuse unchanged" {
  grep -q '../hps-opensvc.nix' "$ROOT/nix/modules/profiles/converged.nix"
  # generic: no profile name and no role test in the module
  run ! grep -E 'hpsProfile|hps\.roles|node-converged|compute|storage' <(grep -v '^ *#' "$ROOT/nix/modules/hps-opensvc.nix")
}

@test "the daemon unit runs om daemon run, always restarts, waits for the node init and for the secret" {
  local m="$ROOT/nix/modules/hps-opensvc.nix"
  grep -q 'ExecStart = "${pkgs.om3}/bin/om daemon run $OSVC_DAEMON_ARGS";' "$m"
  grep -q 'Restart = "always";' "$m"
  grep -q 'Environment = \[ "HOME=/var/lib/opensvc" \];' "$m"
  grep -q 'WorkingDirectory = "/var/lib/opensvc";' "$m"
  grep -q '"hps-node-init.service"' "$m"
  grep -q 'network-online.target' "$m"
  grep -q 'ConditionPathExists = "/run/hps/osvc-cluster-secret";' "$m"
  grep -q 'ExecStartPre = "${pkgs.bash}/bin/bash /etc/hps/hps-osvc-config";' "$m"
  grep -q '"d /etc/opensvc 0700 root root -"' "$m"
  grep -q '"d /var/lib/opensvc 0700 root root -"' "$m"
  grep -q 'allowedTCPPorts = \[ 1215 10000 \]' "$m"
  grep -q 'node-manager/nixos-26/boot/hps-osvc-config.sh' "$m"
}

@test "every OpenSVC script exists, is executable, is allowlisted once under profile node" {
  local s
  for s in $SCRIPTS; do
    [ -x "$SD/$s" ]
    [ "$(head -1 "$SD/$s")" = "#!/usr/bin/env bash" ]
    grep -qF "$s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$NIX"
    grep -qF "$s.options.profile = \"node\";" "$NIX"
    [ "$(grep -cF "$s.source" "$NIX")" -eq 1 ]
  done
  [ -x "$ROOT/node-manager/nixos-26/boot/hps-osvc-config.sh" ]
}

@test "only the secret script takes raw input" {
  local s
  grep -qF 'osvc-secret-set.options.input = "raw";' "$NIX"
  for s in $SCRIPTS; do
    [ "$s" = osvc-secret-set ] && continue
    run ! grep -qF "$s.options.input" "$NIX"
  done
}

@test "no script starts or stops an object without --local (rig-probe's plain-start is the one test-only exception)" {
  local s
  for s in osvc-object-start osvc-object-stop osvc-object-delete osvc-object-set osvc-status osvc-freeze osvc-thaw; do
    run ! grep -E '^[[:space:]]*run om .* (start|stop|delete)( |$)' <(grep -v -- '--local' "$SD/$s" | grep -vE 'node (freeze|thaw)' | grep -v '^[[:space:]]*#')
  done
  # the only plain start in the tree
  [ "$(grep -lE 'run om "svc/\$\{2#svc/\}" start$' "$SD"/osvc-* | wc -l)" -eq 1 ]
}

@test "no script ever sets orchestrate to ha or start, or passes --node" {
  run ! grep -E 'orchestrate=(ha|start)|orchestrate = (ha|start)|--node' "$SD"/osvc-object-* "$SD/osvc-status" "$SD/osvc-freeze" "$SD/osvc-thaw"
}

@test "the secret reaches the image nowhere: no secret value, key or password in the OpenSVC files" {
  run ! grep -rniE 'password|PRIVATE KEY|secret=' "$ROOT/nix/modules/hps-opensvc.nix" "$ROOT/nix/pkgs" "$ROOT/flake.nix" "$SD"/osvc-* "$ROOT/node-manager/nixos-26/boot/hps-osvc-config.sh"
  # the module and the generator hold no fixed cluster name, node name or address
  run ! grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$ROOT/nix/modules/hps-opensvc.nix" "$ROOT/nix/pkgs/om3.nix"
}

@test "the IPS side exists: hps-osvc, the CGI command and the docs" {
  [ -x "$ROOT/bin/hps-osvc" ]
  grep -q 'cmd" == "cluster_nodes"' "$ROOT/http/cgi-bin/boot_manager.sh"
  [ -f "$ROOT/docs/OPENSVC.md" ]
  grep -q 'osvc-status' "$ROOT/docs/OPENSVC.md"
  [ -x "$ROOT/lab/osvc-rig-1.sh" ]
  [ -x "$ROOT/lab/osvc-rig-2.sh" ]
}

@test "shellcheck is clean at warning level on every OpenSVC shell file" {
  command -v shellcheck > /dev/null || skip "shellcheck not installed"
  shellcheck -S warning -x "$SD"/osvc-* "$ROOT/node-manager/nixos-26/boot/hps-osvc-config.sh" \
    "$ROOT/lab/osvc-rig-lib.sh" "$ROOT/lab/osvc-rig-1.sh" "$ROOT/lab/osvc-rig-2.sh"
}
