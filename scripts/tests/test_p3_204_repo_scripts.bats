#!/usr/bin/env bats
#
# The site repository's node scripts (docs/REPOSITORY.md): repo-seed and
# repo-update (fetch and check, start the job unit), the runner's seed,
# build and update jobs (nix, nix-store and curl stubbed: a fake store and a
# fake file binary cache), the signing key and the signing sweep, and
# repo-status.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers
load p3_202_helpers
load p3_204_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-204.XXXXXX")"
  export TEST_DIR
  p3_204_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

P1=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-glibc-2.42
P2=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-om3-3.0.0-rc60
P3=/nix/store/cccccccccccccccccccccccccccccccc-ctrl-exec-agent-0.14.7
D1=/nix/store/dddddddddddddddddddddddddddddddd-om3-3.0.0-rc60.drv

# a_runner: HPS_BUILDER_RUN records its arguments.
a_runner() {
  export HPS_BUILDER_RUN="$TEST_DIR/bin/fake-run"
  cat > "$HPS_BUILDER_RUN" <<'SHIM'
#!/usr/bin/env bash
echo "fake-run $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$HPS_BUILDER_RUN"
}

# a_list <path...>: a seed list served by the fake IPS; sets LSUM.
a_list() {
  printf '%s\n' "$@" > "$TEST_DIR/list.txt"
  LSUM=$(p3_171_sha "$TEST_DIR/list.txt")
  mkdir -p "$STATE/www/packages/repo"
  cp "$TEST_DIR/list.txt" "$STATE/www/packages/repo/seed-${LSUM:0:16}.txt"
}

log_of() {
  cat "$MNT/state/build-$1.log"
}

# --- repo-seed ------------------------------------------------------------------------

@test "seed: fetches the path list straight from the IPS, checks it, starts the seed job from the IPS cache" {
  p3_202_prepared
  a_runner
  a_list "$P1" "$P2"
  run bash "$S/repo-seed" ips "$LSUM"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" =~ ^REPO-SEED\ started\ id=[0-9]{8}T[0-9]{6}Z\ from=http://10\.99\.1\.1/nix-cache\ paths=2\ unit=hps-builder-build\ log=$MNT/state/build-[0-9T]+Z\.log$ ]]
  grep -qE "^curl .*--noproxy \* .*http://10\.99\.1\.1/packages/repo/seed-${LSUM:0:16}\.txt$" "$SHIM_LOG"
  grep -qE "^systemd-run --quiet --collect --unit hps-builder-build --description HPS repo seed [0-9T]+Z --setenv PATH=.* -- $HPS_BUILDER_RUN --id [0-9T]+Z --mode seed --from http://10\.99\.1\.1/nix-cache --paths $MNT/state/seed-${LSUM:0:16}\.txt$" "$SHIM_LOG"
  cmp "$TEST_DIR/list.txt" "$MNT/state/seed-${LSUM:0:16}.txt"
  run bash "$S/repo-seed" http://10.99.2.5:8091/nix-cache "$LSUM"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"from=http://10.99.2.5:8091/nix-cache paths=2 "* ]]
}

@test "seed: a list of another sum, a line that is no store path, a bad source, a running job or no disk is refused" {
  a_runner
  a_list "$P1"
  run bash "$S/repo-seed" ips "$LSUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not mounted"* ]]
  p3_202_prepared
  other=$(printf 'e%.0s' {1..64})
  cp "$STATE/www/packages/repo/seed-${LSUM:0:16}.txt" "$STATE/www/packages/repo/seed-${other:0:16}.txt"
  run bash "$S/repo-seed" ips "$other"
  [ "$status" -eq 3 ]
  [[ "$output" == *"has sha256 $LSUM, not $other"* ]]
  a_list "$P1" "/etc/passwd"
  run bash "$S/repo-seed" ips "$LSUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"1 line(s) that are not a store path"* ]]
  a_list "$P1"
  local f
  for f in https://x/nix-cache 'http://x/../y' file:///etc ftp://x 'http://x/a b'; do
    run bash "$S/repo-seed" "$f" "$LSUM"
    [ "$status" -eq 3 ]
  done
  echo active > "$STATE/unit-state"
  run bash "$S/repo-seed" ips "$LSUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"a job is running"* ]]
  rm -f "$STATE/unit-state"
  run bash "$S/repo-seed" ips
  [ "$status" -eq 2 ]
  run ! grep -q '^systemd-run' "$SHIM_LOG"
}

