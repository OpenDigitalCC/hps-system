#!/usr/bin/env bash
#
# hps-apk-build - build one Alpine package set in a chroot on the builder
# (docs/BUILDER.md "Local packages: the Alpine chroot").
#
# Started by the node script builder-apk-build as the transient unit
# hps-builder-build (systemd-run, full root; the unit nix builds and the repository
# jobs use too, so one job at a time); not a node script itself.
#
# Usage: hps-apk-build --id ID --src DIR --recipe NAME
#
# DIR is an unpacked hps-system source (builder-build's); NAME names a directory
# DIR/alpine/recipes/NAME. The recipe is DATA: PINS (every value taken from outside
# the tree), recipe.conf (the package set and what to check) and the patch it names.
# Nothing in the recipe is executed here. What runs is this script and
# hps-apk-inner, both part of the builder image.
#
# What it does, in order (every command is logged):
#   1. reads PINS and recipe.conf with a strict parser (no sourcing; every value
#      matched against a pattern). A value that is still a placeholder
#      (RECORD-ME) switches to RECORD MODE: it fetches what the pins name, prints
#      every value it saw as PIN-OBSERVED lines, changes nothing and fails (4), so
#      that the values are looked at by a person and recorded in the tree.
#   2. fetches, through the egress proxy only (hps.proxy= on the kernel line): the
#      Alpine minirootfs for the pinned release, checked against the pinned sha256,
#      and each file of the pinned aports commit's directory (raw, by commit id),
#      each checked against its pinned sha256. The packages and their indexes are
#      fetched by apk inside the chroot, which verifies Alpine's signatures.
#   3. keeps the chroot on the builder's disk, <disk>/apk/chroot/<release>-<sha12>,
#      made from the minirootfs once, and runs everything below in a private
#      mount, PID, IPC and UTS namespace (unshare), with a tmpfs /dev of six device
#      nodes (the host's /dev is not visible), /proc of that PID namespace, the
#      host's resolv.conf and the proxy in the environment.
#   4. in the chroot as root: apk add bash, curl and alpine-sdk (signed packages), then
#      hps-apk-inner prepare (the user `builder`, the makedepends); as `builder`:
#      hps-apk-inner build (patch, a throwaway abuild key, abuild); the key is
#      removed afterwards and never leaves the chroot.
#   5. selects the recipe's package set from what was built, builds the meta
#      package whose depends are exactly that set at its version-release (read
#      from the built files, not written down), and checks the result: the helper
#      binary is in the set, the library carries the AppArmor driver (the helper's
#      compiled-in path is in a library of the set), no file of the set is in the
#      directory the node's own profile texts are written to, every dependency
#      on the package's own name is satisfied inside the set, every version is
#      the same and its release at least min_pkgrel. Anything else fails the job.
#   6. publishes <disk>/out/pkgs/<recipe>/{files/*.apk,pkg.json,SHA256SUMS}, the
#      layout lab/builder/pkg-fetch.sh and hps-starter add-local take.
#
# Record: <disk>/state/<id>.json and last.json (mode apk), log build-<id>.log, as
# hps-builder-run writes them. Exit: 0 ok, 2 usage, 3 refused (recipe, pins, no
# proxy), 4 pins observed (record mode), 1 a step failed.
#
# Overrides for tests: HPS_BUILDER_ROOT (prefix of /var/lib/hps-builder), HPS_CMDLINE,
# HPS_APK_INNER (the inner script), HPS_BUILDER_NO_NS=1 (no namespace, no mounts),
# HPS_RESOLV (instead of /etc/resolv.conf).

set -euo pipefail

: "${HPS_BUILDER_ROOT:=}"
: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_APK_INNER:=/etc/hps/hps-apk-inner}"
: "${HPS_BUILDER_NO_NS:=0}"
: "${HPS_RESOLV:=/etc/resolv.conf}"

MNT="$HPS_BUILDER_ROOT/var/lib/hps-builder"
STATE_DIR="$MNT/state"
APK_DIR="$MNT/apk"
OUT_PKGS="$MNT/out/pkgs"
ID=""
SRC=""
RECIPE=""
INNER=0
RDIR=""
RECORDING=0
DETAIL=""
WORK=""
CH=""
PROXY=""
NOPROXY=""
declare -A PIN=()
declare -A CONF=()
declare -A FILES=()
FILE_ORDER=()

