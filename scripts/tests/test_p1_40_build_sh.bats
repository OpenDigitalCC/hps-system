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
    if [[ "$profile" == ipxe ]]; then
      store="$FAKE_STORE/hps-ipxe"
      mkdir -p "$store"
      for n in snponly.efi ipxe.efi undionly.kpxe; do echo "ipxe-$n" > "$store/$n"; done
      echo '{"version":"2.0.0","files":["snponly.efi","ipxe.efi","undionly.kpxe"],"nixpkgs_rev":"0123456789abcdef0123456789abcdef01234567"}' > "$store/ipxe.json"
      ln -sfn "$store" "$link"
      exit 0
    fi
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
  # Fake nix-store: records the call; --verify-path fails when FAKE_VERIFY_BAD
  # names a substring of the path.
  cat > "$TEST_DIR/bin/nix-store" <<'SHIM'
#!/bin/bash
echo "nix-store $*" >> "$NIX_LOG"
if [[ "$1" == --verify-path && -n "${FAKE_VERIFY_BAD:-}" && "$2" == *"$FAKE_VERIFY_BAD"* ]]; then
  echo "path '$2' was modified! expected hash 'sha256:x', got 'sha256:y'" >&2
  exit 1
fi
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/nix-store"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# The pin's content suffix, computed as build.sh does: sha256 over
# "<profile> <init store path>" lines in profile order, first 7 hex chars.
pin_for() {
  local profiles="$1" p suffix
  suffix=$(for p in $profiles; do
    printf '%s /nix/store/aaaa-nixos-system-%s/init\n' "$p" "$p"
  done | sha256sum | cut -c1-7)
  printf 'nixos-26.05-%s-0123456-%s\n' "${2:-20261109}" "$suffix"
}
ALL_PROFILES="audit node-base node-converged node-cnh"

@test "publishes <pin>/<profile>/{bzImage,initrd,boot.json} for every profile and writes latest" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  pin="$(pin_for "$ALL_PROFILES")"
  [ "$(cat "$OUT/latest")" = "$pin" ]
  for p in audit node-base node-converged node-cnh; do
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
  f="$OUT/$(pin_for "$ALL_PROFILES")/node-base/boot.json"
  jq -e '.kernel == "bzImage" and .initrd == "initrd"' "$f"
  jq -e '.init | test("^/nix/store/.*/init$")' "$f"
  jq -e '.cmdline | test("console=ttyS0")' "$f"
  jq -e '.nixpkgs_rev | length == 40' "$f"
  jq -e '.nixos_version == "26.05"' "$f"
  jq -e '.profile == "node-base"' "$f"
  jq -e --arg pin "$(pin_for "$ALL_PROFILES")" '.pin == $pin' "$f"
  jq -e '.built_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$f"
}

@test "pin is nixos-<version>-<yyyymmdd>-<7-char nixpkgs rev>-<7-char content hash>" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  run cat "$OUT/latest"
  [[ "$output" =~ ^nixos-26\.05-[0-9]{8}-[0-9a-f]{7}-[0-9a-f]{7}$ ]]
}

@test "the pin date defaults to today (UTC) when --date is absent" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE"
  [ "$status" -eq 0 ]
  today="$(date -u +%Y%m%d)"
  [ "$(cat "$OUT/latest")" = "$(pin_for "$ALL_PROFILES" "$today")" ]
}

@test "--no-cache builds with no substituters and --rebuild" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109 --no-cache
  [ "$status" -eq 0 ]
  run grep -c -- '--option substituters .*--rebuild' "$NIX_LOG"
  [ "$output" -eq 5 ]
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
  [ "$output" -eq 4 ]
  grep -q "copy --to file://$CACHE /nix/store/aaaa-nixos-system-audit$" "$NIX_LOG"
}

@test "CTRL_EXEC_FLAKE overrides the ctrl-exec input on every flake evaluation" {
  CTRL_EXEC_FLAKE="path:/ctrl-exec" run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  run grep -c -- '--override-input ctrl-exec path:/ctrl-exec' "$NIX_LOG"
  # metadata + 4 profile builds + ipxe; nix copy takes no flake flags
  [ "$output" -eq 6 ]
  # the flag sits after the subcommand, where nix accepts it
  run grep -c -E -- '(flake metadata|build) --no-write-lock-file --override-input' "$NIX_LOG"
  [ "$output" -eq 6 ]
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
  jq 'del(.built_at)' "$OUT/$(pin_for "$ALL_PROFILES")/audit/boot.json" > "$TEST_DIR/first.json"

  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  second="$(cd "$OUT" && find . -type f | sort)"
  [ "$first" = "$second" ]
  jq 'del(.built_at)' "$OUT/$(pin_for "$ALL_PROFILES")/audit/boot.json" > "$TEST_DIR/second.json"
  cmp "$TEST_DIR/first.json" "$TEST_DIR/second.json"
  # No scratch directory left behind.
  [ -z "$(find "$OUT" -maxdepth 1 -name '.build-*')" ]
}

@test "--profiles restricts the build" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109 --profiles audit
  [ "$status" -eq 0 ]
  [ -f "$OUT/$(pin_for audit)/audit/boot.json" ]
  [ ! -e "$OUT/$(pin_for audit)/node-base" ]
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

@test "every published kernel and initrd store path is verified first" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -eq 0 ]
  for p in audit node-base node-converged node-cnh; do
    grep -q "nix-store --verify-path $FAKE_STORE/hps-netboot-$p" "$NIX_LOG"
  done
}

@test "a damaged store path fails the build: no latest, nothing of that profile published" {
  FAKE_VERIFY_BAD=hps-netboot-audit run bash "$BUILD" --out "$OUT" --cache "$CACHE" --date 20261109
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed verification"* ]]
  [[ "$output" == *"--repair"* ]]
  [ ! -e "$OUT/latest" ]
  pin="$(pin_for "$ALL_PROFILES")"
  [ ! -e "$OUT/$pin/audit/initrd" ]
}