# --- repo-update ----------------------------------------------------------------------

@test "update: fetches and checks the source and inputs as builder-build does, starts the update job" {
  p3_202_prepared
  a_runner
  mkdir -p "$TEST_DIR/srctree/nix"
  echo '{ }' > "$TEST_DIR/srctree/flake.nix"
  echo 'echo' > "$TEST_DIR/srctree/nix/build.sh"
  sum=$(p3_202_source "$TEST_DIR/srctree")
  mkdir -p "$TEST_DIR/ce"
  echo '{ }' > "$TEST_DIR/ce/flake.nix"
  ce=$(p3_202_input ctrl-exec "$TEST_DIR/ce")
  run bash "$S/repo-update" "$sum" --input "ctrl-exec=$ce" --profiles "node-base"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" =~ ^REPO-UPDATE\ started\ id=[0-9T]+Z\ source=${sum:0:16}\ unit=hps-builder-build\ log= ]]
  grep -qE "^systemd-run .* --description HPS repo update [0-9T]+Z .* -- $HPS_BUILDER_RUN --id [0-9T]+Z --mode update --src $MNT/src/${sum:0:16} --profiles node-base --input ctrl-exec=$MNT/inputs/ctrl-exec-${ce:0:16}$" "$SHIM_LOG"
  run bash "$S/repo-update" "$sum" --upstream
  [ "$status" -eq 2 ]
  echo active > "$STATE/unit-state"
  run bash "$S/repo-update" "$sum"
  [ "$status" -eq 3 ]
  [[ "$output" == *"a job is running"* ]]
}

@test "build: --upstream reaches the runner; without it the runner gets none" {
  p3_202_prepared
  a_runner
  mkdir -p "$TEST_DIR/srctree/nix"
  echo '{ }' > "$TEST_DIR/srctree/flake.nix"
  echo 'echo' > "$TEST_DIR/srctree/nix/build.sh"
  sum=$(p3_202_source "$TEST_DIR/srctree")
  run bash "$S/builder-build" "$sum" --upstream
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *" upstream=yes "* ]]
  grep -qE -- "--mode build --src $MNT/src/${sum:0:16} --upstream$" "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$S/builder-build" "$sum"
  [[ "${lines[-1]}" == *" upstream=no "* ]]
  run ! grep -q -- '--upstream' "$SHIM_LOG"
}

# --- the runner: key, seed, publish ------------------------------------------------------