PLACEHOLDER=RECORD-ME
HEX64='^[0-9a-f]{64}$'
HTTPS_RE='^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._%-]+)*$'
declare -A PIN_RE=(
  [alpine_mirror]="$HTTPS_RE"
  [alpine_release]='^[0-9]+\.[0-9]+$'
  [minirootfs_file]='^alpine-minirootfs-[0-9][0-9A-Za-z._-]*-x86_64\.tar\.gz$'
  [minirootfs_sha256]="$HEX64"
  [aports_raw]="$HTTPS_RE"
  [aports_api]="$HTTPS_RE"
  [aports_ref]='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  [aports_commit]='^[0-9a-f]{40}$'
  [aports_dir]='^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$'
)
declare -A CONF_RE=(
  [pkgname]='^[a-z][a-z0-9-]*$'
  [meta]='^[a-z][a-z0-9-]*$'
  [parts]='^(main|[a-z][a-z0-9-]*)( (main|[a-z][a-z0-9-]*))*$'
  [patch]='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
  [helper]='^[a-z][A-Za-z0-9._/+-]*$'
  [driver_string]='^/[A-Za-z0-9._/+-]+$'
  [forbid_prefix]='^[a-z][A-Za-z0-9._/+-]*$'
  [min_pkgrel]='^[0-9]{1,4}$'
)

log() {
  printf '[hps-apk-build] %s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

usage_fail() {
  echo "hps-apk-build: $*" >&2
  exit 2
}

refuse() {
  log "refused: $*"
  exit 3
}

die() {
  log "FAILED: $*"
  return 1
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
      --recipe) RECIPE=$2; shift 2 ;;
      --inner) INNER=1; shift ;;
      *) usage_fail "unknown argument $1" ;;
    esac
  done
  [[ "$ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || usage_fail "--id must be <yyyymmdd>T<hhmmss>Z"
  [[ "$RECIPE" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || usage_fail "--recipe is not a recipe name"
  [[ -n "$SRC" && -d "$SRC" ]] || usage_fail "--src must name a source tree"
}

# record <state> [rc]: <id>.json and last.json, the shape hps-builder-run writes.
record() {
  local state="$1" rc="${2:-}" now
  now=$(date -u +%s)
  jq -n --arg id "$ID" --arg state "$state" --arg src "$SRC" --arg profiles "apk:$RECIPE" \
    --arg rc "$rc" --arg detail "$DETAIL" --argjson now "$now" --argjson t0 "${T0:-$now}" \
    '{id: $id, mode: "apk", state: $state, src: $src, profiles: $profiles,
      started_at: ($t0 | todate),
      finished_at: (if $state == "running" then null else ($now | todate) end),
      seconds: ($now - $t0),
      rc: (if $rc == "" then null else ($rc | tonumber) end),
      pin: null,
      detail: (if $detail == "" then null else $detail end)}' > "$STATE_DIR/$ID.json.tmp"
  mv -f "$STATE_DIR/$ID.json.tmp" "$STATE_DIR/$ID.json"
  cp -f "$STATE_DIR/$ID.json" "$STATE_DIR/last.json.tmp"
  mv -f "$STATE_DIR/last.json.tmp" "$STATE_DIR/last.json"
}

#--- the recipe: data, read strictly --------------------------------------------------

# trim_line <text>: no leading or trailing blanks, no comment.
trim_line() {
  local l="${1%%#*}"
  l="${l#"${l%%[![:space:]]*}"}"
  printf '%s\n' "${l%"${l##*[![:space:]]}"}"
}

read_recipe() {
  local line key val name sum k
  RDIR="$SRC/alpine/recipes/$RECIPE"
  [[ -d "$RDIR" && ! -L "$RDIR" ]] || refuse "no recipe directory alpine/recipes/$RECIPE in the source"
  for k in PINS recipe.conf; do
    [[ -f "$RDIR/$k" && ! -L "$RDIR/$k" ]] || refuse "the recipe has no plain file $k"
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim_line "$line")
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^file[[:space:]]+([A-Za-z0-9][A-Za-z0-9._+-]*)[[:space:]]+([A-Za-z0-9-]+)$ ]]; then
      name=${BASH_REMATCH[1]}
      sum=${BASH_REMATCH[2]}
      [[ -z "${FILES[$name]:-}" ]] || refuse "PINS names $name twice"
      FILES[$name]=$sum
      FILE_ORDER+=("$name")
    elif [[ "$line" =~ ^([a-z_0-9]+)=([^[:space:]]*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      [[ -n "${PIN_RE[$key]:-}" ]] || refuse "PINS: unknown key '$key'"
      PIN[$key]=$val
    else
      refuse "PINS: cannot read the line '$line'"
    fi
  done < "$RDIR/PINS"
  for key in "${!PIN_RE[@]}"; do
    [[ -n "${PIN[$key]:-}" ]] || refuse "PINS has no $key"
    if [[ "${PIN[$key]}" == "$PLACEHOLDER" ]]; then
      RECORDING=1
    elif ! [[ "${PIN[$key]}" =~ ${PIN_RE[$key]} ]]; then
      refuse "PINS: $key '${PIN[$key]}' does not fit its pattern"
    fi
  done
  [[ -n "${FILES[APKBUILD]:-}" ]] || refuse "PINS names no APKBUILD"
  for name in "${FILE_ORDER[@]}"; do
    if [[ "${FILES[$name]}" == "$PLACEHOLDER" ]]; then
      RECORDING=1
    elif ! [[ "${FILES[$name]}" =~ $HEX64 ]]; then
      refuse "PINS: the sha256 of $name is not 64 hex digits"
    fi
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim_line "$line")
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^([a-z_]+)=(.*)$ ]] || refuse "recipe.conf: cannot read the line '$line'"
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    [[ -n "${CONF_RE[$key]:-}" ]] || refuse "recipe.conf: unknown key '$key'"
    [[ "$val" =~ ${CONF_RE[$key]} ]] || refuse "recipe.conf: $key '$val' does not fit its pattern"
    CONF[$key]=$val
  done < "$RDIR/recipe.conf"
  for key in "${!CONF_RE[@]}"; do
    [[ -n "${CONF[$key]:-}" ]] || refuse "recipe.conf has no $key"
  done
  [[ "${CONF[meta]}" == "$RECIPE" ]] || refuse "recipe.conf: meta '${CONF[meta]}' is not the recipe name '$RECIPE' (the output directory)"
  [[ -f "$RDIR/${CONF[patch]}" && ! -L "$RDIR/${CONF[patch]}" ]] || refuse "the patch ${CONF[patch]} is not a plain file of the recipe"
}

