#!/usr/bin/env bash
#
# hps-builder-run - run one image build on the builder (docs/BUILDER.md).
#
# Started by the node script builder-build as the transient unit
# hps-builder-build (systemd-run, full root); not a node script itself.
#
# Usage: hps-builder-run --id ID --src DIR [--profiles "a b"] [--input NAME=DIR ...]
#
# The build store is /var/lib/hps-builder/root/nix (store URI
# local?root=/var/lib/hps-builder/root), on the builder disk. The netboot
# image's own store is RAM and is registered anew at every boot, so it cannot
# keep a build cache; a disk store can. The runner:
#
#   1. copies the running system's closure into the disk store (nix copy,
#      local, no download; only what a new image adds is copied), so every
#      tool the build calls exists in it
#   2. re-runs itself in a private mount namespace (unshare -m) in which the
#      disk store is bind-mounted at /nix: there nix/build.sh sees an
#      ordinary /nix, with the usual /nix/store paths (the binary cache
#      applies), and nix runs without the daemon, as root
#   3. runs <src>/nix/build.sh --src <src> --out <disk>/out --cache
#      <disk>/cache (the source's own build.sh), build directories and nix's
#      fetch cache on the disk
#
# Egress: https_proxy from hps.proxy= on the kernel command line (the IPS sets
# it from the cluster key egress_proxy); the IPS (hps.ips=) is reached
# directly. No hps.proxy=: no proxy is set, logged.
#
# Every command is logged to /var/lib/hps-builder/state/build-<id>.log. The
# record /var/lib/hps-builder/state/<id>.json (and last.json, a copy) holds
# id, state (running, ok, failed), started_at, finished_at, seconds, rc, pin,
# src and profiles; builder-status reads it.
#
# Overrides for tests: HPS_BUILDER_ROOT (prefix of /var/lib/hps-builder),
# HPS_CMDLINE (file read instead of /proc/cmdline), HPS_BUILDER_SYSTEM
# (instead of /run/current-system), HPS_BUILDER_NO_NS=1 (no namespace and no
# bind mount: the tests' nix is a shim).

set -euo pipefail

: "${HPS_BUILDER_ROOT:=}"
: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_BUILDER_SYSTEM:=/run/current-system}"
: "${HPS_BUILDER_NO_NS:=0}"

MNT="$HPS_BUILDER_ROOT/var/lib/hps-builder"
STORE_ROOT="$MNT/root"
STATE="$MNT/state"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
ID=""
SRC=""
PROFILES=""
INPUTS=()
INNER=0

log() {
  printf '[hps-builder-run] %s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

cmdline_value() {
  local key="$1" word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) ID=$2; shift 2 ;;
      --src) SRC=$2; shift 2 ;;
      --profiles) PROFILES=$2; shift 2 ;;
      --input) INPUTS+=("$2"); shift 2 ;;
      --inner) INNER=1; shift ;;
      *) echo "hps-builder-run: unknown argument $1" >&2; exit 2 ;;
    esac
  done
  [[ "$ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "hps-builder-run: --id must be <yyyymmdd>T<hhmmss>Z" >&2; exit 2; }
  [[ -f "$SRC/nix/build.sh" ]] || { echo "hps-builder-run: no nix/build.sh under '$SRC'" >&2; exit 2; }
}

# record <state> [rc] [pin]: write <id>.json and last.json.
record() {
  local state="$1" rc="${2:-}" pin="${3:-}" now
  now=$(date -u +%s)
  jq -n --arg id "$ID" --arg state "$state" --arg src "$SRC" --arg profiles "$PROFILES" \
    --arg rc "$rc" --arg pin "$pin" --argjson now "$now" --argjson t0 "${T0:-$now}" \
    '{id: $id, state: $state, src: $src, profiles: $profiles,
      started_at: ($t0 | todate),
      finished_at: (if $state == "running" then null else ($now | todate) end),
      seconds: ($now - $t0),
      rc: (if $rc == "" then null else ($rc | tonumber) end),
      pin: (if $pin == "" then null else $pin end)}' > "$STATE/$ID.json.tmp"
  mv -f "$STATE/$ID.json.tmp" "$STATE/$ID.json"
  cp -f "$STATE/$ID.json" "$STATE/last.json.tmp"
  mv -f "$STATE/last.json.tmp" "$STATE/last.json"
}

