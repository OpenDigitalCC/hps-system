#!/bin/sh
# bootstrap.sh - fetch the node bundle from this node's own IPS into RAM and run
# its init. POSIX sh. Plan step 2 (docs/BUNDLE.md).
#
# The IPS serves this file as cmd=node_bootstrap; it is also inside the bundle
# (as bootstrap.sh), which is how the preset action bundle-refresh runs it again.
# It is the only thing a stock starter fetches by itself: the kernel line the
# IPS issued names the IPS (hps.ips=) and a hook that runs this script as root
# (systemd.run=, docs/BUNDLE.md "The hook").
#
# Usage: bootstrap.sh            at boot
#        bootstrap.sh refresh    again, by the bundle-refresh action
#
# What it does, in order:
#   1. read hps.ips= from the kernel command line (never from an argument)
#   2. fetch the bundle, a tar.gz, to /run/hps (RAM), retrying while the network
#      comes up
#   3. unpack it to /run/hps/b/<first 16 hex of its sha256>/ (once per content)
#   4. point /run/hps/bundle at it (one atomic rename), drop older copies
#   5. run <bundle>/init
#
# Overrides for tests: HPS_RUN_DIR, HPS_CMDLINE, HPS_FETCH_RETRY, HPS_PATH_EXTRA.

set -eu

# HPS_PATH_EXTRA (tests): directories in front of the system's
PATH="${HPS_PATH_EXTRA:+$HPS_PATH_EXTRA:}/run/current-system/sw/bin:/run/wrappers/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

RUN="${HPS_RUN_DIR:-/run/hps}"
CMDLINE="${HPS_CMDLINE:-/proc/cmdline}"
MODE="${1:-boot}"

log() {
  printf '[hps-bootstrap] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

case "$MODE" in
  boot | refresh) ;;
  *) die "usage: bootstrap.sh [refresh]" ;;
esac

# The IPS address: hps.ips= on the kernel command line, the first one. Words
# are split on spaces, so the quoted argument of the hook is never one word.
ips=""
for word in $(cat "$CMDLINE"); do
  case "$word" in
    hps.ips=*)
      ips="${word#hps.ips=}"
      break
      ;;
  esac
done
[ -n "$ips" ] || die "no hps.ips= on the kernel command line: this node was not booted by an HPS IPS"
case "$ips" in
  *[!0-9A-Za-z.:-]*) die "hps.ips '$ips' is not an address" ;;
esac

# --retry-all-errors: the network may not be up when the hook starts.
retry="${HPS_FETCH_RETRY:-60}"
url="http://${ips}/cgi-bin/boot_manager.sh?cmd=node_bundle"

mkdir -p "$RUN/b"
tmp="$RUN/bundle.tar.gz"
log "+ curl $url -> $tmp"
curl -fsS --retry "$retry" --retry-delay 2 --retry-all-errors --max-time 120 -o "$tmp" "$url" \
  || die "cannot fetch the bundle from $ips"

sum=$(sha256sum "$tmp")
id=$(printf '%s' "$sum" | cut -c1-16)
dir="$RUN/b/$id"
if [ ! -d "$dir" ]; then
  rm -rf "$dir.new"
  mkdir -p "$dir.new"
  tar -xzf "$tmp" -C "$dir.new" || die "the bundle does not unpack"
  [ -x "$dir.new/init" ] || die "the bundle has no init"
  mv "$dir.new" "$dir"
  log "bundle $id unpacked"
else
  log "bundle $id is already here"
fi
rm -f "$tmp"

# The bundle in use is the one /run/hps/bundle names. Swap by renaming a new
# link over it, so a reader never sees no bundle; then keep this one and the one
# before it.
old=""
[ -L "$RUN/bundle" ] && old=$(readlink "$RUN/bundle")
ln -sfn "b/$id" "$RUN/bundle.new"
mv -T "$RUN/bundle.new" "$RUN/bundle"
for d in "$RUN"/b/*; do
  [ -d "$d" ] || continue
  case "$d" in
    "$RUN/b/$id" | "$RUN/$old") ;;
    *) rm -rf "$d" ;;
  esac
done
log "bundle $id is live as $RUN/bundle"

# stdin is the pipe the hook fed this script through: init gets none
exec bash "$RUN/bundle/init" "$MODE" < /dev/null
