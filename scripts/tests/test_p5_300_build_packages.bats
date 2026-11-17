#!/usr/bin/env bats
#
# nix/build.sh package mode (--profiles pkg-<attr> / out-<attr>): a package is
# built by name from the flake, staged under <out>/pkgs/<attr>/ with pkg.json
# and SHA256SUMS, makes no pin, leaves `latest` alone; a mixture with netboot
# profiles is refused. nix is a PATH shim (jq is real).

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p5-300.XXXXXX")"
  export TEST_DIR
  export NIX_LOG="$TEST_DIR/nix.log"
  export NIX_STORE_DIR="$TEST_DIR/store"
  export OUT="$TEST_DIR/out"
  export CACHE="$TEST_DIR/cache"
  SRC="${BATS_TEST_DIRNAME}/../.."
  BUILD="$SRC/nix/build.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$NIX_STORE_DIR" "$OUT"

  cat > "$TEST_DIR/bin/nix" <<'EOF'
#!/bin/bash
echo "$*" >> "$NIX_LOG"
sub=""
for a in "$@"; do
  case "$a" in build|flake|copy|path-info) sub="$a"; break ;; esac
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
    attr="${inst##*#}"
    [[ -z "${FAKE_NO_ATTR:-}" || "$attr" != "$FAKE_NO_ATTR" ]] || { echo "error: flake does not provide attribute '$attr'" >&2; exit 1; }
    store="$NIX_STORE_DIR/aaaa-$attr-1.0"
    mkdir -p "$store/bin"
    echo "binary-$attr" > "$store/bin/$attr"
    ln -s "$store/bin/$attr" "$store/bin/$attr-link"
    ln -sfn "$store" "$link"
    ;;
  copy)
    # nix copy --to file://<dir>?compression=xz <path>: leave a narinfo and a nar
    for a in "$@"; do
      case "$a" in
        file://*'?compression=xz')
          d="${a#file://}"; d="${d%%\?*}"
          mkdir -p "$d/nar"; echo "nar" > "$d/nar/x.nar.xz"; echo "StorePath: x" > "$d/aaaa.narinfo" ;;
      esac
    done
    ;;
  path-info)
    case " $* " in
      *" -s "*) printf '%s\t%s\n' "${@: -1}" 1234 ;;
      *" -S "*) printf '%s\t%s\n' "${@: -1}" 98765 ;;
    esac
    ;;
esac
exit 0
EOF
  chmod +x "$TEST_DIR/bin/nix"
  printf '#!/bin/bash\necho "nix-store $*" >> "$NIX_LOG"\nexit 0\n' > "$TEST_DIR/bin/nix-store"
  chmod +x "$TEST_DIR/bin/nix-store"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "pkg-<attr> builds the attribute by name and stages cache, pkg.json and SHA256SUMS" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3 pkg-ctrl-exec-agent"
  [ "$status" -eq 0 ]
  grep -q 'build .*#om3 --out-link' "$NIX_LOG"
  grep -q 'build .*#ctrl-exec-agent --out-link' "$NIX_LOG"
  for a in om3 ctrl-exec-agent; do
    [ -f "$OUT/pkgs/$a/cache/aaaa.narinfo" ]
    [ -f "$OUT/pkgs/$a/pkg.json" ]
    jq -e --arg a "$a" --arg p "$NIX_STORE_DIR/aaaa-$a-1.0" \
      '.attr == $a and .kind == "pkg" and .store_path == $p and .nar_size == 1234 and .closure_size == 98765' "$OUT/pkgs/$a/pkg.json"
    (cd "$OUT/pkgs/$a" && sha256sum -c SHA256SUMS)
    grep -q ' \./cache/nar/x.nar.xz$' "$OUT/pkgs/$a/SHA256SUMS"
  done
}

@test "package mode makes no pin and leaves latest alone" {
  echo nixos-26.05-20261101-0123456-abcdef0 > "$OUT/latest"
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/latest")" = nixos-26.05-20261101-0123456-abcdef0 ]
  [ "$(find "$OUT" -maxdepth 1 -name 'nixos-*' | wc -l)" -eq 0 ]
  ! grep -q '#ipxe' "$NIX_LOG"
}

@test "pkg- also copies into the repository cache URL with BUILD_CACHE_PARAMS" {
  BUILD_CACHE_PARAMS="compression=zstd&secret-key=/k" run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3"
  [ "$status" -eq 0 ]
  grep -q "copy --to file://$CACHE?compression=zstd&secret-key=/k " "$NIX_LOG"
}

@test "out-<attr> stages the output as a file tree, links resolved, and no cache" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "out-om3-static"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/pkgs/om3-static/files/bin/om3-static")" = binary-om3-static ]
  [ ! -L "$OUT/pkgs/om3-static/files/bin/om3-static-link" ]
  [ "$(cat "$OUT/pkgs/om3-static/files/bin/om3-static-link")" = binary-om3-static ]
  [ ! -e "$OUT/pkgs/om3-static/cache" ]
  jq -e '.kind == "out"' "$OUT/pkgs/om3-static/pkg.json"
  grep -q ' \./files/bin/om3-static$' "$OUT/pkgs/om3-static/SHA256SUMS"
  ! grep -q 'copy --to' "$NIX_LOG"
}

@test "a package is replaced whole by a second build" {
  bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3"
  echo stale > "$OUT/pkgs/om3/cache/stale"
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/pkgs/om3/cache/stale" ]
  [ ! -e "$OUT/pkgs/om3.old" ]
  [ ! -e "$OUT/pkgs/om3.tmp" ]
}

@test "a mixture of packages and netboot profiles is refused before anything is built" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-om3 node-base"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mixes packages"* ]]
  ! grep -q ' build ' "$NIX_LOG"
}

@test "an attribute the flake does not have fails the build and stages nothing" {
  FAKE_NO_ATTR=nothing run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-nothing"
  [ "$status" -ne 0 ]
  [ ! -e "$OUT/pkgs/nothing" ]
}

@test "a name that is not a plain attribute is refused" {
  run bash "$BUILD" --out "$OUT" --cache "$CACHE" --profiles "pkg-Bad_Name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a package name"* ]]
}

@test "the flake exports the local package attributes build.sh is asked for" {
  for a in ctrl-exec-agent om3 om3-static ctrl-exec-executor-static qemu-headless qemu-host-cpu-only; do
    grep -qE "^ +$a = " "$SRC/flake.nix"
  done
}