@test "run seed: the key is made once (secret 0600 outside the served tree), every path imported, re-hashed and signed" {
  p3_202_prepared
  printf '%s\n' "$P1" "$P2" > "$MNT/state/seed.txt"
  echo "$D1" >> "$STATE/store"
  run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$MNT/keys/repo.secret")" = 600 ]
  [ "$(stat -c %a "$MNT/keys")" = 700 ]
  [[ "$(cat "$MNT/repo/repo.pub")" =~ ^hps-repo-[a-z0-9-]+-1:[A-Za-z0-9+/]{43}=$ ]]
  [ ! -e "$MNT/repo/repo.secret" ]
  grep -q '^Priority: 10$' "$MNT/repo/nix-cache/nix-cache-info"
  grep -qxF "nix copy --no-check-sigs --from http://10.99.1.1/nix-cache --stdin" <(sed 's/--extra-experimental-features nix-command flakes //' "$SHIM_LOG")
  grep -qF "nix --extra-experimental-features nix-command flakes store verify --no-trust --stdin" "$SHIM_LOG"
  name=$(cut -d: -f1 "$MNT/repo/repo.pub")
  grep -qx "Sig: $name:x" "$MNT/repo/nix-cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo"
  grep -qx "Sig: $name:x" "$MNT/repo/nix-cache/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo"
  # no .drv is published
  [ ! -e "$MNT/repo/nix-cache/dddddddddddddddddddddddddddddddd.narinfo" ]
  grep -qF "copy --to file://$MNT/repo/nix-cache?compression=zstd&secret-key=$MNT/keys/repo.secret --stdin" "$SHIM_LOG"
  jq -e '.mode == "seed" and .state == "ok" and (.detail | startswith("seeded=2 verified=2 from=http://10.99.1.1/nix-cache published=2"))' "$MNT/state/last.json"
  log_of 20261112T080000Z | grep -q 'signatures not checked for this import only'
  # the second job keeps the key
  pub=$(cat "$MNT/repo/repo.pub")
  run bash "$B/hps-builder-run.sh" --id 20261112T080001Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$MNT/repo/repo.pub")" = "$pub" ]
  [ "$(grep -c -- '--generate-binary-cache-key' "$SHIM_LOG")" -eq 1 ]
}

@test "run seed: an import whose re-hash fails is failed and nothing is published" {
  p3_202_prepared
  printf '%s\n' "$P1" > "$MNT/state/seed.txt"
  FAKE_VERIFY_RC=1 run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -ne 0 ]
  jq -e '.mode == "seed" and .state == "failed"' "$MNT/state/last.json"
  [ -z "$(ls "$MNT/repo/nix-cache"/*.narinfo 2> /dev/null)" ]
  FAKE_COPY_FROM_RC=1 run bash "$B/hps-builder-run.sh" --id 20261112T080001Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -ne 0 ]
  jq -e '.state == "failed"' "$MNT/state/last.json"
}

@test "run: half a key is refused, never replaced; bad modes and sources are usage" {
  p3_202_prepared
  mkdir -p "$MNT/repo"
  echo "hps-repo-x-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$MNT/repo/repo.pub"
  printf '%s\n' "$P1" > "$MNT/state/seed.txt"
  run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -ne 0 ]
  log_of 20261112T080000Z | grep -q 'refusing to make a new key'
  run ! grep -q -- '--generate-binary-cache-key' "$SHIM_LOG"
  jq -e '.state == "failed"' "$MNT/state/last.json"
  run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode wipe
  [ "$status" -eq 2 ]
  run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode seed --from 'http://x/../y' --paths "$MNT/state/seed.txt"
  [ "$status" -eq 2 ]
  p3_204_src
  run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode update --src "$MNT/src/s1" --upstream
  [ "$status" -eq 2 ]
}

@test "publish: a narinfo left unsigned (an older build.sh) is signed; one that stays unsigned fails the job" {
  p3_202_prepared
  p3_204_key
  printf '%s\n' "$P1" > "$MNT/state/seed.txt"
  FAKE_UNSIGNED_COPY=1 run bash "$B/hps-builder-run.sh" --id 20261112T080000Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -eq 0 ]
  log_of 20261112T080000Z | grep -q '1 narinfo(s) in the repository lack the signature hps-repo-test-1: signing them'
  grep -qx 'Sig: hps-repo-test-1:z' "$MNT/repo/nix-cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo"
  rm -f "$MNT/repo/nix-cache/"*.narinfo
  FAKE_UNSIGNED_COPY=1 FAKE_SIGN_FAIL=1 run bash "$B/hps-builder-run.sh" --id 20261112T080001Z --mode seed --from http://10.99.1.1/nix-cache --paths "$MNT/state/seed.txt"
  [ "$status" -ne 0 ]
  log_of 20261112T080001Z | grep -q 'FAILED: 1 path(s) in the repository are still unsigned'
  jq -e '.state == "failed"' "$MNT/state/last.json"
}

