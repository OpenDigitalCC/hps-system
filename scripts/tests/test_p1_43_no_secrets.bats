#!/usr/bin/env bats
#
# "No secret in any image": grep the Nix tree and the NixOS node-manager tree
# for anything that looks like a credential. The only allowed hits are the
# comment block in hps-common.nix that states the rule and the NixOS option
# users.allowNoPasswordLogin (which silences the lock-out assertion and grants
# nothing). Also checks that every file the flake and modules point at exists.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "nix/ and node-manager/nixos-26/ contain no password, private key or secret=" {
  run grep -rniE 'password|PRIVATE KEY|secret=' "$ROOT/nix" "$ROOT/node-manager/nixos-26" "$ROOT/flake.nix"
  # Every hit must be on the allow-list: the rule's own comment block in
  # hps-common.nix, or the allowNoPasswordLogin option.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *hps-common.nix:*'#'*) ;;
      *hps-common.nix:*allowNoPasswordLogin*) ;;
      *) echo "secret-looking line: $line" >&2; return 1 ;;
    esac
  done <<< "$output"
}

@test "no image sets a password, a password file or an authorized key" {
  ! grep -rnE 'hashedPassword|initialPassword|initialHashedPassword|passwordFile|authorizedKeys' "$ROOT/nix" "$ROOT/flake.nix"
}

@test "sshd is off and no user can log in" {
  grep -q 'services.openssh.enable = false' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'users.mutableUsers = false' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'users.allowNoPasswordLogin = true' "$ROOT/nix/modules/hps-common.nix"
}

@test "the flake pins nixos-26.05 and takes ctrl-exec as an overridable input" {
  grep -q 'nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"' "$ROOT/flake.nix"
  grep -q 'url = "github:OpenDigitalCC/ctrl-exec"' "$ROOT/flake.nix"
  grep -q 'inputs.nixpkgs.follows = "nixpkgs"' "$ROOT/flake.nix"
  ! grep -q 'path:/srv' "$ROOT/flake.nix"
  for p in audit node-base node-converged; do
    grep -q "$p = \[" "$ROOT/flake.nix"
  done
}

@test "every module and script the flake references exists" {
  for f in nix/modules/hps-common.nix nix/modules/hps-audit.nix nix/modules/hps-node.nix nix/modules/profiles/converged.nix; do
    grep -q "./$f" "$ROOT/flake.nix"
    [ -f "$ROOT/$f" ]
  done
  [ -f "$ROOT/node-manager/nixos-26/audit/hps-audit.sh" ]
  grep -q 'node-manager/nixos-26/audit/hps-audit.sh' "$ROOT/nix/modules/hps-audit.nix"
  [ -f "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh" ]
  grep -q 'node-manager/nixos-26/boot/hps-node-init.sh' "$ROOT/nix/modules/hps-node.nix"
  [ -f "$ROOT/node-manager/plugins/hps-node/hps-node.sh" ]
  grep -q 'node-manager/plugins/hps-node/hps-node.sh' "$ROOT/nix/modules/hps-node.nix"
  grep -q 'installer/netboot/netboot.nix' "$ROOT/nix/modules/hps-common.nix"
}

@test "no executable script sits directly in node-manager/nixos-26 (the bundle builder concatenates every *.sh there)" {
  run find "$ROOT/node-manager/nixos-26" -maxdepth 1 -name '*.sh' -perm -u+x
  [ -z "$output" ]
  head -1 "$ROOT/node-manager/nixos-26/nixos.init" | grep -q '^#@METADATA os=nixos-26'
}

@test "the node image carries the roles file only for the converged profile" {
  grep -q 'hps.roles = "SCH,TCH"' "$ROOT/nix/modules/profiles/converged.nix"
  grep -q '"hps/roles"' "$ROOT/nix/modules/hps-common.nix"
  ! grep -q 'hps.roles =' "$ROOT/nix/modules/hps-node.nix"
}
