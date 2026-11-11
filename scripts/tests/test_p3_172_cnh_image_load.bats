#!/usr/bin/env bats
#
# CS-3.11: cnh-image-load - an image archive from this node's IPS only,
# verified before podman loads it.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-172.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  C="$HPS_CNH_ROOT/var/lib/containers"
  p3_171_mount "$C" "$HPS_DEV/vdb"
  p3_171_serve packages/cnh/hps-container.tar "an-oci-archive"
  SUM=$(p3_171_sha "$STATE/www/packages/cnh/hps-container.tar")
  URL="http://10.99.1.1/packages/cnh/hps-container.tar"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "fetches from the IPS, verifies, loads through systemd-run and prints IMAGE" {
  run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IMAGE localhost/hps-container:latest $SUM" ]
  [ -f "$C/hps-cnh-images/$SUM.tar" ]
  [ ! -e "$C/hps-cnh-images/$SUM.tar.part" ]
  grep -qF -- "curl --fail --silent --show-error --proto =http --max-redirs 0 --output $C/hps-cnh-images/$SUM.tar.part $URL" "$SHIM_LOG"
  grep -qxF "systemd-run --quiet --wait --pipe --collect -- podman load --input $C/hps-cnh-images/$SUM.tar" "$SHIM_LOG"
  # verified before podman sees it
  [ "$(p3_171_cmds | grep -oE 'curl sha256sum systemd-run podman')" = "curl sha256sum systemd-run podman" ]
}

@test "a port on the IPS address is allowed" {
  p3_171_serve x/a.tar "an-oci-archive"
  run bash "$S/cnh-image-load" "http://10.99.1.1:8080/x/a.tar" "$SUM"
  [ "$status" -eq 0 ]
}

@test "an archive already there with the right hash is loaded without fetching" {
  run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 0 ]
  run ! grep -q '^curl' "$SHIM_LOG"
  grep -q '^podman load' "$SHIM_LOG"
}

@test "a hash mismatch is refused (3): nothing kept, nothing loaded" {
  run bash "$S/cnh-image-load" "$URL" "$(printf 'a%.0s' {1..64})"
  [ "$status" -eq 3 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  run ! grep -q '^podman' "$SHIM_LOG"
  [ -z "$(ls -A "$C/hps-cnh-images")" ]
}

@test "any host other than hps.ips is refused (3) with no curl call" {
  local u
  for u in "http://10.99.1.2/packages/cnh/hps-container.tar" "http://ips.example/packages/a.tar" "http://10.99.1.10/a.tar" "http://110.99.1.1/a.tar"; do
    run bash "$S/cnh-image-load" "$u" "$SUM"
    [ "$status" -eq 3 ]
    [[ "$output" == *"is not this node's IPS"* ]]
  done
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "other schemes, credentials, queries and traversal are refused (3)" {
  local u
  for u in "https://10.99.1.1/a.tar" "ftp://10.99.1.1/a.tar" "file:///etc/passwd" "http://user@10.99.1.1/a.tar" "http://10.99.1.1/a.tar?x=1" "http://10.99.1.1/../a.tar" "http://10.99.1.1" "http://10.99.1.1/a b"; do
    run bash "$S/cnh-image-load" "$u" "$SUM"
    [ "$status" -eq 3 ]
  done
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "no hps.ips on the command line is refused (3)" {
  echo "BOOT_IMAGE=bzImage hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps.ips"* ]]
}

@test "without the CNH disk mounted nothing is fetched (3)" {
  rm -f "$STATE/mounts"
  run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-disk-prepare"* ]]
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "several names from podman each get an IMAGE line; none is a failure (1)" {
  FAKE_LOADED="Loaded image(s): localhost/a:1,localhost/b:2" run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 0 ]
  [ "${lines[-2]}" = "IMAGE localhost/a:1 $SUM" ]
  [ "${lines[-1]}" = "IMAGE localhost/b:2 $SUM" ]
  FAKE_LOADED="nothing useful" run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 1 ]
}

@test "a failing curl or podman load fails (1)" {
  run bash "$S/cnh-image-load" "http://10.99.1.1/missing.tar" "$SUM"
  [ "$status" -eq 1 ]
  FAKE_LOAD_RC=125 run bash "$S/cnh-image-load" "$URL" "$SUM"
  [ "$status" -eq 1 ]
}

@test "bad hash and usage errors" {
  run bash "$S/cnh-image-load" "$URL" ABC
  [ "$status" -eq 3 ]
  run bash "$S/cnh-image-load" "$URL"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-image-load"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-image-load" --url "$URL" "$SUM"
  [ "$status" -eq 2 ]
}