# --- the runner: build -------------------------------------------------------------------

@test "run build: without upstream the repository is the only substituter, trusted by its own key; no proxy; results signed back" {
  p3_202_prepared
  p3_204_key
  p3_204_src
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=http://10.99.1.2:3128" > "$HPS_CMDLINE"
  run bash "$B/hps-builder-run.sh" --id 20261112T090000Z --mode build --src "$MNT/src/s1"
  [ "$status" -eq 0 ]
  grep -qxF "build.sh --src $MNT/src/s1 --out $MNT/out --cache $MNT/repo/nix-cache" "$SHIM_LOG"
  grep -qxF "env https_proxy= BUILD_CACHE_PARAMS=compression=zstd&secret-key=$MNT/keys/repo.secret" "$SHIM_LOG"
  grep -qxF "substituters = file://$MNT/repo/nix-cache" "$SHIM_LOG"
  grep -qxF "trusted-public-keys = $(cat "$MNT/repo/repo.pub")" "$SHIM_LOG"
  run ! grep -q 'extra-substituters' "$SHIM_LOG"
  grep -qx 'Sig: hps-repo-test-1:x' "$MNT/repo/nix-cache/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo"
  jq -e '.mode == "build" and .state == "ok" and .pin == "nixos-26.05-20261112-0123456-abcdef0" and .detail == "upstream=no published=1"' "$MNT/state/last.json"
}

@test "run build: with upstream the system's substituters are added through the proxy; a failed build still publishes" {
  p3_202_prepared
  p3_204_key
  p3_204_src
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=http://10.99.1.2:3128" > "$HPS_CMDLINE"
  FAKE_BUILD_RC=1 run bash "$B/hps-builder-run.sh" --id 20261112T090000Z --mode build --src "$MNT/src/s1" --upstream
  [ "$status" -eq 1 ]
  grep -qF "env https_proxy=http://10.99.1.2:3128 " "$SHIM_LOG"
  grep -qxF "extra-substituters = file://$MNT/repo/nix-cache" "$SHIM_LOG"
  grep -qxF "extra-trusted-public-keys = $(cat "$MNT/repo/repo.pub")" "$SHIM_LOG"
  [ -f "$MNT/repo/nix-cache/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo" ]
  jq -e '.state == "failed" and .rc == 1 and .detail == "upstream=yes published=1"' "$MNT/state/last.json"
}

# --- the runner: update ------------------------------------------------------------------

# an_update: two profiles' dry runs (one shared path), one fixed-output and one
# ordinary derivation to build, and GitHub tags for the three pinned inputs.
an_update() {
  p3_202_prepared
  p3_204_key
  p3_204_src
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=http://10.99.1.2:3128" > "$HPS_CMDLINE"
  printf 'these 2 derivations will be built:\n  %s\n  /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-om3-3.0.0-rc60-go-modules.drv\nthese 2 paths will be fetched (1.0 MiB download, 3.0 MiB unpacked):\n  %s\n  %s\n' \
    "$D1" "$P1" "$P3" > "$STATE/dry.node-base"
  printf 'this path will be fetched (1.0 MiB download, 3.0 MiB unpacked):\n  %s\n' "$P1" > "$STATE/dry.node-builder"
  cat > "$STATE/drvshow.json" <<EOF
{"$D1": {"outputs": {"out": {"path": "$P2"}}, "env": {}},
 "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-om3-3.0.0-rc60-go-modules.drv": {"outputs": {"out": {"hash": "abc", "method": "nar"}}, "env": {"outputHash": "sha256-x"}}}
EOF
  p3_204_tags opensvc/om3 v3.0.0-rc59 v3.0.0-rc60 v3.0.0-alpha111 v3.0.0-rc62 v3.0.0-beta9 v3.0.0-rc61 v2.1.9
  p3_204_tags OpenDigitalCC/ctrl-exec-plugins v0.3.10 v0.3.11
  p3_204_tags OpenDigitalCC/ctrl-exec v0.14.6 v0.14.7
}

