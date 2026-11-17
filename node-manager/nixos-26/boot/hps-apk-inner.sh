#!/usr/bin/env bash
#
# hps-apk-inner - the part of an Alpine package build that runs INSIDE the chroot
# (docs/BUILDER.md "Local packages: the Alpine chroot"). It is part of the builder
# image, like the runner that copies it into the chroot and calls it (hps-apk-build);
# nothing in it comes from the source tree except the data files the runner stages
# under /opt/hps (the APKBUILD and the other files of Alpine's aports directory, the
# recipe's patch, job.env).
#
# Usage (as the runner calls it):
#   hps-apk-inner prepare                    as root: the build user, its tree, the makedepends
#   hps-apk-inner build                      as the build user: patch, key, abuild
#   hps-apk-inner meta NAME VER REL DEP...   as the build user: the meta package
#
# prepare   makes the unprivileged user `builder` (uid 1000, group abuild), clears its
#           build tree, puts the staged files in ~/aports/<aports_dir>, then reads the
#           makedepends from the APKBUILD (as the build user) and installs them with apk
#           as root, so that the network is used with the proxy the runner passed in
#           the environment and not through abuild's sudo helper. A dependency on the
#           package's own name (libvirt's depends_dev is one) is left out: it is what is
#           being built.
# build     applies the recipe's patch with no fuzz (a patch that does not fit the
#           pinned APKBUILD fails the build), makes a throwaway abuild key (abuild-keygen
#           -a -n; removed when the phase ends, success or not; it never leaves the
#           chroot), and runs abuild with dependency checking off (prepare did it):
#           fetch, check the source's sha512 from the APKBUILD, unpack, build, package.
# meta      builds the meta package NAME, version VER-rREL, whose depends are exactly
#           the DEP arguments (name=version-release), with the same kind of key.
#
# Overrides for tests: HPS_INNER_ROOT (prefix of every path here).

set -euo pipefail

R="${HPS_INNER_ROOT:-}"
JOB="$R/opt/hps/job.env"
IN="$R/opt/hps/in"
BHOME=/home/builder
PKGNAME=""
APORTS_DIR=""
PATCH_FILE=""

log() {
  printf '[hps-apk-inner] %s\n' "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

die() {
  log "FAILED: $*"
  exit 1
}

# read_job: key=value lines the runner validated; checked again here.
read_job() {
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      pkgname) PKGNAME=$v ;;
      aports_dir) APORTS_DIR=$v ;;
      patch) PATCH_FILE=$v ;;
      "") ;;
      *) die "job.env: unknown key '$k'" ;;
    esac
  done < "$JOB"
  [[ "$PKGNAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "job.env: pkgname '$PKGNAME'"
  [[ "$APORTS_DIR" =~ ^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$ ]] || die "job.env: aports_dir '$APORTS_DIR'"
  [[ "$PATCH_FILE" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "job.env: patch '$PATCH_FILE'"
}

phase_prepare() {
  local f cmd dep own
  local -a deps=()
  read_job
  own="^${PKGNAME}([=<>~].*)?\$"
  run addgroup -S abuild 2> /dev/null || true
  id builder > /dev/null 2>&1 || run adduser -D -u 1000 -s /bin/bash builder
  run addgroup builder abuild 2> /dev/null || true
  run rm -rf -- "$R$BHOME/aports" "$R$BHOME/packages" "$R$BHOME/meta" "$R$BHOME/.abuild"
  run install -d -o builder -g builder -m 0755 "$R$BHOME" "$R$BHOME/aports/$APORTS_DIR" "$R$BHOME/packages" "$R/var/cache/distfiles"
  run chown builder:abuild "$R/var/cache/distfiles"
  for f in "$IN"/*; do
    [[ -f "$f" && ! -L "$f" ]] || die "$f is not a plain file"
    run install -o builder -g builder -m 0644 "$f" "$R$BHOME/aports/$APORTS_DIR/"
  done
  # the makedepends of the APKBUILD, read by the build user (the file is sourced, as abuild does)
  cmd="cd $R$BHOME/aports/$APORTS_DIR && export CARCH=\$(apk --print-arch) && . ./APKBUILD && printf '%s\\n' \$makedepends"
  while read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ "$dep" =~ $own ]] && continue
    deps+=("$dep")
  done < <(su -s /bin/bash -c "$cmd" builder)
  [[ ${#deps[@]} -gt 0 ]] || die "the APKBUILD has no makedepends: it is not the one this recipe was written for"
  log "makedepends: ${deps[*]}"
  run apk add --no-progress --virtual ".makedepends-$PKGNAME" "${deps[@]}"
}

phase_build() {
  local dir
  read_job
  dir="$R$BHOME/aports/$APORTS_DIR"
  [[ -f "$dir/APKBUILD" ]] || die "no APKBUILD in $dir"
  cd "$dir"
  run patch -p1 -F0 --no-backup-if-mismatch -i "$PATCH_FILE"
  make_key
  # shellcheck disable=SC2064  # the path is fixed now
  trap "rm -rf -- '$R$BHOME/.abuild'" EXIT
  export SRCDEST=/var/cache/distfiles REPODEST="$BHOME/packages"
  run abuild -d
}

# make_key: a throwaway key for this phase, as abuild's own tool makes it.
make_key() {
  export PACKAGER="HPS builder <builder@hps.invalid>"
  export HOME="$BHOME"
  run rm -rf -- "$R$BHOME/.abuild"
  run abuild-keygen -a -n
}

phase_meta() {
  local name="$1" ver="$2" rel="$3" d dir
  shift 3
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ && "$ver" =~ ^[0-9][0-9A-Za-z._]*$ && "$rel" =~ ^[0-9]+$ ]] || die "meta: bad name or version"
  [[ $# -gt 0 ]] || die "meta: no dependency given"
  for d in "$@"; do
    [[ "$d" =~ ^[a-z][a-z0-9._+-]*=[0-9][0-9A-Za-z._-]*$ ]] || die "meta: '$d' is not name=version-release"
  done
  dir="$R$BHOME/meta"
  run rm -rf -- "$dir"
  run mkdir -p -- "$dir"
  {
    printf '%s\n' '# generated by hps-apk-inner: the libvirt set built with the AppArmor driver'
    printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n' "$name" "$ver" "$rel"
    printf '%s\n' 'pkgdesc="libvirt with the AppArmor security driver (HPS build)"' \
      'arch="noarch"' 'license="LGPL-2.1-or-later"' 'options="!check"' 'source=""' 'builddir="$srcdir"'
    printf 'depends="%s"\n' "$*"
    cat << 'EOF'

package() {
	install -d "$pkgdir"/usr/share/hps
	printf '%s\n' $depends > "$pkgdir"/usr/share/hps/libvirt-apparmor.set
}
EOF
  } > "$dir/APKBUILD"
  cd "$dir"
  make_key
  # shellcheck disable=SC2064  # the path is fixed now
  trap "rm -rf -- '$R$BHOME/.abuild'" EXIT
  export SRCDEST=/var/cache/distfiles REPODEST="$BHOME/packages"
  run abuild -d
}

main() {
  local phase="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$phase" in
    prepare) phase_prepare ;;
    build) phase_build ;;
    meta) phase_meta "$@" ;;
    *)
      echo "Usage: hps-apk-inner prepare | build | meta NAME VER REL DEP..." >&2
      exit 2
      ;;
  esac
}

main "$@"
