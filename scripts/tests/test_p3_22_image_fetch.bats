#!/usr/bin/env bats
#
# CS-3.3: image-fetch.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-22.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

URL="http://ips.example/hps-resources/images/base.qcow2"

body() {
  printf 'qcow2-bytes-of-the-image' > "$STATE/curl-body"
  SUM=$(/usr/bin/sha256sum "$STATE/curl-body")
  SUM=${SUM%% *}
  mkdir -p "$TEST_DIR/pool-images"
  DEST="$TEST_DIR/pool-images"
}

@test "fetches, verifies the hash and renames; curl is http-only with no redirects; last line IMAGE" {
  body
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IMAGE base $SUM $DEST/base.qcow2" ]
  [ -f "$DEST/base.qcow2" ]
  [ ! -e "$DEST/base.qcow2.part" ]
  grep -qF -- "curl --fail --silent --show-error --proto =http --max-redirs 0 --output $DEST/base.qcow2.part $URL" "$SHIM_LOG"
  [ "$(awk '{print $1}' "$SHIM_LOG" | paste -sd' ' -)" = "curl sha256sum" ]
}

@test "idempotent: the file present with the right hash is not fetched again" {
  body
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IMAGE base $SUM $DEST/base.qcow2" ]
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "a hash mismatch removes the .part, leaves no final file and exits 3" {
  body
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$(printf 'a%.0s' {1..64})" --dest "$DEST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  [ ! -e "$DEST/base.qcow2" ]
  [ ! -e "$DEST/base.qcow2.part" ]
}

@test "an existing file with the wrong hash is replaced by a verified download" {
  body
  echo stale > "$DEST/base.qcow2"
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$DEST/base.qcow2" "$STATE/curl-body"
}

@test "a mismatch on re-fetch keeps the old file (never replaced by unverified bytes)" {
  body
  echo stale > "$DEST/base.qcow2"
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$(printf 'b%.0s' {1..64})" --dest "$DEST"
  [ "$status" -eq 3 ]
  [ "$(cat "$DEST/base.qcow2")" = "stale" ]
}

@test "schemes other than http are refused (3) with no curl call" {
  body
  local u
  for u in https://ips.example/a.qcow2 ftp://ips.example/a.qcow2 file:///etc/passwd //ips.example/a ips.example/a "http:/ips.example/a"; do
    run bash "$S/image-fetch" base --from "$u" --sha256 "$SUM" --dest "$DEST"
    [ "$status" -eq 3 ]
  done
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "URLs with credentials, queries, traversal or odd characters are refused (3)" {
  body
  local u
  for u in "http://user@ips.example/a.qcow2" "http://ips.example/a.qcow2?x=1" "http://ips.example/../a" "http://ips.example/a b" 'http://ips.example/$a' "http://ips.example:80x/a" "http://ips.example"; do
    run bash "$S/image-fetch" base --from "$u" --sha256 "$SUM" --dest "$DEST"
    [ "$status" -eq 3 ]
  done
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "bad name, bad hash, missing dest directory are refused (3)" {
  body
  run bash "$S/image-fetch" Base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 3 ]
  run bash "$S/image-fetch" ../x --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 3 ]
  run bash "$S/image-fetch" base --from "$URL" --sha256 "ABC" --dest "$DEST"
  [ "$status" -eq 3 ]
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$TEST_DIR/none"
  [ "$status" -eq 3 ]
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest relative
  [ "$status" -eq 3 ]
  run ! grep -q '^curl' "$SHIM_LOG"
}

@test "usage errors exit 2" {
  run bash "$S/image-fetch"
  [ "$status" -eq 2 ]
  run bash "$S/image-fetch" base --from "$URL"
  [ "$status" -eq 2 ]
  run bash "$S/image-fetch" base --bogus x
  [ "$status" -eq 2 ]
}

@test "a failing curl exits 1 and leaves no final file" {
  body
  FAKE_CURL_RC=1 run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$DEST"
  [ "$status" -eq 1 ]
  [ ! -e "$DEST/base.qcow2" ]
}
zfs_shim() {
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/zfs" <<'SH'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
case "$1" in
  list) [[ -d "$HPS_POOL_ROOT/${*: -1}" || -f "$HPS_POOL_ROOT/${*: -1}.unmounted" ]] && exit 0; exit 1 ;;
  get) [[ -f "$HPS_POOL_ROOT/${*: -1}.unmounted" ]] && echo no || echo yes; exit 0 ;;
  set) exit 0 ;;
  mount) rm -f "$HPS_POOL_ROOT/$2.unmounted"; mkdir -p "$HPS_POOL_ROOT/$2"; exit 0 ;;
  create) mkdir -p "$HPS_POOL_ROOT/${*: -1}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$TEST_DIR/bin/zfs"
  export HPS_POOL_ROOT="$TEST_DIR/mnt"
  mkdir -p "$HPS_POOL_ROOT/lab/enc"
}

@test "--dest /<pool>/enc/images absent: the dataset is created below <pool>/enc, then used" {
  body
  zfs_shim
  PATH="$TEST_DIR/bin:$PATH" run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$HPS_POOL_ROOT/lab/enc/images"
  [ "$status" -eq 0 ]
  grep -qF "zfs create -o mountpoint=$HPS_POOL_ROOT/lab/enc/images lab/enc/images" "$SHIM_LOG"
  [ -f "$HPS_POOL_ROOT/lab/enc/images/base.qcow2" ]
}

@test "--dest /<pool>/enc/images: the dataset exists but is unmounted (pool mountpoint=none): mountpoint set, mounted, used" {
  body
  zfs_shim
  : > "$HPS_POOL_ROOT/lab/enc/images.unmounted"
  PATH="$TEST_DIR/bin:$PATH" run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$HPS_POOL_ROOT/lab/enc/images"
  [ "$status" -eq 0 ]
  grep -qF "zfs set mountpoint=$HPS_POOL_ROOT/lab/enc/images lab/enc/images" "$SHIM_LOG"
  grep -qF "zfs mount lab/enc/images" "$SHIM_LOG"
  run ! grep -q "zfs create" "$SHIM_LOG"
  [ -f "$HPS_POOL_ROOT/lab/enc/images/base.qcow2" ]
}

@test "--dest /<pool>/enc/images present: no zfs create" {
  body
  zfs_shim
  mkdir -p "$HPS_POOL_ROOT/lab/enc/images"
  PATH="$TEST_DIR/bin:$PATH" run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$HPS_POOL_ROOT/lab/enc/images"
  [ "$status" -eq 0 ]
  run ! grep -q "zfs" "$SHIM_LOG"
}

@test "an absent --dest that is not a pool's images path is refused, nothing created" {
  body
  zfs_shim
  PATH="$TEST_DIR/bin:$PATH" run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$HPS_POOL_ROOT/lab/enc/other"
  [ "$status" -eq 3 ]
  run ! grep -q "zfs" "$SHIM_LOG"
}

@test "a thin compute host's RAM cache /run/hps/images is created (no pool on the host)" {
  body
  export HPS_RUN_ROOT="$TEST_DIR/rr"
  local d="$HPS_RUN_ROOT/run/hps/images"
  [ ! -d "$d" ]
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$d"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IMAGE base $SUM $d/base.qcow2" ]
  [ "$(stat -c %a "$d")" = 700 ]
}

@test "any other missing --dest is still refused (only /run/hps/images is made)" {
  body
  export HPS_RUN_ROOT="$TEST_DIR/rr"
  run bash "$S/image-fetch" base --from "$URL" --sha256 "$SUM" --dest "$HPS_RUN_ROOT/run/hps/other"
  [ "$status" -eq 3 ]
}
