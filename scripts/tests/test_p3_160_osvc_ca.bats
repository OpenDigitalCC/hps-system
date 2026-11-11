#!/usr/bin/env bats
#
# IPS-12: one om3 cluster CA. osvc-secret-set installs it from an optional second
# input line; osvc-ca-export prints it; neither shows the CA bytes. (hps-osvc's
# capture and send paths are in t/91-hps-osvc-ca.t.)

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-160.XXXXXX")"
  SD="$ROOT/node-manager/nixos-26/scripts"
  export HPS_RUN_DIR="$T/run/hps"
  export OSVC_ETC="$T/etc/opensvc"
  SEC="$OSVC_ETC/namespaces/system/sec"
  export SHIM_LOG="$T/shim.log"
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$SHIM_LOG"\nexit 0\n' > "$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  export PATH="$T/bin:$PATH"
  SECRET="$(printf 'cd%.0s' {1..16})"
  CA_TEXT=$'[DEFAULT]\nca_marker_zzz = crypt:abcdef\n'
  CA_B64="$(printf '%s' "$CA_TEXT" | base64 -w0)"
  CA_LINE="1700000123 $CA_B64"
}

teardown() {
  rm -rf "$T"
}

@test "secret-set: without a CA line nothing under OSVC_ETC is touched" {
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"
  [ ! -e "$OSVC_ETC" ]
  [[ "$output" != *"cluster CA"* ]]
}

@test "secret-set: a CA line installs ca.conf 0600 in a 0700 dir with the given mtime, before the restart" {
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  [ "$(cat "$SEC/ca.conf")" = "${CA_TEXT%$'\n'}" ]
  [ "$(stat -c %a "$SEC/ca.conf")" = 600 ]
  [ "$(stat -c %a "$SEC")" = 700 ]
  [ "$(stat -c %Y "$SEC/ca.conf")" = 1700000123 ]
  [[ "$output" == *"cluster secret stored; opensvc-daemon restarted"* ]]
  [[ "$output" == *"cluster CA installed"* ]]
  grep -qx 'systemctl restart opensvc-daemon.service' "$SHIM_LOG"
}

@test "secret-set: a changed CA removes cert.conf" {
  mkdir -p "$SEC"
  printf '[DEFAULT]\nold = 1\n' > "$SEC/ca.conf"
  printf 'cert' > "$SEC/cert.conf"
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  [ ! -e "$SEC/cert.conf" ]
  [ "$(cat "$SEC/ca.conf")" = "${CA_TEXT%$'\n'}" ]
}

@test "secret-set: an absent CA with a stale cert.conf removes cert.conf" {
  mkdir -p "$SEC"
  printf 'cert' > "$SEC/cert.conf"
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  [ ! -e "$SEC/cert.conf" ]
}

@test "secret-set: an identical CA keeps cert.conf, reports unchanged and still sets the mtime" {
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  printf 'cert' > "$SEC/cert.conf"
  touch -d @1600000000 "$SEC/ca.conf"
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  [ -e "$SEC/cert.conf" ]
  [[ "$output" == *"cluster CA unchanged"* ]]
  [ "$(stat -c %Y "$SEC/ca.conf")" = 1700000123 ]
}

@test "secret-set: a malformed CA line is refused (3) and nothing is written or restarted" {
  local v
  for v in "abc $CA_B64" "1700000123" "1700000123 !!!notbase64" "1234567890123 $CA_B64" "1700000123 $(printf 'not a ca file' | base64 -w0)" "1700000123 $CA_B64 extra"; do
    run -3 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$v"
    [ ! -e "$OSVC_ETC" ]
    [ ! -e "$HPS_RUN_DIR/osvc-cluster-secret" ]
  done
  [ ! -e "$SHIM_LOG" ]
}

@test "secret-set: the CA is in no output and no logged command" {
  run -0 bash "$SD/osvc-secret-set" <<< "$SECRET"$'\n'"$CA_LINE"
  [[ "$output" != *"$CA_B64"* ]]
  [[ "$output" != *ca_marker* ]]
  run ! grep -q "$CA_B64" "$SHIM_LOG"
}

@test "ca-export: prints exactly one line '<mtime> <base64>'" {
  mkdir -p "$SEC"
  printf '%s' "$CA_TEXT" > "$SEC/ca.conf"
  touch -d @1700000123 "$SEC/ca.conf"
  run -0 --separate-stderr bash "$SD/osvc-ca-export"
  [ "$output" = "$CA_LINE" ]
  [[ "$stderr" != *"$CA_B64"* ]]
  [[ "$stderr" != *ca_marker* ]]
}

@test "ca-export: a missing or empty file is exit 1 after OSVC_CA_WAIT, with no output" {
  OSVC_CA_WAIT=1 run -1 --separate-stderr bash "$SD/osvc-ca-export"
  [ -z "$output" ]
  mkdir -p "$SEC"
  : > "$SEC/ca.conf"
  OSVC_CA_WAIT=1 run -1 --separate-stderr bash "$SD/osvc-ca-export"
  [ -z "$output" ]
}

@test "ca-export: waits for a file that appears" {
  mkdir -p "$SEC"
  ( sleep 1; printf '%s' "$CA_TEXT" > "$SEC/ca.conf" ) &
  OSVC_CA_WAIT=5 run -0 bash "$SD/osvc-ca-export"
  wait
  [[ "$output" == *" $CA_B64" ]]
}

@test "ca-export: an argument is a usage error (2)" {
  run -2 bash "$SD/osvc-ca-export" now
}

@test "ca-export is allowlisted for the node profile, read-only (no input option)" {
  local nix="$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -qF 'osvc-ca-export.options.profile = "node";' "$nix"
  run ! grep -qF 'osvc-ca-export.options.input' "$nix"
}

@test "the node scripts are executable and shellcheck-clean" {
  [ -x "$SD/osvc-ca-export" ]
  shellcheck -s bash -S warning "$SD/osvc-ca-export" "$SD/osvc-secret-set"
}