@test "run update: substitutes what the builds would fetch, builds only the fixed-output inputs, reports newer releases" {
  an_update
  run bash "$B/hps-builder-run.sh" --id 20261112T100000Z --mode update --src "$MNT/src/s1"
  [ "$status" -eq 0 ]
  # every profile of the source's build.sh, and ipxe
  grep -qE "nix .*build --dry-run --no-link --no-write-lock-file path:$MNT/src/s1#node-base$" "$SHIM_LOG"
  grep -qE "nix .*build --dry-run .*path:$MNT/src/s1#node-builder$" "$SHIM_LOG"
  grep -qE "nix .*build --dry-run .*path:$MNT/src/s1#ipxe$" "$SHIM_LOG"
  [ "$(sort "$STATE/realised")" = "$(printf '%s\n' "$P1" "$P3")" ]
  [ "$(cat "$STATE/fod-built")" = /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-om3-3.0.0-rc60-go-modules.drv ]
  run ! grep -q "build .*$D1" "$SHIM_LOG"
  run ! grep -q 'build.sh' "$SHIM_LOG"
  grep -qF 'egress through http://10.99.1.2:3128' "$MNT/state/build-20261112T100000Z.log"
  grep -qxF 'INPUT github:OpenDigitalCC/ctrl-exec pinned=none newest=v0.14.7 unpinned' "$MNT/state/inputs.txt"
  grep -qxF 'INPUT github:opensvc/om3 pinned=v3.0.0-rc60 newest=v3.0.0-rc62 NEWER' "$MNT/state/inputs.txt"
  grep -qxF 'INPUT github:OpenDigitalCC/ctrl-exec-plugins pinned=v0.3.11 newest=v0.3.11 current' "$MNT/state/inputs.txt"
  run ! grep -q 'NixOS/nixpkgs' "$MNT/state/inputs.txt"
  grep -qE "^curl .*--proto =https http://gh.test/repos/opensvc/om3/tags\?per_page=100&page=1$" "$SHIM_LOG"
  jq -e '.mode == "update" and .state == "ok" and (.detail | startswith("fetched=2 fixed_output=1 left_to_build=1"))' "$MNT/state/last.json"
}

@test "run update: a fixed-output fetch that fails names the hosts its log names and fails the update; the rest is still published" {
  an_update
  echo /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-om3-3.0.0-rc60-go-modules.drv > "$STATE/fod-fail"
  echo "$P3" >> "$STATE/store"
  run bash "$B/hps-builder-run.sh" --id 20261112T100000Z --mode update --src "$MNT/src/s1"
  [ "$status" -eq 1 ]
  grep -qF 'UPDATE-FETCH-FAILED om3-3.0.0-rc60-go-modules.drv: hosts its log names: proxy.golang.org storage.googleapis.com' "$MNT/state/build-20261112T100000Z.log"
  grep -qF 'REPO-UPDATE FAILED' "$MNT/state/build-20261112T100000Z.log"
  [ -f "$MNT/repo/nix-cache/cccccccccccccccccccccccccccccccc.narinfo" ]
  jq -e '.state == "failed"' "$MNT/state/last.json"
}

@test "run update: without the tags API every input is unknown and the update still succeeds" {
  an_update
  rm -rf "$STATE/www/repos"
  run bash "$B/hps-builder-run.sh" --id 20261112T100000Z --mode update --src "$MNT/src/s1"
  [ "$status" -eq 0 ]
  grep -qxF 'INPUT github:opensvc/om3 pinned=v3.0.0-rc60 newest=unknown unknown' "$MNT/state/inputs.txt"
}

