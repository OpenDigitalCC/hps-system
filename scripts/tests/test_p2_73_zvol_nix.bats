#!/usr/bin/env bats
#
# CS-2.5: structural checks over the Nix allowlist (unevaluated here - nix is not
# installed; `nix flake check` is the real test) for the zvol and status scripts.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
  NEW="storage-zvol-create storage-zvol-destroy storage-zvol-list storage-status"
}

@test "every new script exists, is executable, and is allowlisted with profile node (one .source line each)" {
  local s
  for s in $NEW; do
    [ -x "$ROOT/node-manager/nixos-26/scripts/$s" ]
    [ "$(grep -c "^      $s\.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$CTRL")" -eq 1 ]
    [ "$(grep -c "^      $s\.options\.profile = \"node\";" "$CTRL")" -eq 1 ]
  done
}

@test "only storage-zvol-destroy reads request input (input = raw); create, list and status declare none" {
  grep -q '^      storage-zvol-destroy\.options\.input = "raw";' "$CTRL"
  local s
  for s in storage-zvol-create storage-zvol-list storage-status; do
    run ! grep -q "^      $s\.options\.input" "$CTRL"
  done
}

@test "the structural counts hold: sources equal profile lines, every source via mkScript" {
  local sources profiles viamk
  sources=$(grep -cE '^      [a-z-]+\.source = ' "$CTRL")
  profiles=$(grep -cE '^      [a-z-]+\.options\.profile = "node";' "$CTRL")
  viamk=$(grep -cE '^      [a-z-]+\.source = mkScript ' "$CTRL")
  [ "$sources" -eq "$profiles" ]
  [ "$sources" -eq "$viamk" ]
  [ "$sources" -ge 17 ]
}

@test "the new scripts carry no credential, no 64-hex literal and no real disk id" {
  local s f
  for s in $NEW; do
    f="$ROOT/node-manager/nixos-26/scripts/$s"
    run ! grep -niE 'password|PRIVATE KEY|secret=|token=|BEGIN CERTIFICATE' "$f"
    run ! grep -E '[0-9a-fA-F]{64}' "$f"
    run ! grep -E 'Samsung|S5RRNF' "$f"
  done
}

@test "the new scripts: env shebang, set -euo pipefail, one run() logger, no library sourcing, shellcheck clean" {
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
