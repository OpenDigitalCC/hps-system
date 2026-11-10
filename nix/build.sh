#!/usr/bin/env bash
#
# build.sh - build the HPS netboot artefact sets and publish them for the IPS.
#
# Runs INSIDE the builder container (lab/builder/compose.yml). For each profile
# (audit, node-base, node-converged by default):
#   nix build <src>#<profile>          -> bzImage, initrd, boot.json (store)
# then computes the pin  nixos-<ver>-<yyyymmdd>-<nixpkgs short rev>-<content7>  and writes
#   <out>/<pin>/<profile>/{bzImage,initrd,boot.json}
#   <out>/<pin>/ipxe/{snponly.efi,ipxe.efi,undionly.kpxe,ipxe.json}   (IPS-09)
#   <out>/latest                       (the pin)
#   nix copy --to file://<cache>       (each profile's system closure)
# boot.json gains built_at, pin, sha256 and size (bzImage, initrd) on the way
# out of the store, plus ipxe {version}; <pin>/SHA256SUMS lists every profile's
# two files and the three iPXE binaries. ipxe.json carries version, files,
# sha256 and size of the iPXE binaries (built by `nix build <src>#ipxe`).
#
# Usage:
#   build.sh --out DIR --cache DIR [--src DIR] [--profiles "a b"] [--no-cache]
#            [--date YYYYMMDD]
# Environment: CTRL_EXEC_FLAKE=<flakeref> overrides the ctrl-exec input
# (--override-input ctrl-exec <flakeref>); BUILD_DATE as --date.
#
# --no-cache proves the rebuild route: no substituters, and --rebuild on the
# artefact derivation. A full from-source proof also needs a fresh /nix store
# (lab/builder/README.md).

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$SELF_DIR/.." && pwd)
OUT=""
CACHE=""
PROFILES="audit node-base node-converged"
IPXE_FILES="snponly.efi ipxe.efi undionly.kpxe"
IPXE_VERSION=""
NO_CACHE=0
BUILD_DATE="${BUILD_DATE:-}"
mkdir -p "${TMPDIR:-/tmp}"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
# Flags that belong after the subcommand (flake/build only, not copy).
FLAKE_FLAGS=()

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

log() {
  printf '[build] %s\n' "$*" >&2
}

run() {
  log "+ $*"
  "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) OUT="$2"; shift 2 ;;
      --cache) CACHE="$2"; shift 2 ;;
      --src) SRC="$2"; shift 2 ;;
      --profiles) PROFILES="$2"; shift 2 ;;
      --date) BUILD_DATE="$2"; shift 2 ;;
      --no-cache) NO_CACHE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "build.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  if [[ -z "$OUT" || -z "$CACHE" ]]; then
    echo "build.sh: --out and --cache are required" >&2
    exit 2
  fi
  if [[ ! -f "$SRC/flake.nix" ]]; then
    echo "build.sh: no flake.nix in $SRC" >&2
    exit 2
  fi
  if [[ -z "$BUILD_DATE" ]]; then
    BUILD_DATE=$(date -u +%Y%m%d)
  fi
  if [[ ! "$BUILD_DATE" =~ ^[0-9]{8}$ ]]; then
    echo "build.sh: --date must be YYYYMMDD" >&2
    exit 2
  fi
}

# Flags every nix build/flake call gets.
build_flags() {
  if [[ ! -f "$SRC/flake.lock" ]]; then
    log "no flake.lock in $SRC: inputs resolve to their newest revisions (run 'nix flake lock' and commit it)"
    FLAKE_FLAGS+=(--no-write-lock-file)
  fi
  if [[ -n "${CTRL_EXEC_FLAKE:-}" ]]; then
    FLAKE_FLAGS+=(--override-input ctrl-exec "$CTRL_EXEC_FLAKE")
  fi
}

nixpkgs_short_rev() {
  local rev
  rev=$(run nix "${NIX_FLAGS[@]}" flake metadata "${FLAKE_FLAGS[@]}" "path:$SRC" --json \
    | jq -r '.locks.nodes.nixpkgs.locked.rev // empty')
  if [[ -z "$rev" ]]; then
    echo "build.sh: cannot read the nixpkgs revision from flake metadata" >&2
    return 1
  fi
  printf '%s\n' "${rev:0:7}"
}