#--- egress and fetching ----------------------------------------------------------------

set_egress() {
  local ips
  PROXY=$(cmdline_value hps.proxy || true)
  ips=$(cmdline_value hps.ips || true)
  NOPROXY="${ips:+$ips,}localhost,127.0.0.1"
  [[ "$PROXY" =~ ^http://[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$ ]] ||
    refuse "no hps.proxy=http://<host>:<port> on the kernel command line: the build reaches the internet only through the egress proxy"
  export https_proxy="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" HTTP_PROXY="$PROXY" no_proxy="$NOPROXY" NO_PROXY="$NOPROXY"
  log "egress through $PROXY"
}

# fetch <url> <file>: https only, through the proxy in the environment.
fetch() {
  run curl --fail --silent --show-error --location --proto =https --proto-redir =https --max-redirs 5 \
    --max-time 1800 --output "$2" "$1"
}

sha_of() {
  local s
  s=$(sha256sum -- "$1")
  printf '%s\n' "${s%% *}"
}

# observed <what> <value> [pinned]: one PIN-OBSERVED line.
observed() {
  local state=new
  if [[ -n "${3:-}" && "$3" != "$PLACEHOLDER" ]]; then
    [[ "$3" == "$2" ]] && state=matches-pin || state="DIFFERS-from-pin($3)"
  fi
  printf 'PIN-OBSERVED %s=%s %s\n' "$1" "$2" "$state" | tee -a "$WORK/observed.txt" >&2
}

# yaml_minirootfs <latest-releases.yaml>: "<file> <sha256>" of the alpine-minirootfs entry
# (the entry names its file as iso: or file:; unverified which one Alpine's yaml uses).
yaml_minirootfs() {
  awk '
    function flush() { if (!done && fl && f != "") { print f, s; done = 1 } f = ""; s = ""; fl = 0 }
    /^-([[:space:]]|$)/ { flush(); $0 = substr($0, 2) }
    /^[[:space:]]+(iso|file):/ { f = $2 }
    /^[[:space:]]+sha256:/ { s = $2 }
    /^[[:space:]]+flavor:[[:space:]]*alpine-minirootfs[[:space:]]*$/ { fl = 1 }
    END { flush() }' "$1"
}

# record_mode: look at what the pins name, print it, change nothing. The commit is the
# one the pinned ref (a stable branch) points at now.
record_mode() {
  local commit name f yaml mfile msum got
  mkdir -p "$WORK/rec"
  log "RECORD MODE: PINS holds placeholders; fetching to print what they would pin, nothing is used"
  fetch "${PIN[aports_api]}/${PIN[aports_ref]}" "$WORK/rec/commit.json"
  commit=$(jq -r '.id // empty' "$WORK/rec/commit.json")
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { log "the ref ${PIN[aports_ref]} gave no commit id"; return 1; }
  observed aports_commit "$commit" "${PIN[aports_commit]}"
  for name in "${FILE_ORDER[@]}"; do
    f="$WORK/rec/$name"
    fetch "${PIN[aports_raw]}/$commit/${PIN[aports_dir]}/$name" "$f"
    observed "file.$name" "$(sha_of "$f")" "${FILES[$name]}"
  done
  yaml="$WORK/rec/latest-releases.yaml"
  fetch "${PIN[alpine_mirror]}/v${PIN[alpine_release]}/releases/x86_64/latest-releases.yaml" "$yaml"
  read -r mfile msum < <(yaml_minirootfs "$yaml")
  [[ "$mfile" =~ ${PIN_RE[minirootfs_file]} ]] || { log "latest-releases.yaml names no alpine-minirootfs file"; return 1; }
  observed minirootfs_file "$mfile" "${PIN[minirootfs_file]}"
  fetch "${PIN[alpine_mirror]}/v${PIN[alpine_release]}/releases/x86_64/$mfile" "$WORK/rec/$mfile"
  got=$(sha_of "$WORK/rec/$mfile")
  observed minirootfs_sha256 "$got" "${PIN[minirootfs_sha256]}"
  if [[ -n "$msum" && "$msum" != "$got" ]]; then
    log "the yaml's sha256 for $mfile ($msum) is not the file's ($got)"
  fi
  log "RECORD MODE done: compare these with Alpine's own listing and the aports commit, put them in PINS, commit, publish a new source"
  DETAIL="pins observed, not used: see the log"
  printf '%s\n' "$DETAIL" > "$STATE_DIR/$ID.detail"
  return 4
}

#--- the chroot ------------------------------------------------------------------------

fetch_inputs() {
  local rootfs name f sum
  run mkdir -p -- "$APK_DIR/dl" "$WORK/in"
  rootfs="$APK_DIR/dl/${PIN[minirootfs_file]}"
  if [[ ! -f "$rootfs" || "$(sha_of "$rootfs")" != "${PIN[minirootfs_sha256]}" ]]; then
    run rm -f -- "$rootfs"
    fetch "${PIN[alpine_mirror]}/v${PIN[alpine_release]}/releases/x86_64/${PIN[minirootfs_file]}" "$rootfs.part"
    sum=$(sha_of "$rootfs.part")
    if [[ "$sum" != "${PIN[minirootfs_sha256]}" ]]; then
      run rm -f -- "$rootfs.part"
      die "the minirootfs has sha256 $sum, not the pinned ${PIN[minirootfs_sha256]}"
    fi
    run mv -f -- "$rootfs.part" "$rootfs"
  fi
  for name in "${FILE_ORDER[@]}"; do
    f="$WORK/in/$name"
    fetch "${PIN[aports_raw]}/${PIN[aports_commit]}/${PIN[aports_dir]}/$name" "$f"
    sum=$(sha_of "$f")
    [[ "$sum" == "${FILES[$name]}" ]] || die "$name of aports ${PIN[aports_commit]} has sha256 $sum, not the pinned ${FILES[$name]}"
  done
  run install -m 0644 -- "$RDIR/${CONF[patch]}" "$WORK/in/${CONF[patch]}"
  printf 'pkgname=%s\naports_dir=%s\npatch=%s\n' "${CONF[pkgname]}" "${PIN[aports_dir]}" "${CONF[patch]}" > "$WORK/job.env"
}

ensure_chroot() {
  local rootfs="$APK_DIR/dl/${PIN[minirootfs_file]}"
  CH="$APK_DIR/chroot/${PIN[alpine_release]}-${PIN[minirootfs_sha256]:0:12}"
  if [[ ! -f "$CH/.hps-ready" ]]; then
    run rm -rf -- "$CH" "$CH.tmp"
    run mkdir -p -- "$CH.tmp"
    run tar -xzf "$rootfs" -C "$CH.tmp" --numeric-owner
    run touch "$CH.tmp/.hps-ready"
    run mv -T -- "$CH.tmp" "$CH"
  fi
}

# in_chroot <command...>: as root in the chroot, with the proxy and nothing else of the host's environment.
in_chroot() {
  run chroot "$CH" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    "https_proxy=$PROXY" "http_proxy=$PROXY" "HTTPS_PROXY=$PROXY" "HTTP_PROXY=$PROXY" "no_proxy=$NOPROXY" "NO_PROXY=$NOPROXY" "$@"
}

# as_builder <inner phase and arguments>: the same, as the unprivileged user.
as_builder() {
  local cmd="/usr/local/bin/hps-apk-inner $*"
  in_chroot /bin/su -s /bin/bash -c "$cmd" builder
}

mount_chroot() {
  local n
  [[ "$HPS_BUILDER_NO_NS" == 1 ]] && return 0
  run mount -t proc proc "$CH/proc"
  run mount -t tmpfs -o mode=0755,size=16m tmpfs "$CH/dev"
  for n in "null 1 3" "zero 1 5" "full 1 7" "random 1 8" "urandom 1 9" "tty 5 0"; do
    # shellcheck disable=SC2086  # name, major, minor
    set -- $n
    run mknod -m 0666 "$CH/dev/$1" c "$2" "$3"
  done
  run ln -sfn /proc/self/fd "$CH/dev/fd"
  # POSIX shared memory (python's semaphores, which meson and docutils may use)
  run mkdir -p -- "$CH/dev/shm"
  run mount -t tmpfs -o mode=1777,size=1g tmpfs "$CH/dev/shm"
}

stage_chroot() {
  run mkdir -p -- "$CH/proc" "$CH/dev" "$CH/etc/apk" "$CH/opt/hps" "$CH/usr/local/bin"
  [[ ! -r "$HPS_RESOLV" ]] || cat "$HPS_RESOLV" > "$CH/etc/resolv.conf"
  printf '%s/v%s/main\n%s/v%s/community\n' "${PIN[alpine_mirror]}" "${PIN[alpine_release]}" "${PIN[alpine_mirror]}" "${PIN[alpine_release]}" > "$CH/etc/apk/repositories"
  run rm -rf -- "$CH/opt/hps"
  run mkdir -p -- "$CH/opt/hps"
  run cp -r -- "$WORK/in" "$CH/opt/hps/in"
  run cp -- "$WORK/job.env" "$CH/opt/hps/job.env"
  run install -m 0755 -- "$HPS_APK_INNER" "$CH/usr/local/bin/hps-apk-inner"
}

#--- the set ----------------------------------------------------------------------------

# pkginfo <apk> <key>: the first value of a .PKGINFO key.
pkginfo() {
  tar -xzOf "$1" .PKGINFO 2> /dev/null | sed -n "s/^$2 = //p" | head -n 1
}

# apk_has_member <apk> <member>
apk_has_member() {
  # no grep -q: it would end early, tar would die of SIGPIPE and pipefail would say "not found"
  tar -tzf "$1" 2> /dev/null | grep -xF -- "$2" > /dev/null
}

# select_set: SEL_NAME[] SEL_FILE[] SEL_VER, from what abuild made.
select_set() {
  local f n part want
  local -A byname=()
  SEL_NAME=()
  SEL_FILE=()
  SEL_VER=""
  while IFS= read -r -d '' f; do
    n=$(pkginfo "$f" pkgname)
    [[ -n "$n" ]] && byname[$n]=$f
  done < <(find "$CH/home/builder/packages" -name '*.apk' -print0 | sort -z)
  for part in ${CONF[parts]}; do
    if [[ "$part" == main ]]; then want=${CONF[pkgname]}; else want="${CONF[pkgname]}-$part"; fi
    [[ -n "${byname[$want]:-}" ]] || die "the build made no package $want"
    f=${byname[$want]}
    n=$(pkginfo "$f" pkgver)
    [[ "$n" =~ ^[0-9][0-9A-Za-z._]*-r([0-9]+)$ ]] || die "$want has the version '$n'"
    [[ "${BASH_REMATCH[1]}" -ge "${CONF[min_pkgrel]}" ]] || die "$want is release ${BASH_REMATCH[1]}, below min_pkgrel ${CONF[min_pkgrel]}: the patch did not set pkgrel"
    [[ -z "$SEL_VER" || "$SEL_VER" == "$n" ]] || die "$want is $n but the set is $SEL_VER"
    SEL_VER=$n
    SEL_NAME+=("$want")
    SEL_FILE+=("$f")
  done
}

# verify_set <name>...: what the set must be. Names are in SEL_NAME order, files in SEL_FILE.
verify_set() {
  local i f n helper_in="" driver_in="" d dn dv found j
  for i in "${!SEL_FILE[@]}"; do
    f=${SEL_FILE[$i]}
    n=${SEL_NAME[$i]}
    if apk_has_member "$f" "${CONF[helper]}"; then helper_in="$helper_in $n"; fi
    if tar -xzOf "$f" --wildcards 'usr/lib/*' 2> /dev/null | grep -aF -- "${CONF[driver_string]}" > /dev/null; then
      driver_in="$driver_in $n"
    fi
    if tar -tzf "$f" 2> /dev/null | grep -E "^(\./)?${CONF[forbid_prefix]}(/|\$)" > /dev/null; then
      die "$n holds a file under ${CONF[forbid_prefix]}: the profile texts of the node bundle are the only ones (upstream's would shadow them)"
    fi
    while read -r d; do
      [[ -n "$d" ]] || continue
      [[ "$d" =~ ^(${CONF[pkgname]}[a-z0-9-]*)=(.+)$ ]] || continue
      dn=${BASH_REMATCH[1]}
      dv=${BASH_REMATCH[2]}
      found=0
      for j in "${!SEL_NAME[@]}"; do
        [[ "${SEL_NAME[$j]}" == "$dn" && "$dv" == "$SEL_VER" ]] && found=1
      done
      [[ $found -eq 1 ]] || die "$n depends on $dn=$dv, which is not in the set at $SEL_VER"
    done < <(tar -xzOf "$f" .PKGINFO 2> /dev/null | sed -n 's/^depend = //p')
  done
  [[ -n "$helper_in" ]] || die "no package of the set holds ${CONF[helper]}: the build has no AppArmor helper"
  [[ -n "$driver_in" ]] || die "no library of the set carries ${CONF[driver_string]}: the build has no AppArmor security driver"
  log "verified: ${CONF[helper]} in$helper_in; the AppArmor driver (${CONF[driver_string]}) in$driver_in"
}

publish_set() {
  local dest="$OUT_PKGS/$RECIPE" i f n sum meta_file
  local tsv="$WORK/set.tsv"
  : > "$tsv"
  run rm -rf -- "$dest.tmp"
  run mkdir -p -- "$dest.tmp/files"
  for i in "${!SEL_FILE[@]}"; do
    f=${SEL_FILE[$i]}
    n=${SEL_NAME[$i]}
    run install -m 0644 -- "$f" "$dest.tmp/files/${f##*/}"
    printf '%s\t%s\t%s\t%s\n' "$n" "$SEL_VER" "${f##*/}" "$(sha_of "$dest.tmp/files/${f##*/}")" >> "$tsv"
  done
  meta_file=$(find "$CH/home/builder/packages" -name "${CONF[meta]}-*.apk" -print -quit)
  [[ -n "$meta_file" ]] || die "the meta package ${CONF[meta]} was not built"
  [[ "$(pkginfo "$meta_file" pkgname)" == "${CONF[meta]}" && "$(pkginfo "$meta_file" pkgver)" == "$SEL_VER" ]] || die "the meta package is not ${CONF[meta]} $SEL_VER"
  run install -m 0644 -- "$meta_file" "$dest.tmp/files/${meta_file##*/}"
  sum=$(sha_of "$dest.tmp/files/${meta_file##*/}")
  printf '%s\t%s\t%s\t%s\n' "${CONF[meta]}" "$SEL_VER" "${meta_file##*/}" "$sum" >> "$tsv"
  jq -n --arg attr "$RECIPE" --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$SEL_VER" \
    --arg commit "${PIN[aports_commit]}" --arg release "${PIN[alpine_release]}" --arg rootfs "${PIN[minirootfs_sha256]}" \
    --slurpfile pk <(jq -R -n '[inputs | split("\t") | {name: .[0], version: .[1], file: .[2], sha256: .[3]}]' < "$tsv") \
    '{attr: $attr, kind: "apk", store_path: ("apk:" + $attr + "-" + $ver), version: $ver, built_at: $built_at,
      alpine_release: $release, minirootfs_sha256: $rootfs, aports_commit: $commit, packages: $pk[0]}' > "$dest.tmp/pkg.json"
  (cd "$dest.tmp" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
  run rm -rf -- "$dest.old"
  [[ ! -d "$dest" ]] || run mv -T -- "$dest" "$dest.old"
  run mv -T -- "$dest.tmp" "$dest"
  run rm -rf -- "$dest.old"
  DETAIL="recipe=$RECIPE version=$SEL_VER packages=$((${#SEL_FILE[@]} + 1)) aports=${PIN[aports_commit]:0:12}"
  # the detail crosses back to the outer process through the disk
  printf '%s\n' "$DETAIL" > "$STATE_DIR/$ID.detail"
  log "package set $RECIPE $SEL_VER published: $dest ($((${#SEL_FILE[@]} + 1)) apks)"
}

#--- the job ---------------------------------------------------------------------------

# inner: inside the private namespaces. The steps run under errexit in a subshell (main
# turns it off to read the status); the key is removed when they end, however they end.
inner() {
  ( set -e; inner_job )
}

inner_job() {
  local i
  local -a deps=()
  read_recipe
  set_egress
  CH="$APK_DIR/chroot/${PIN[alpine_release]}-${PIN[minirootfs_sha256]:0:12}"
  WORK="$MNT/tmp/$ID"
  # shellcheck disable=SC2064  # the path is fixed now
  trap "rm -rf -- '$CH/home/builder/.abuild'" EXIT
  mount_chroot
  stage_chroot
  in_chroot /sbin/apk add --no-progress --update-cache bash curl alpine-sdk
  in_chroot /usr/local/bin/hps-apk-inner prepare
  as_builder build
  select_set
  verify_set
  for i in "${!SEL_NAME[@]}"; do
    deps+=("${SEL_NAME[$i]}=$SEL_VER")
  done
  as_builder meta "${CONF[meta]}" "${SEL_VER%-r*}" "${SEL_VER##*-r}" "${deps[@]}"
  publish_set
}

outer() {
  local rc=0
  T0=$(date -u +%s)
  WORK="$MNT/tmp/$ID"
  run mkdir -p -- "$STATE_DIR" "$WORK" "$APK_DIR" "$OUT_PKGS"
  exec >> "$STATE_DIR/build-$ID.log" 2>&1
  log "job $ID: apk recipe $RECIPE src $SRC"
  record running
  set +e
  (
    set -e
    read_recipe
    set_egress
    if [[ $RECORDING -eq 1 ]]; then
      record_mode
    else
      fetch_inputs
      ensure_chroot
      if [[ "$HPS_BUILDER_NO_NS" == 1 ]]; then
        "$0" --inner "${ARGV[@]}"
      else
        run unshare --mount --pid --fork --ipc --uts --propagation private -- "$0" --inner "${ARGV[@]}"
      fi
    fi
  )
  rc=$?
  set -e
  [[ ! -f "$STATE_DIR/$ID.detail" ]] || DETAIL=$(cat "$STATE_DIR/$ID.detail")
  rm -f -- "$STATE_DIR/$ID.detail"
  run rm -rf -- "$WORK"
  if [[ $rc -eq 0 ]]; then
    record ok 0
    log "job $ID (apk $RECIPE) ok ($(($(date -u +%s) - T0)) s)"
  else
    record failed "$rc"
    log "job $ID (apk $RECIPE) FAILED: exit $rc ($(($(date -u +%s) - T0)) s)"
  fi
  return "$rc"
}

main() {
  ARGV=("$@")
  parse_args "$@"
  if [[ $INNER -eq 1 ]]; then
    local rc
    set +e
    inner
    rc=$?
    set -e
    return "$rc"
  fi
  outer
}

main "$@"
