#!/usr/bin/env bash
#
# build.sh - build the HPS netboot artefact sets and publish them for the IPS.
#
# Runs INSIDE the builder container (lab/builder/compose.yml). For each profile
# (audit, node-base, node-converged by default):
#   nix build <src>#<profile>          -> bzImage, initrd, boot.json (store)
# then computes the pin  nixos-<ver>-<yyyymmdd>-<nixpkgs short rev>  and writes
#   <out>/<pin>/<profile>/{bzImage,initrd,boot.json}
#   <out>/latest                       (the pin)
#   nix copy --to file://<cache>       (each profile's system closure)
# boot.json gains built_at and pin on the way out of the store.
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
NO_CACHE=0
BUILD_DATE="${BUILD_DATE:-}"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

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
    NIX_FLAGS+=(--no-write-lock-file)
  fi
  if [[ -n "${CTRL_EXEC_FLAKE:-}" ]]; then
    NIX_FLAGS+=(--override-input ctrl-exec "$CTRL_EXEC_FLAKE")
  fi
}

nixpkgs_short_rev() {
  local rev
  rev=$(run nix "${NIX_FLAGS[@]}" flake metadata "path:$SRC" --json \
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
  run nix "${NIX_FLAGS[@]}" build "path:$SRC#$profile" --out-link "$link" "${extra[@]}"
  if [[ ! -f "$link/boot.json" ]]; then
    echo "build.sh: $profile built without boot.json" >&2
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
  run mkdir -p "$dest"
  run install -m 0644 "$link/bzImage" "$dest/bzImage.tmp"
  run install -m 0644 "$link/initrd" "$dest/initrd.tmp"
  log "+ jq add built_at/pin -> $dest/boot.json"
  jq --arg built_at "$built_at" --arg pin "$pin" --arg profile "$profile" \
    '.built_at = $built_at | .pin = $pin | .profile = $profile' \
    "$link/boot.json" > "$dest/boot.json.tmp"
  run mv -f "$dest/bzImage.tmp" "$dest/bzImage"
  run mv -f "$dest/initrd.tmp" "$dest/initrd"
  run mv -f "$dest/boot.json.tmp" "$dest/boot.json"
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

  version=$(jq -r '.nixos_version' "$WORK/result-${PROFILES%% *}/boot.json")
  pin="nixos-${version}-${BUILD_DATE}-${rev}"
  log "pin: $pin"

  for profile in $PROFILES; do
    link="$WORK/result-$profile"
    publish_profile "$profile" "$link" "$pin"
    cache_profile "$link"
  done

  printf '%s\n' "$pin" > "$OUT/latest.tmp"
  run mv -f "$OUT/latest.tmp" "$OUT/latest"
  log "done: $OUT/$pin ($PROFILES); latest -> $pin"
}

main "$@"