set_egress() {
  local proxy ips
  proxy=$(cmdline_value hps.proxy || true)
  ips=$(cmdline_value hps.ips || true)
  export no_proxy="${ips:+$ips,}localhost,127.0.0.1"
  export NO_PROXY="$no_proxy"
  if [[ "$proxy" =~ ^http://[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$ ]]; then
    export https_proxy="$proxy" HTTPS_PROXY="$proxy" http_proxy="$proxy" HTTP_PROXY="$proxy"
    log "egress through $proxy (no_proxy $no_proxy)"
  else
    log "no hps.proxy= on the kernel command line: no proxy set"
  fi
}

# inner: inside the private mount namespace.
inner() {
  local i name dir
  if [[ "$HPS_BUILDER_NO_NS" != 1 ]]; then
    run mount --make-rprivate /
    run mount --bind "$STORE_ROOT/nix" /nix
  fi
  export PATH="$HPS_BUILDER_SYSTEM/sw/bin:$PATH"
  export TMPDIR="$MNT/tmp/$ID"
  export XDG_CACHE_HOME="$MNT/tmp/xdg-cache"
  export NIX_REMOTE=local
  run mkdir -p -- "$TMPDIR" "$XDG_CACHE_HOME"
  set_egress
  unset CTRL_EXEC_FLAKE CTRL_EXEC_PLUGINS_FLAKE
  for i in "${INPUTS[@]}"; do
    name=${i%%=*}
    dir=${i#*=}
    case "$name" in
      ctrl-exec) export CTRL_EXEC_FLAKE="path:$dir" ;;
      ctrl-exec-plugins) export CTRL_EXEC_PLUGINS_FLAKE="path:$dir" ;;
      *) echo "hps-builder-run: unknown input $name" >&2; exit 2 ;;
    esac
    log "input $name -> path:$dir"
  done
  local -a bargs=(--src "$SRC" --out "$MNT/out" --cache "$MNT/cache")
  [[ -z "$PROFILES" ]] || bargs+=(--profiles "$PROFILES")
  set +e
  run bash "$SRC/nix/build.sh" "${bargs[@]}"
  local rc=$?
  set -e
  run rm -rf -- "$TMPDIR"
  return "$rc"
}

outer() {
  local rc pin="" log_file
  T0=$(date -u +%s)
  log_file="$STATE/build-$ID.log"
  exec >> "$log_file" 2>&1
  log "build $ID: src $SRC profiles '${PROFILES:-build.sh default}'"
  record running
  run mkdir -p -- "$STORE_ROOT" "$MNT/out" "$MNT/cache" "$MNT/tmp"
  set +e
  run nix "${NIX_FLAGS[@]}" copy --no-check-sigs --to "local?root=$STORE_ROOT" "$HPS_BUILDER_SYSTEM"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    if [[ "$HPS_BUILDER_NO_NS" == 1 ]]; then
      "$0" --inner "${ARGV[@]}"
    else
      run unshare --mount --propagation private -- "$0" --inner "${ARGV[@]}"
    fi
    rc=$?
  else
    log "copying the system closure into the disk store failed (exit $rc)"
  fi
  set -e
  if [[ $rc -eq 0 && -f "$MNT/out/latest" ]]; then
    pin=$(cat "$MNT/out/latest")
    record ok 0 "$pin"
    log "build $ID ok: pin $pin ($(( $(date -u +%s) - T0 )) s)"
  else
    record failed "$rc"
    log "build $ID FAILED: exit $rc ($(( $(date -u +%s) - T0 )) s)"
  fi
  return "$rc"
}

main() {
  ARGV=("$@")
  parse_args "$@"
  if [[ $INNER -eq 1 ]]; then
    inner
  else
    outer
  fi
}

main "$@"
