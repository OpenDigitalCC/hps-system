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
#   hps-apk-inner build                      as the build user: sources, key, abuild
#   hps-apk-inner meta NAME VER REL DEP...   as the build user: the meta package
#
# prepare   makes the unprivileged user `builder` (uid 1000, group abuild), clears its
#           build tree, puts the staged files in ~/aports/<aports_dir>, applies the
#           recipe's patch with no fuzz (a patch that does not fit the pinned APKBUILD
#           fails the job), then reads the makedepends from the PATCHED APKBUILD (as
#           the build user) and installs them with apk
#           as root, so that the network is used with the proxy the runner passed in
#           the environment and not through abuild's sudo helper. A dependency on the
#           package's own name (libvirt's depends_dev is one) is left out: it is what is
#           being built.
# build     fetches the https sources with curl (prefetch_sources) and runs abuild with
#           dependency checking off (prepare did it) and the key prepare made: check the
#           source's sha512 from the APKBUILD, unpack, build, package, index.
# meta      builds the meta package NAME, version VER-rREL, whose depends are exactly
#           the DEP arguments (name=version-release), with the same key.
#
# The key: prepare makes a throwaway abuild key (abuild-keygen -a -n) for the job and
# installs its public half in /etc/apk/keys, because abuild reads the packages back to
# make the index and refuses ones it does not trust. It never leaves the chroot, and the
# runner removes both halves when the job ends. HPS adds no signing layer: nodes install
# local packages with --allow-untrusted.
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
  run rm -f -- "$R"/etc/apk/keys/builder@hps.invalid-*.rsa.pub
  run install -d -o builder -g builder -m 0755 "$R$BHOME" "$R$BHOME/aports/$APORTS_DIR" "$R$BHOME/packages" "$R/var/cache/distfiles"
  run chown builder:abuild "$R/var/cache/distfiles"
  for f in "$IN"/*; do
    [[ -f "$f" && ! -L "$f" ]] || die "$f is not a plain file"
    run install -o builder -g builder -m 0644 "$f" "$R$BHOME/aports/$APORTS_DIR/"
  done
  # the recipe's patch first, with no fuzz (one that does not fit the pinned APKBUILD fails the job):
  # the makedepends below are those of the PATCHED file (libapparmor-dev is the patch's)
  run su -s /bin/bash -c "cd $R$BHOME/aports/$APORTS_DIR && patch -p1 -F0 --no-backup-if-mismatch -i $PATCH_FILE && rm -f $PATCH_FILE" builder
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
  # The job's throwaway key, made by the build user, its public half trusted by apk in the chroot:
  # abuild's index step reads the packages back and refuses ones it does not trust ("UNTRUSTED
  # signature"). The private half stays in builder's .abuild. The runner removes both when the job
  # ends, however it ends (and the next prepare does, should the job have been killed).
  run su -s /bin/bash -c "export HOME=$BHOME PACKAGER='HPS builder <builder@hps.invalid>'; abuild-keygen -a -n" builder
  run install -d -m 0755 "$R/etc/apk/keys"
  for f in "$R$BHOME"/.abuild/*.rsa.pub; do
    [[ -f "$f" ]] || die "abuild-keygen made no public key"
    run install -m 0644 "$f" "$R/etc/apk/keys/"
  done
}

phase_build() {
  local dir
  read_job
  dir="$R$BHOME/aports/$APORTS_DIR"
  [[ -f "$dir/APKBUILD" ]] || die "no APKBUILD in $dir"
  cd "$dir"
  prefetch_sources
  need_key
  export HOME="$BHOME" SRCDEST=/var/cache/distfiles REPODEST="$BHOME/packages"
  run abuild -d
}

# prefetch_sources: abuild fetches with busybox wget, which cannot use an HTTPS proxy (it sends
# GET and the proxy answers "405 Only CONNECT"). So the https sources the APKBUILD names are
# fetched here with curl, which does CONNECT, into the distfiles directory abuild looks in;
# abuild still checks each file against the sha512 the APKBUILD carries. Only plain https URLs;
# the other words of `source` are files of the aports directory.
prefetch_sources() {
  local w name url dist="$R/var/cache/distfiles"
  # shellcheck disable=SC2154  # `source` is the APKBUILD's variable, set by the sourcing below
  while read -r w; do
    case "$w" in
      "" | *[!A-Za-z0-9._+:/%~-]*) [[ -z "$w" ]] || die "source '$w' has characters a source name and URL do not"; continue ;;
      *://*) ;;
      *) continue ;;
    esac
    if [[ "$w" == *::* ]]; then
      name=${w%%::*}
      url=${w#*::}
    else
      url=$w
      name=${url##*/}
    fi
    [[ "$url" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/[A-Za-z0-9._%+~-]+)+$ && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
      die "source '$w' is not a plain https URL"
    if [[ -s "$dist/$name" ]]; then
      log "$name is in the distfiles already"
      continue
    fi
    run curl --fail --silent --show-error --location --proto =https --proto-redir =https --max-redirs 5 \
      --max-time 1800 --output "$dist/$name.part" "$url"
    run mv -f -- "$dist/$name.part" "$dist/$name"
  done < <(export CARCH; CARCH=$(apk --print-arch); . ./APKBUILD > /dev/null; printf '%s\n' $source)
}

# need_key: prepare made the job's key.
need_key() {
  [[ -d "$R$BHOME/.abuild" ]] || die "no abuild key: prepare makes it"
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
      'url="https://hps.invalid/"' 'arch="noarch"' 'license="LGPL-2.1-or-later"' 'options="!check"' 'source=""' 'builddir="$srcdir"'
    printf 'depends="%s"\n' "$*"
    cat << 'EOF'

package() {
	install -d "$pkgdir"/usr/share/hps
	printf '%s\n' $depends > "$pkgdir"/usr/share/hps/libvirt-apparmor.set
}
EOF
  } > "$dir/APKBUILD"
  cd "$dir"
  need_key
  export HOME="$BHOME" SRCDEST=/var/cache/distfiles REPODEST="$BHOME/packages"
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
