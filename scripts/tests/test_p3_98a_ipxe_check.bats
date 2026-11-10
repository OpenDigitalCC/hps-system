#!/usr/bin/env bats
#
# IPS-09: the ipxe line of bin/hps-ips-check. check_ipxe is extracted from the
# script (the script runs main when sourced) and run with stubs for record and
# hps_get_config; nothing here starts a service.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-98a.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/res/nixos/pin1/ipxe" "$TEST_DIR/tftp" "$TEST_DIR/bin"
  echo pin1 > "$TEST_DIR/res/nixos/latest"
  echo snp > "$TEST_DIR/tftp/snponly.efi"
  printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/dpkg-query"
  chmod +x "$TEST_DIR/bin/dpkg-query"
  export PATH="$TEST_DIR/bin:$PATH"
  sed -n '/^check_ipxe() {/,/^}/p;/^ipxe_image_version() {/,/^}/p' "$ROOT/bin/hps-ips-check" > "$TEST_DIR/fn.sh"
  hps_get_config() { [[ "$1" == resources ]] && echo "$TEST_DIR/res"; return 0; }
  record() { echo "$1 $2: $3"; }
  source "$TEST_DIR/fn.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_json() {
  printf '{"version":"2.0.0","files":["snponly.efi"],"sha256":{"snponly.efi":"%s"}}\n' "$1" \
    > "$TEST_DIR/res/nixos/pin1/ipxe/ipxe.json"
}

@test "ipxe: the root holds the latest pin's snponly.efi: PASS names pin and version" {
  write_json "$(sha256sum "$TEST_DIR/tftp/snponly.efi" | cut -d' ' -f1)"
  run check_ipxe "$TEST_DIR/tftp"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS ipxe: pin pin1 2.0.0" ]
}

@test "ipxe: the root differs from the pin's: WARN, source image" {
  write_json "$(printf 'x' | sha256sum | cut -d' ' -f1)"
  run check_ipxe "$TEST_DIR/tftp"
  [[ "$output" == "WARN ipxe: image unknown (the TFTP root does not hold latest pin pin1's iPXE 2.0.0"* ]]
}

@test "ipxe: the latest pin has none: WARN, source image with the Debian version" {
  printf '#!/bin/bash\necho 1.0.0+git-20190125.36a4c85-5.1\n' > "$TEST_DIR/bin/dpkg-query"
  run check_ipxe "$TEST_DIR/tftp"
  [[ "$output" == "WARN ipxe: image 1.0.0+git-20190125.36a4c85-5.1 (latest pin pin1 has no iPXE"* ]]
}

@test "ipxe: the check is wired after the tftp boot files PASS and the script stays shellcheck-clean" {
  grep -q 'check_ipxe "\$tftp"' "$ROOT/bin/hps-ips-check"
  run shellcheck -S warning "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
}
