#!/usr/bin/env bats
#
# CS-2.1: structural checks over the Nix (unevaluated here - nix is not
# installed; `nix flake check` is the real test) and the no-secrets scope over
# the new scripts. storage.nix is imported by converged.nix; every new script is
# allowlisted with profile node (one .source line each, so the CS-1.14
# structural counts keep working); the input-bearing ones declare input=raw.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
  NEW="storage-pool-import storage-pool-create storage-pool-destroy dataset-unlock storage-trim-check iscsi-export iscsi-unexport iscsi-status"
}

@test "converged.nix imports storage.nix and keeps both roles" {
  grep -q '\./storage\.nix' "$ROOT/nix/modules/profiles/converged.nix"
  grep -q 'hps.roles = "SCH,TCH"' "$ROOT/nix/modules/profiles/converged.nix"
}

@test "storage.nix: LIO on, SCH role, no NixOS pool import, the tools on the path" {
  local f="$ROOT/nix/modules/profiles/storage.nix"
  [ -f "$f" ]
  grep -q 'services.target.enable = true;' "$f"
  grep -q '"SCH"' "$f"
  grep -q 'boot.zfs.extraPools = \[ \];' "$f"
  local t
  for t in targetcli mdadm smartmontools util-linux unixtools.xxd; do
    grep -q "^    $t\$" "$f"
  done
  run ! grep -E 'forceImportRoot *= *true|forceImportAll *= *true|extraPools *= *\[ *"' "$f"
}

@test "storage.nix is not imported by the audit or base node images" {
  run ! grep -q 'storage.nix' "$ROOT/nix/modules/hps-node.nix" "$ROOT/nix/modules/hps-audit.nix" "$ROOT/nix/modules/hps-common.nix"
}

@test "ZFS stays on and root import stays unforced in hps-common.nix" {
  grep -q 'boot.supportedFilesystems = \[ "zfs" \];' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'boot.zfs.forceImportRoot = false;' "$ROOT/nix/modules/hps-common.nix"
}

@test "every new script exists, is executable, and is allowlisted with profile node" {
  local s
  for s in $NEW; do
    [ -x "$ROOT/node-manager/nixos-26/scripts/$s" ]
    grep -q "^      $s\.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$CTRL"
    grep -q "^      $s\.options\.profile = \"node\";" "$CTRL"
  done
}

@test "the scripts that read request input declare input=raw, the others declare none" {
  local s
  for s in storage-pool-create storage-pool-destroy dataset-unlock; do
    grep -q "^      $s\.options\.input = \"raw\";" "$CTRL"
  done
  for s in storage-pool-import storage-trim-check iscsi-export iscsi-unexport iscsi-status; do
    run ! grep -q "^      $s\.options\.input" "$CTRL"
  done
}

@test "the CS-1.14 structural counts still hold: one source line per profile line" {
  local sources profiles
  sources=$(grep -cE '^      [a-z-]+\.source = ' "$CTRL")
  profiles=$(grep -cE '^      [a-z-]+\.options\.profile = "node";' "$CTRL")
  [ "$sources" -eq "$profiles" ]
  [ "$sources" -ge 13 ]
}

@test "new scripts: env shebang, set -euo pipefail, one run() logger, no library sourcing, shellcheck clean" {
  local s f
  for s in $NEW; do
    f="$ROOT/node-manager/nixos-26/scripts/$s"
    [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$f"
    grep -q '^run() {' "$f"
    run ! grep -E '^[[:space:]]*(source|\.) ' "$f"
    shellcheck -S warning "$f"
  done
}

@test "no secrets: nothing in the new scripts or storage.nix looks like a credential" {
  local s
  for s in $NEW; do
    run ! grep -niE 'password|PRIVATE KEY|secret=|token=|BEGIN CERTIFICATE' "$ROOT/node-manager/nixos-26/scripts/$s"
  done
  run ! grep -niE 'password|PRIVATE KEY|secret=|token=' "$ROOT/nix/modules/profiles/storage.nix"
  # no 64-hex literal (a key) and no real by-id disk in any new script
  for s in $NEW; do
    run ! grep -E '[0-9a-fA-F]{64}' "$ROOT/node-manager/nixos-26/scripts/$s"
    run ! grep -E 'Samsung|S5RRNF' "$ROOT/node-manager/nixos-26/scripts/$s"
  done
}

@test "no new script has key material in a command-line position (xxd/openssl are fed by printf pipes)" {
  local s
  for s in storage-pool-create storage-pool-destroy dataset-unlock; do
    run ! grep -E 'openssl .*(-hmac|hexkey|-macopt)' "$ROOT/node-manager/nixos-26/scripts/$s"
    run ! grep -E 'zfs (load-key|create) .*\$(KEY|ENC_KEY|KEY_HEX)' "$ROOT/node-manager/nixos-26/scripts/$s"
  done
}