build_profile() {
  local profile="$1"
  local link="$2"
  local -a extra=()
  if [[ $NO_CACHE -eq 1 ]]; then
    extra+=(--option substituters "" --rebuild)
  fi
  run nix "${NIX_FLAGS[@]}" build "${FLAKE_FLAGS[@]}" "path:$SRC#$profile" --out-link "$link" "${extra[@]}"
  if [[ ! -f "$link/boot.json" ]]; then
    echo "build.sh: $profile built without boot.json" >&2
    return 1
  fi
}

# verify_store_file <link>/<file>: the store path holding the file must still
# match the hash nix recorded for it. A damaged path is not rebuilt by nix (it
# counts as present), so without this check every later build would publish the
# same damaged file. 2026-11-10: the audit initrd path had 24 MiB of zeros at its
# start after a disk-full build; the image downloaded and the kernel panicked.
verify_store_file() {
  local f
  f=$(readlink -f "$1")
  if ! run nix-store --verify-path "$(dirname "$f")"; then
    echo "build.sh: $1: store path $(dirname "$f") failed verification (its contents differ from the recorded hash); repair the store (nix-store --verify --check-contents --repair) and build again" >&2
    return 1
  fi
}

publish_profile() {
  local profile="$1"
  local link="$2"
  local pin="$3"
  local dest="$OUT/$pin/$profile"
  local built_at
  built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  verify_store_file "$link/bzImage" || return 1
  verify_store_file "$link/initrd" || return 1
  run mkdir -p "$dest"
  run install -m 0644 "$link/bzImage" "$dest/bzImage.tmp"
  run install -m 0644 "$link/initrd" "$dest/initrd.tmp"
  run mv -f "$dest/bzImage.tmp" "$dest/bzImage"
  run mv -f "$dest/initrd.tmp" "$dest/initrd"
  # Hash and size come from the published files, after the move (IPS-05): what
  # the IPS serves is checked against what was written here. boot.json goes
  # last, so a pin without one is visibly incomplete.
  local bz_sha bz_size rd_sha rd_size
  bz_sha=$(file_sha256 "$dest/bzImage")
  bz_size=$(file_size "$dest/bzImage")
  rd_sha=$(file_sha256 "$dest/initrd")
  rd_size=$(file_size "$dest/initrd")
  log "+ jq add built_at/pin/sha256/size -> $dest/boot.json"
  jq --arg built_at "$built_at" --arg pin "$pin" --arg profile "$profile" \
    --arg bz_sha "$bz_sha" --arg rd_sha "$rd_sha" \
    --argjson bz_size "$bz_size" --argjson rd_size "$rd_size" \
    --arg ipxe "$IPXE_VERSION" \
    '.built_at = $built_at | .pin = $pin | .profile = $profile
     | (if $ipxe != "" then .ipxe = {version: $ipxe} else . end)
     | .sha256 = {bzImage: $bz_sha, initrd: $rd_sha}
     | .size = {bzImage: $bz_size, initrd: $rd_size}' \
    "$link/boot.json" > "$dest/boot.json.tmp"
  run mv -f "$dest/boot.json.tmp" "$dest/boot.json"
}

# publish_ipxe <link> <pin>: <pin>/ipxe/{snponly.efi,ipxe.efi,undionly.kpxe,
# ipxe.json}. ipxe.json is the store's (version, files) plus built_at, pin and
# the sha256 and size of each binary, taken from the published files.
publish_ipxe() {
  local link="$1"
  local pin="$2"
  local dest="$OUT/$pin/ipxe"
  local f sha_json="{}" size_json="{}" sha size
  for f in $IPXE_FILES; do
    verify_store_file "$link/$f" || return 1
    [[ -s "$link/$f" ]] || { echo "build.sh: ipxe output lacks $f" >&2; return 1; }
  done
  [[ -f "$link/ipxe.json" ]] || { echo "build.sh: ipxe output lacks ipxe.json" >&2; return 1; }
  run mkdir -p "$dest"
  for f in $IPXE_FILES; do
    run install -m 0644 "$link/$f" "$dest/$f.tmp"
    run mv -f "$dest/$f.tmp" "$dest/$f"
    sha=$(file_sha256 "$dest/$f")
    size=$(file_size "$dest/$f")
    sha_json=$(jq -c --arg k "$f" --arg v "$sha" '.[$k] = $v' <<< "$sha_json")
    size_json=$(jq -c --arg k "$f" --argjson v "$size" '.[$k] = $v' <<< "$size_json")
  done
  log "+ jq add built_at/pin/sha256/size -> $dest/ipxe.json"
  jq --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pin "$pin" \
    --argjson sha "$sha_json" --argjson size "$size_json" \
    '.built_at = $built_at | .pin = $pin | .sha256 = $sha | .size = $size' \
    "$link/ipxe.json" > "$dest/ipxe.json.tmp"
  run mv -f "$dest/ipxe.json.tmp" "$dest/ipxe.json"
}

