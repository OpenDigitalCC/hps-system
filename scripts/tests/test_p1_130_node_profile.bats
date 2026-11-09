#!/usr/bin/env bats
#
# CS-1.14: node scripts run under the ctrl-exec profile "node" (root plus the
# capabilities node operations need). Structural checks over hps-ctrl-exec.nix;
# the Nix itself is evaluated by `nix flake check`, which is not run here.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
}

@test "profile node exists, runs as root, keeps no_new_privileges" {
  block=$(sed -n '/profiles\.node = {/,/^    };/p' "$CTRL")
  [[ "$block" == *'run_as = "root";'* ]]
  [[ "$block" == *'no_new_privileges = "yes";'* ]]
}

@test "profile node caps include CAP_SYS_ADMIN and CAP_SYSLOG" {
  block=$(sed -n '/profiles\.node = {/,/^    };/p' "$CTRL")
  [[ "$block" == *'"CAP_SYS_ADMIN"'* ]]
  [[ "$block" == *'"CAP_SYSLOG"'* ]]
}

@test "profile node caps are all well-formed CAP_* names within the executor's 32 limit" {
  run grep -oE '"CAP_[A-Z0-9_]+"' <(sed -n '/profiles\.node = {/,/^    };/p' "$CTRL")
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -le 32 ]
  [ "${#lines[@]}" -ge 20 ]
}

@test "profile node sets no writable list (filesystem stays as it is)" {
  ! sed -n '/profiles\.node = {/,/^    };/p' "$CTRL" | grep -q 'writable ='
}

@test "profile default stays restrictive as the module ships it" {
  block=$(sed -n '/profiles\.default = {/,/^    };/p' "$CTRL")
  [[ "$block" == *'run_as = "root";'* ]]
  [[ "$block" == *'no_new_privileges = "yes";'* ]]
  [[ "$block" != *'caps'* ]]
}

@test "every script entry names profile node" {
  sources=$(grep -cE '^      [a-z-]+\.source = ' "$CTRL")
  profiles=$(grep -cE '^      [a-z-]+\.options\.profile = "node";' "$CTRL")
  [ "$sources" -ge 5 ]
  [ "$sources" -eq "$profiles" ]
}

@test "each script's profile line names the same script as its source line" {
  while IFS= read -r name; do
    grep -q "^      $name\.options\.profile = \"node\";" "$CTRL"
  done < <(grep -oE '^      [a-z-]+\.source' "$CTRL" | sed -E 's/^ +//; s/\.source$//')
}

@test "the module header takes lib" {
  grep -q '^{ config, lib, pkgs, ctrl-exec, \.\.\. }:' "$CTRL"
}

@test "SECURITY.md states the node-scripts-as-root model" {
  grep -q 'Node scripts run as root with capabilities' "$ROOT/docs/SECURITY.md"
}
