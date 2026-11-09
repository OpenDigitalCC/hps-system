#!/usr/bin/env bats
#
# nix/build.sh with a PATH shim for nix (jq is real): the published tree,
# boot.json, the pin format, --no-cache, the ctrl-exec input override, the
# lock-file handling and idempotency.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-40.XXXXXX")"
  export TEST_DIR
  export NIX_LOG="$TEST_DIR/nix.log"
  export FAKE_STORE="$TEST_DIR/store"
  export OUT="$TEST_DIR/out"
  export CACHE="$TEST_DIR/cache"
  SRC="${BATS_TEST_DIRNAME}/../.."
  BUILD="$SRC/nix/build.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$FAKE_STORE"

  # Fake nix: records every call; answers flake metadata, build and copy.
  cat > "$TEST_DIR/bin/nix" <<'EOF'
#!/bin/bash
echo "$*" >> "$NIX_LOG"
sub=""
for a in "$@"; do
  case "$a" in build|flake|copy) sub="$a"; break ;; esac
done
case "$sub" in
  flake)
    echo '{"locks":{"nodes":{"nixpkgs":{"locked":{"rev":"0123456789abcdef0123456789abcdef01234567"}}}}}'
    ;;
  build)
    inst=""; link=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out-link) link="$2"; shift 2 ;;
        *'#'*) inst="$1"; shift ;;
        *) shift ;;
      esac
    done
    profile="${inst##*#}"
    store="$FAKE_STORE/hps-netboot-$profile"
    mkdir -p "$store"
    echo "kernel-$profile" > "$store/bzImage"
    echo "initrd-$profile" > "$store/initrd"
    printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/aaaa-nixos-system-%s/init","cmdline":"initrd=initrd console=ttyS0,115200n8 console=tty0","nixpkgs_rev":"0123456789abcdef0123456789abcdef01234567","nixos_version":"26.05","profile":"%s"}\n' \
      "$profile" "$profile" > "$store/boot.json"
    ln -sfn "$store" "$link"
    ;;
  copy) : ;;
esac
exit "${FAKE_NIX_RC:-0}"
EOF
  chmod +x "$TEST_DIR/bin/nix"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "publishes <pin>/<profile>/{bzImage,initrd,boot.json} for every profile and writes latest" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  pin="nixos-26.05-20261109-0123456"
  [ "$(cat "$OUT/latest")" = "$pin" ]
  for p in audit node-base node-converged; do
    [ -f "$OUT/$pin/$p/bzImage" ]
    [ -f "$OUT/$pin/$p/initrd" ]
    [ -f "$OUT/$pin/$p/boot.json" ]
    [ ! -L "$OUT/$pin/$p/bzImage" ]
  done
  [ "$(cat "$OUT/$pin/audit/bzImage")" = "kernel-audit" ]
}

@test "boot.json is valid and carries every required key" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  f="$OUT/nixos-26.05-20261109-0123456/node-base/boot.json"
  jq -e '.kernel == "bzImage" and .initrd == "initrd"' "$f"
  jq -e '.init | test("^/nix/store/.*/init$")' "$f"
  jq -e '.cmdline | test("console=ttyS0")' "$f"
  jq -e '.nixpkgs_rev | length == 40' "$f"
  jq -e '.nixos_version == "26.05"' "$f"
  jq -e '.profile == "node-base"' "$f"
  jq -e '.pin == "nixos-26.05-20261109-0123456"' "$f"
  jq -e '.built_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$f"
}

@test "pin is nixos-<version>-<yyyymmdd>-<7-char nixpkgs rev>" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  run cat "$OUT/latest"
  [[ "$output" =~ ^nixos-26\.05-[0-9]{8}-[0-9a-f]{7}$ ]]
}

@test "the pin date defaults to today (UTC) when --date is absent" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE"
  [ "$status" -eq 0 ]
  today="$(date -u +%Y%m%d)"
  [ "$(cat "$OUT/latest")" = "nixos-26.05-${today}-0123456" ]
}

@test "--no-cache builds with no substituters and --rebuild" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109 --no-cache
  [ "$status" -eq 0 ]
  run grep -c -- '--option substituters .*--rebuild' "$NIX_LOG"
  [ "$output" -eq 3 ]
}

@test "without --no-cache the build uses the configured substituters" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  ! grep -q -- '--rebuild' "$NIX_LOG"
  ! grep -q -- 'substituters' "$NIX_LOG"
}

@test "each profile's system closure is copied to the file binary cache" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  run grep -c "copy --to file://$CACHE /nix/store/aaaa-nixos-system-" "$NIX_LOG"
  [ "$output" -eq 3 ]
  grep -q "copy --to file://$CACHE /nix/store/aaaa-nixos-system-audit$" "$NIX_LOG"
}

@test "CTRL_EXEC_FLAKE overrides the ctrl-exec input on every flake evaluation" {
  CTRL_EXEC_FLAKE="path:/ctrl-exec" run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  run grep -c -- '--override-input ctrl-exec path:/ctrl-exec' "$NIX_LOG"
  # metadata + 3 builds; nix copy takes no flake flags
  [ "$output" -eq 4 ]
  # the flag sits after the subcommand, where nix accepts it
  run grep -c -E -- '(flake metadata|build) --no-write-lock-file --override-input' "$NIX_LOG"
  [ "$output" -eq 4 ]
}

@test "without a flake.lock the lock file is not written; with one it is left alone" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  grep -q -- '--no-write-lock-file' "$NIX_LOG"

  mkdir -p "$TEST_DIR/src"
  cp "$SRC/flake.nix" "$TEST_DIR/src/"
  echo '{}' > "$TEST_DIR/src/flake.lock"
  : > "$NIX_LOG"
  run bash "$BUILD" --src "$TEST_DIR/src" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  ! grep -q -- '--no-write-lock-file' "$NIX_LOG"
}

@test "a second run produces the same tree" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  first="$(cd "$OUT" && find . -type f | sort)"
  jq 'del(.built_at)' "$OUT/nixos-26.05-20261109-0123456/audit/boot.json" > "$TEST_DIR/first.json"

  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  second="$(cd "$OUT" && find . -type f | sort)"
  [ "$first" = "$second" ]
  jq 'del(.built_at)' "$OUT/nixos-26.05-20261109-0123456/audit/boot.json" > "$TEST_DIR/second.json"
  cmp "$TEST_DIR/first.json" "$TEST_DIR/second.json"
  # No scratch directory left behind.
  [ -z "$(find "$OUT" -maxdepth 1 -name '.build-*')" ]
}

@test "--profiles restricts the build" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109 --profiles audit
  [ "$status" -eq 0 ]
  [ -f "$OUT/nixos-26.05-20261109-0123456/audit/boot.json" ]
  [ ! -e "$OUT/nixos-26.05-20261109-0123456/node-base" ]
}

@test "refuses to run without --out and --cache, with a bad date, or with a failing nix" {
  run bash "$BUILD" --out "$OUT"
  [ "$status" -eq 2 ]
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 2026
  [ "$status" -eq 2 ]
  FAKE_NIX_RC=1 run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [ ! -e "$OUT/latest" ]
}