# --- repo-status ----------------------------------------------------------------------

@test "status: no disk, no key" {
  run bash "$S/repo-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"key: none yet"* ]]
  [ "${lines[-1]}" = "REPO state=nodisk key=no paths=0 signed=0 unsigned=0 packages=0 pins=0 last=none newer=0" ]
}

@test "status: the key, the cache counts, HPS's own packages with their signature, pins, the last job, newer inputs" {
  p3_202_prepared
  p3_204_key
  local c="$MNT/repo/nix-cache"
  printf 'StorePath: %s\nFileSize: 100\nSig: hps-repo-test-1:x\nSig: cache.nixos.org-1:y\n' "$P1" > "$c/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.narinfo"
  printf 'StorePath: %s\nFileSize: 200\nSig: hps-repo-test-1:x\n' "$P2" > "$c/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.narinfo"
  printf 'StorePath: %s\nFileSize: 300\n' "$P3" > "$c/cccccccccccccccccccccccccccccccc.narinfo"
  printf 'StorePath: /nix/store/ffffffffffffffffffffffffffffffff-hps-netboot-node-base\nFileSize: 1\nSig: hps-repo-test-1:x\n' > "$c/ffffffffffffffffffffffffffffffff.narinfo"
  mkdir -p "$MNT/out/nixos-a" "$MNT/out/nixos-b"
  echo nixos-b > "$MNT/out/latest"
  echo '{"id":"20261112T100000Z","mode":"update","state":"ok","rc":0,"seconds":9}' > "$MNT/state/last.json"
  printf 'INPUT github:opensvc/om3 pinned=v3.0.0-rc60 newest=v3.0.0-rc62 NEWER\nINPUT github:x/y pinned=v1.0.0 newest=v1.0.0 current\n' > "$MNT/state/inputs.txt"
  echo 'last line' > "$MNT/state/build-20261112T100000Z.log"
  run bash "$S/repo-status" --log 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO-PUBKEY hps-repo-test-1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="* ]]
  [[ "$output" == *"paths=4 signed=3 unsigned=1 nar_bytes=601"* ]]
  [[ "$output" == *"PACKAGE om3 3.0.0-rc60 $P2 signed=yes"* ]]
  [[ "$output" == *"PACKAGE ctrl-exec-agent 0.14.7 $P3 signed=no"* ]]
  [[ "$output" == *"PACKAGE hps-netboot-node-base - /nix/store/ffffffffffffffffffffffffffffffff-hps-netboot-node-base signed=yes"* ]]
  [[ "$output" != *"PACKAGE glibc"* ]]
  [[ "$output" == *"  nixos-b (latest)"* ]]
  [[ "$output" == *"pinned=v3.0.0-rc60 newest=v3.0.0-rc62 NEWER"* ]]
  [[ "$output" == *"  last line"* ]]
  [ "${lines[-1]}" = "REPO state=idle key=yes paths=4 signed=3 unsigned=1 packages=3 pins=2 last=update:20261112T100000Z:ok newer=1" ]
}

@test "status: a running job; a record left running by a gone job is failed; --log takes 0 to 2000" {
  p3_202_prepared
  echo '{"id":"20261112T100000Z","mode":"seed","state":"running"}' > "$MNT/state/last.json"
  echo active > "$STATE/unit-state"
  run bash "$S/repo-status" --log 0
  [[ "${lines[-1]}" == "REPO state=running "*" last=seed:20261112T100000Z:running newer=0" ]]
  rm -f "$STATE/unit-state"
  run bash "$S/repo-status" --log 0
  [[ "${lines[-1]}" == *" last=seed:20261112T100000Z:failed newer=0" ]]
  [[ "$output" == *"interrupted"* ]]
  run bash "$S/repo-status" --log 2001
  [ "$status" -eq 2 ]
  run bash "$S/repo-status" --bogus
  [ "$status" -eq 2 ]
}
