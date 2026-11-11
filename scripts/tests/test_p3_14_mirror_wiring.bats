#!/usr/bin/env bats
#
# CS-3.2: wiring and hygiene of the leg/mirror scripts: allowlist entries, the
# absence of raw input and of approvals, no secrets or real values in the scripts, no --force.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SCRIPTS="leg-resolve mirror-create mirror-assemble mirror-status mirror-rejoin mirror-stop mirror-detach-leg"

@test "every script is allowlisted under profile node, after a # CS-3.2 comment" {
  local s
  grep -q '# CS-3.2' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  for s in $SCRIPTS; do
    grep -qF "$s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$ROOT/nix/modules/hps-ctrl-exec.nix"
    grep -qF "$s.options.profile = \"node\";" "$ROOT/nix/modules/hps-ctrl-exec.nix"
  done
}

@test "no mirror script takes raw input: none reads an approval document any more (ADR 0007)" {
  local s
  for s in $SCRIPTS; do
    run ! grep -qF "$s.options.input" "$ROOT/nix/modules/hps-ctrl-exec.nix"
    run ! grep -nE -- '--approval-file|--declaration-file|hmac' "$ROOT/node-manager/nixos-26/scripts/$s"
  done
}

@test "no script contains --force, a password, a key or an address of a real host" {
  local s
  for s in $SCRIPTS; do
    run ! grep -nE -- 'password|PRIVATE KEY|secret=' "$ROOT/node-manager/nixos-26/scripts/$s"
    run ! bash -c "grep -v '^[[:space:]]*#' '$ROOT/node-manager/nixos-26/scripts/$s' | grep -E -- '--force'"
    run ! grep -nE '(^|[^0-9.])(1[0-9]{2}|2[0-4][0-9]|[0-9]{1,2})\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$ROOT/node-manager/nixos-26/scripts/$s"
  done
}

@test "every script is executable, env shebang, set -euo pipefail, shellcheck clean" {
  local s
  for s in $SCRIPTS; do
    [ -x "$ROOT/node-manager/nixos-26/scripts/$s" ]
    [ "$(head -1 "$ROOT/node-manager/nixos-26/scripts/$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$ROOT/node-manager/nixos-26/scripts/$s"
    shellcheck -S warning "$ROOT/node-manager/nixos-26/scripts/$s"
  done
}
