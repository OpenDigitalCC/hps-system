#!/usr/bin/env bash
#
# build.sh - build the HPS netboot artefact sets and publish them for the IPS.
#
# Runs INSIDE the builder container (lab/builder/compose.yml). For each profile
# (audit, node-base, node-converged, node-cnh, node-builder by default):
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
# Every published file is proved on disk (IPS-33 #3, #3b): the store original
# and the copy are both read with O_DIRECT (dd iflag=direct, past the page
# cache) and must agree; a copy that reads back differently is written again
# (HPS_BUILD_COPY_TRIES, default 3). boot.json, ipxe.json and SHA256SUMS
# record that proved hash, never one more read of the copy.
#
# Firmware layer: a profile whose store boot.json names firmware_layer (the
# audit image: firmware.cpio) has it published ONCE per store path, shared by
# every pin and never copied again while it is unchanged:
#   <out>/firmware/<store hash>-<name>.cpio
# The published boot.json drops firmware_layer and gains
#   extra_initrds: [{path: "firmware/<file>", sha256, size}]
# (path relative to <out>, which the IPS serves as /nixos/); the IPS has iPXE
# load each after the profile's initrd. SHA256SUMS lists it as ../firmware/<file>.
# hps-pins verify checks it; hps-pins prune removes layers no pin names.
#
# Usage:
#   build.sh --out DIR --cache DIR [--src DIR] [--profiles "a b"] [--no-cache]
#            [--date YYYYMMDD]
# Environment: CTRL_EXEC_FLAKE=<flakeref> overrides the ctrl-exec input
# (--override-input ctrl-exec <flakeref>); CTRL_EXEC_PLUGINS_FLAKE the same for
# the ctrl-exec-plugins input; BUILD_DATE as --date; BUILD_CACHE_PARAMS is
# appended to the cache URL (file://<cache>?<params>), so the builder signs and
# compresses what it copies into its site repository (docs/REPOSITORY.md:
# compression=zstd&secret-key=<file>).
#
# --no-cache proves the rebuild route: no substituters, and --rebuild on the
# artefact derivation. A full from-source proof also needs a fresh /nix store
# (lab/builder/README.md).

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$SELF_DIR/.." && pwd)
OUT=""
CACHE=""
PROFILES="audit node-base node-converged node-cnh node-builder"
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
  # A build never rewrites the committed lock (an --override-input below would
  # otherwise ask to); with no lock, inputs resolve to their newest revisions.
  FLAKE_FLAGS+=(--no-write-lock-file)
  if [[ ! -f "$SRC/flake.lock" ]]; then
    log "no flake.lock in $SRC: inputs resolve to their newest revisions (run 'nix flake lock' and commit it)"
  fi
  if [[ -n "${CTRL_EXEC_FLAKE:-}" ]]; then
    FLAKE_FLAGS+=(--override-input ctrl-exec "$CTRL_EXEC_FLAKE")
  fi
  if [[ -n "${CTRL_EXEC_PLUGINS_FLAKE:-}" ]]; then
    FLAKE_FLAGS+=(--override-input ctrl-exec-plugins "$CTRL_EXEC_PLUGINS_FLAKE")
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

# firmware_layer_file <link>: the layer file a profile's store boot.json names
# (firmware_layer), as a path under <link>; prints nothing for a profile
# without one. Fails for a name that is not a plain file name or a named file
# that is not there.
firmware_layer_file() {
  local link="$1" name
  name=$(jq -r '.firmware_layer // empty' "$link/boot.json")
  [[ -n "$name" ]] || return 0
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "build.sh: $link/boot.json: firmware_layer '$name' is not a plain file name" >&2
    return 1
  fi
  if [[ ! -s "$link/$name" ]]; then
    echo "build.sh: $link/boot.json names firmware_layer $name, which the build did not produce" >&2
    return 1
  fi
  printf '%s\n' "$link/$name"
}

# publish_firmware_layer <layer file>: <out>/firmware/<store hash>-<name>.cpio,
# named after the store path that holds the file, so one name is one content.
# An identical published file is kept (touched, so a prune running meanwhile
# sees it as new); a missing or different one is written via a temporary name.
# Sets FW_REL (path under <out>), FW_SHA and FW_SIZE (of the published file).
publish_firmware_layer() {
  local file="$1" real store name dest
  verify_store_file "$file" || return 1
  real=$(readlink -f "$file")
  store=$(basename "$(dirname "$real")")
  if [[ ! "$store" =~ ^[0-9a-z]{32}-[A-Za-z0-9._+-]+$ ]]; then
    echo "build.sh: firmware layer $real is not in a store path (<hash>-<name>/)" >&2
    return 1
  fi
  name="$store.cpio"
  dest="$OUT/firmware/$name"
  run mkdir -p "$OUT/firmware"
  if [[ -f "$dest" ]] && [[ "$(direct_sha256 "$dest")" == "$(direct_sha256 "$real")" ]]; then
    log "firmware layer unchanged: $dest"
    run touch "$dest"
    PUB_SHA=$(direct_sha256 "$real")
  else
    publish_file "$real" "$dest" || return 1
  fi
  FW_REL="firmware/$name"
  FW_SHA=$PUB_SHA
  FW_SIZE=$(file_size "$dest")
}