build_ipxe() {
  local link="$1"
  local -a extra=()
  if [[ $NO_CACHE -eq 1 ]]; then
    extra+=(--option substituters "" --rebuild)
  fi
  run nix "${NIX_FLAGS[@]}" build "${FLAKE_FLAGS[@]}" "path:$SRC#ipxe" --out-link "$link" "${extra[@]}"
  if [[ ! -f "$link/ipxe.json" ]]; then
    echo "build.sh: ipxe built without ipxe.json" >&2
    return 1
  fi
  IPXE_VERSION=$(jq -r '.version // empty' "$link/ipxe.json")
  if [[ -z "$IPXE_VERSION" ]]; then
    echo "build.sh: ipxe.json carries no version" >&2
    return 1
  fi
}

file_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

file_size() {
  stat -c %s "$1"
}

# write_sums <pin>: <pin>/SHA256SUMS over every profile's bzImage and initrd,
# in the sha256sum -c format with paths relative to the pin directory.
write_sums() {
  local pin="$1"
  local dir="$OUT/$pin"
  local profile f
  log "+ write $dir/SHA256SUMS"
  : > "$dir/SHA256SUMS.tmp"
  for profile in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort); do
    [[ -f "$dir/$profile/bzImage" && -f "$dir/$profile/initrd" ]] || continue
    printf '%s  %s/bzImage\n' "$(file_sha256 "$dir/$profile/bzImage")" "$profile" >> "$dir/SHA256SUMS.tmp"
    printf '%s  %s/initrd\n' "$(file_sha256 "$dir/$profile/initrd")" "$profile" >> "$dir/SHA256SUMS.tmp"
  done
  for f in $IPXE_FILES; do
    [[ -f "$dir/ipxe/$f" ]] || continue
    printf '%s  ipxe/%s\n' "$(file_sha256 "$dir/ipxe/$f")" "$f" >> "$dir/SHA256SUMS.tmp"
  done
  run mv -f "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS"
}

cache_profile() {
  local link="$1"
  local toplevel
  toplevel=$(jq -r '.init' "$link/boot.json")
  toplevel="${toplevel%/init}"
  run mkdir -p "$CACHE"
  run nix "${NIX_FLAGS[@]}" copy --to "file://$CACHE" "$toplevel"
}

WORK=""
cleanup() {
  if [[ -n "$WORK" ]]; then
    rm -rf "$WORK"
  fi
}

# content_suffix: 7 hex chars of sha256 over the built systems' store paths, in
# profile order. The date and the nixpkgs rev alone do not change when the HPS
# modules do; two builds of different images on one day must not share a pin.
content_suffix() {
  local profile init
  for profile in $PROFILES; do
    init=$(jq -r '.init' "$WORK/result-$profile/boot.json")
    printf '%s %s\n' "$profile" "$init"
  done | sha256sum | cut -c1-7
}

main() {
  local rev version pin profile link
  parse_args "$@"
  build_flags
  WORK="$OUT/.build-$$"
  run mkdir -p "$WORK"
  trap cleanup EXIT

  rev=$(nixpkgs_short_rev)
  for profile in $PROFILES; do
    build_profile "$profile" "$WORK/result-$profile"
  done
  build_ipxe "$WORK/result-ipxe"

  version=$(jq -r '.nixos_version' "$WORK/result-${PROFILES%% *}/boot.json")
  pin="nixos-${version}-${BUILD_DATE}-${rev}-$(content_suffix)"
  log "pin: $pin"

  publish_ipxe "$WORK/result-ipxe" "$pin"
  for profile in $PROFILES; do
    link="$WORK/result-$profile"
    publish_profile "$profile" "$link" "$pin"
    cache_profile "$link"
  done
  run mkdir -p "$CACHE"
  run nix "${NIX_FLAGS[@]}" copy --to "file://$CACHE" "$(readlink -f "$WORK/result-ipxe")"
  write_sums "$pin"

  printf '%s\n' "$pin" > "$OUT/latest.tmp"
  run mv -f "$OUT/latest.tmp" "$OUT/latest"
  log "done: $OUT/$pin ($PROFILES); latest -> $pin"
}

main "$@"