publish_profile() {
  local profile="$1"
  local link="$2"
  local pin="$3"
  local dest="$OUT/$pin/$profile"
  local built_at layer extra_initrds="[]"
  built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  verify_store_file "$link/bzImage" || return 1
  verify_store_file "$link/initrd" || return 1
  layer=$(firmware_layer_file "$link") || return 1
  if [[ -n "$layer" ]]; then
    publish_firmware_layer "$layer" || return 1
    extra_initrds=$(jq -cn --arg path "$FW_REL" --arg sha "$FW_SHA" --argjson size "$FW_SIZE" \
      '[{path: $path, sha256: $sha, size: $size}]')
  fi
  run mkdir -p "$dest"
  # Hash and size are of the published files, proved on disk after the move
  # (IPS-05, IPS-33 #3): what the IPS serves is checked against what was
  # written here. boot.json goes last, so a pin without one is visibly
  # incomplete.
  local bz_sha bz_size rd_sha rd_size
  publish_file "$link/bzImage" "$dest/bzImage" || return 1
  bz_sha=$PUB_SHA
  publish_file "$link/initrd" "$dest/initrd" || return 1
  rd_sha=$PUB_SHA
  bz_size=$(file_size "$dest/bzImage")
  rd_size=$(file_size "$dest/initrd")
  log "+ jq add built_at/pin/sha256/size -> $dest/boot.json"
  jq --arg built_at "$built_at" --arg pin "$pin" --arg profile "$profile" \
    --arg bz_sha "$bz_sha" --arg rd_sha "$rd_sha" \
    --argjson bz_size "$bz_size" --argjson rd_size "$rd_size" \
    --arg ipxe "$IPXE_VERSION" --argjson extra "$extra_initrds" \
    '.built_at = $built_at | .pin = $pin | .profile = $profile
     | (if $ipxe != "" then .ipxe = {version: $ipxe} else . end)
     | .sha256 = {bzImage: $bz_sha, initrd: $rd_sha}
     | .size = {bzImage: $bz_size, initrd: $rd_size}
     | del(.firmware_layer)
     | (if ($extra | length) > 0 then .extra_initrds = $extra else . end)' \
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
    publish_file "$link/$f" "$dest/$f" || return 1
    sha=$PUB_SHA
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

# direct_sha256 <file>: the sha256 of what the disk holds, read with O_DIRECT
# (dd iflag=direct): a buffered read may come from the page cache. On the busy
# network-backed lab disk, published files read back with zeroed runs and
# other hashes than build.sh had taken from the cache (IPS-33 #3).
direct_sha256() {
  dd if="$1" iflag=direct bs=4M status=none | sha256sum | cut -d' ' -f1
}

# publish_file <source> <dest>: copy a store file into place and prove it.
# The source (a store file, through its link) is read with O_DIRECT; the copy
# is written as <dest>.tmp, read back with O_DIRECT and compared; a copy that
# differs is written again, up to HPS_BUILD_COPY_TRIES (default 3) times with
# HPS_BUILD_COPY_PAUSE (default 10) seconds between. Then it is renamed into
# place and read back once more. Sets PUB_SHA, the proved hash.
publish_file() {
  local src="$1" dest="$2" want got try tries pause
  tries="${HPS_BUILD_COPY_TRIES:-3}"
  pause="${HPS_BUILD_COPY_PAUSE:-10}"
  want=$(direct_sha256 "$(readlink -f "$src")") || {
    echo "build.sh: cannot read $src with O_DIRECT" >&2
    return 1
  }
  for ((try = 1; try <= tries; try++)); do
    run install -m 0644 "$src" "$dest.tmp"
    # A failed sync (an I/O error, seen 2026-11-12) is logged; the O_DIRECT
    # read-back below decides.
    run sync -f "$dest.tmp" || log "sync of $dest.tmp failed"
    got=$(direct_sha256 "$dest.tmp") || got=unreadable
    if [[ "$got" == "$want" ]]; then
      break
    fi
    log "copy $dest.tmp reads back ${got:0:12}, store ${want:0:12} (try $try of $tries)"
    rm -f -- "$dest.tmp"
    if ((try == tries)); then
      echo "build.sh: $dest: the copy never read back as the store original ($want) after $tries tries" >&2
      return 1
    fi
    sleep "$pause"
  done
  run mv -f "$dest.tmp" "$dest"
  got=$(direct_sha256 "$dest") || got=unreadable
  if [[ "$got" != "$want" ]]; then
    echo "build.sh: $dest reads back $got after the rename, store original $want" >&2
    return 1
  fi
  PUB_SHA=$want
}

# recorded_sha256 <dir> <file>: the hash <dir>/boot.json (or ipxe.json) holds
# for <file>; fails when there is none.
recorded_sha256() {
  local dir="$1" f="$2" json sha
  json="$dir/boot.json"
  [[ -f "$json" ]] || json="$dir/ipxe.json"
  sha=$(jq -r --arg f "$f" '.sha256[$f] // empty' "$json")
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "build.sh: $json records no sha256 for $f" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

# write_sums <pin>: <pin>/SHA256SUMS over every profile's bzImage and initrd,
# in the sha256sum -c format with paths relative to the pin directory.
# The hashes are the ones boot.json and ipxe.json recorded on publishing,
# proved on disk then (IPS-33 #3b: a fresh read of the copy here once gave a
# hash of a bad read).
write_sums() {
  local pin="$1"
  local dir="$OUT/$pin"
  local profile f sha
  log "+ write $dir/SHA256SUMS"
  : > "$dir/SHA256SUMS.tmp"
  local -A layers=()
  for profile in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort); do
    [[ -f "$dir/$profile/bzImage" && -f "$dir/$profile/initrd" ]] || continue
    sha=$(recorded_sha256 "$dir/$profile" bzImage) || return 1
    printf '%s  %s/bzImage\n' "$sha" "$profile" >> "$dir/SHA256SUMS.tmp"
    sha=$(recorded_sha256 "$dir/$profile" initrd) || return 1
    printf '%s  %s/initrd\n' "$sha" "$profile" >> "$dir/SHA256SUMS.tmp"
    while IFS=$'\t' read -r f sha; do
      [[ -n "$f" ]] && layers["$f"]="$sha"
    done < <(jq -r '.extra_initrds[]? | [.path, .sha256] | @tsv' "$dir/$profile/boot.json")
  done
  # Shared layers outside the pin, by the hash boot.json recorded on
  # publishing (hashing ~800 MB again per pin would add nothing).
  for f in $(printf '%s\n' "${!layers[@]}" | sort); do
    printf '%s  ../%s\n' "${layers[$f]}" "$f" >> "$dir/SHA256SUMS.tmp"
  done
  for f in $IPXE_FILES; do
    [[ -f "$dir/ipxe/$f" ]] || continue
    sha=$(recorded_sha256 "$dir/ipxe" "$f") || return 1
    printf '%s  ipxe/%s\n' "$sha" "$f" >> "$dir/SHA256SUMS.tmp"
  done
  run mv -f "$dir/SHA256SUMS.tmp" "$dir/SHA256SUMS"
}

# cache_url: file://<cache>, with BUILD_CACHE_PARAMS as its query when set.
cache_url() {
  printf 'file://%s%s\n' "$CACHE" "${BUILD_CACHE_PARAMS:+?$BUILD_CACHE_PARAMS}"
}

cache_profile() {
  local link="$1"
  local toplevel
  toplevel=$(jq -r '.init' "$link/boot.json")
  toplevel="${toplevel%/init}"
  run mkdir -p "$CACHE"
  run nix "${NIX_FLAGS[@]}" copy --to "$(cache_url)" "$toplevel"
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
# A firmware layer counts too (one line per profile that has one), so a
# layer change alone also gives a new pin.
content_suffix() {
  local profile init layer
  for profile in $PROFILES; do
    init=$(jq -r '.init' "$WORK/result-$profile/boot.json")
    printf '%s %s\n' "$profile" "$init"
    layer=$(firmware_layer_file "$WORK/result-$profile") || return 1
    if [[ -n "$layer" ]]; then
      printf '%s-firmware %s\n' "$profile" "$(readlink -f "$layer")"
    fi
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
  run nix "${NIX_FLAGS[@]}" copy --to "$(cache_url)" "$(readlink -f "$WORK/result-ipxe")"
  write_sums "$pin"

  printf '%s\n' "$pin" > "$OUT/latest.tmp"
  run mv -f "$OUT/latest.tmp" "$OUT/latest"
  log "done: $OUT/$pin ($PROFILES); latest -> $pin"
}

main "$@"
