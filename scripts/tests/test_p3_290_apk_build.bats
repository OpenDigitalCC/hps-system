#!/usr/bin/env bats
#
# The Alpine package build on the builder (docs/BUILDER.md "Local packages: the Alpine
# chroot"): builder-apk-build (the allowlisted action: a source sha256 and a recipe name,
# nothing else), hps-apk-build (the root job: pins checked, chroot, set verified,
# published) and hps-apk-inner (the part inside the chroot). chroot, apk, abuild and the
# mounts are stubs; the real recipe's files are parsed by the real runner.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers
load p3_202_helpers

ROOT="${BATS_TEST_DIRNAME}/../.."
RECIPE_DIR="$ROOT/alpine/recipes/libvirt-apparmor"
ID=20261117T070000Z

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-290.XXXXXX")"
  export TEST_DIR
  p3_202_setup
  p3_202_prepared
  export HPS_BUILDER_NO_NS=1
  export HPS_APK_INNER="$TEST_DIR/fake-inner"
  export HPS_RESOLV="$TEST_DIR/resolv.conf"
  printf '#!/usr/bin/env bash\necho inner\n' > "$HPS_APK_INNER"
  echo "nameserver 10.99.1.9" > "$HPS_RESOLV"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=http://10.99.1.2:3128 hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  fake_libs
  make_src
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- fixtures -----------------------------------------------------------------------------

# fake_libs: the https curl, the chroot and the helper that makes apk files.
fake_libs() {
  cat > "$TEST_DIR/fakeapk.sh" <<'LIB'
# fake_apk <file> <name> <ver> "<depends>" [member=content ...]: a one-stream apk-shaped tar.gz
fake_apk() {
  local f=$1 name=$2 ver=$3 deps=$4 d m x
  shift 4
  d=$(mktemp -d)
  { echo "pkgname = $name"; echo "pkgver = $ver"; for x in $deps; do echo "depend = $x"; done; } > "$d/.PKGINFO"
  for m in "$@"; do
    mkdir -p "$d/$(dirname "${m%%=*}")"
    printf '%s' "${m#*=}" > "$d/${m%%=*}"
  done
  (cd "$d" && find . -mindepth 1 | sed 's|^\./||' | sort) > "$d.list"
  tar -czf "$f" -C "$d" --no-recursion -T "$d.list"
  rm -rf "$d" "$d.list"
}
LIB
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
echo "curl-env https_proxy=${https_proxy:-} no_proxy=${no_proxy:-}" >> "$SHIM_LOG"
out="" url="${@: -1}"
while [[ $# -gt 0 ]]; do
  case "$1" in --output) out=$2; shift ;; esac
  shift
done
case "$url" in
  https://*) src="$STATE/www/${url#https://}" ;;
  http://*) src="$STATE/www/${url#http://*/}" ;; # the IPS (builder-apk-build)
  *) exit 22 ;;
esac
[[ -f "$src" ]] || exit 22
cp "$src" "$out"
SHIM
  cat > "$TEST_DIR/bin/chroot" <<'SHIM'
#!/usr/bin/env bash
echo "chroot $*" >> "$SHIM_LOG"
ch=$1
shift
cmd="$*"
. "$TEST_DIR/fakeapk.sh"
sc=" $(cat "$STATE/scenario" 2> /dev/null) "
[[ "$sc" == *" fail-${FAKE_FAIL:-none} "* ]] && exit 7
V=12.3.0-r100
[[ "$sc" == *" lowrel "* ]] && V=12.3.0-r0
P="$ch/home/builder/packages/community/x86_64"
case "$cmd" in
  *"hps-apk-inner build"*)
    mkdir -p "$P"
    h="usr/lib/libvirt/virt-aa-helper=#!helper"
    [[ "$sc" == *" nohelper "* ]] && h="usr/bin/other=x"
    lib="usr/lib/libvirt.so.12.3.0=ELF....../usr/lib/libvirt/virt-aa-helper......"
    [[ "$sc" == *" nodriver "* ]] && lib="usr/lib/libvirt.so.12.3.0=ELF...virCommandSetAppArmorProfile..."
    extra=()
    if [[ "$sc" == *" big "* ]]; then for i in $(seq 1 3000); do extra+=("usr/share/doc/libvirt/a-fairly-long-directory-name-to-fill-the-listing-quickly/another-long-component-for-the-same-purpose/f$i=x"); done; fi
    [[ "$sc" == *" forbid "* ]] && extra=("etc/apparmor.d/usr.sbin.libvirtd=profile")
    od="libvirt-daemon=$V openrc"
    [[ "$sc" == *" baddep "* ]] && od="libvirt-daemon=12.3.0-r5 openrc"
    fake_apk "$P/libvirt-$V.apk" libvirt "$V" "so:libc.musl-x86_64.so.1"
    fake_apk "$P/libvirt-client-$V.apk" libvirt-client "$V" "libvirt=$V gnutls-utils"
    fake_apk "$P/libvirt-daemon-$V.apk" libvirt-daemon "$V" "libvirt-client=$V bridge-utils" "$h" "${extra[@]}"
    fake_apk "$P/libvirt-daemon-openrc-$V.apk" libvirt-daemon-openrc "$V" "$od" "etc/init.d/libvirtd=#!/sbin/openrc-run"
    fake_apk "$P/libvirt-libs-$V.apk" libvirt-libs "$V" "" "$lib"
    fake_apk "$P/libvirt-common-drivers-$V.apk" libvirt-common-drivers "$V" ""
    [[ "$sc" == *" nopart "* ]] || fake_apk "$P/libvirt-qemu-$V.apk" libvirt-qemu "$V" "libvirt-daemon=$V libvirt-common-drivers=$V"
    fake_apk "$P/libvirt-dev-$V.apk" libvirt-dev "$V" "libvirt=$V" "usr/include/libvirt/libvirt.h=x"
    fake_apk "$P/libvirt-doc-$V.apk" libvirt-doc "$V" ""
    mkdir -p "$ch/home/builder/.abuild"
    echo key > "$ch/home/builder/.abuild/builder-1.rsa"
    ;;
  *"hps-apk-inner meta "*)
    args=${cmd#*hps-apk-inner meta }
    args=${args% builder}
    set -- $args
    name=$1 ver=$2 rel=$3
    shift 3
    mkdir -p "$P"
    fake_apk "$P/$name-$ver-r$rel.apk" "$name" "$ver-r$rel" "$*" "usr/share/hps/libvirt-apparmor.set=$*"
    echo "meta-deps $*" >> "$SHIM_LOG"
    ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/curl" "$TEST_DIR/bin/chroot"
}

# make_src [placeholder]: a source tree holding the shipped recipe's recipe.conf and
# patch, and a PINS file whose values match the fixtures served on https://*.test. With
# an argument the values named in it are RECORD-ME.
make_src() {
  local rec="$TEST_DIR/srctree/alpine/recipes/libvirt-apparmor" mir=mirror.test/alpine aports=aports.test/-/raw
  local rootfs rsum name sum
  mkdir -p "$rec" "$TEST_DIR/srctree/nix" "$TEST_DIR/rootfs/etc/apk" "$TEST_DIR/rootfs/proc" "$TEST_DIR/rootfs/dev" "$TEST_DIR/rootfs/home"
  echo '{ }' > "$TEST_DIR/srctree/flake.nix"
  cp "$RECIPE_DIR/recipe.conf" "$RECIPE_DIR/APKBUILD.patch" "$rec/"
  COMMIT=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$STATE/www/$mir/v3.24/releases/x86_64" "$STATE/www/$aports/$COMMIT/community/libvirt" "$STATE/www/aports.test/api/commits"
  rootfs="$STATE/www/$mir/v3.24/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz"
  tar -czf "$rootfs" -C "$TEST_DIR/rootfs" .
  ROOTFS_SUM=$(p3_171_sha "$rootfs")
  {
    printf '%s\n' '# test pins' 'alpine_mirror=https://mirror.test/alpine' 'alpine_release=3.24'
    echo "minirootfs_file=alpine-minirootfs-3.24.1-x86_64.tar.gz"
    echo "minirootfs_sha256=$ROOTFS_SUM"
    printf '%s\n' 'aports_raw=https://aports.test/-/raw' 'aports_api=https://aports.test/api/commits' 'aports_ref=3.24-stable'
    echo "aports_commit=$COMMIT"
    echo "aports_dir=community/libvirt"
    for name in APKBUILD libvirt.confd libvirt.initd libvirt-guests.confd libvirt-guests.initd virtlogd.initd virtlockd.initd libvirt.post-install; do
      printf 'content of %s\n' "$name" > "$STATE/www/$aports/$COMMIT/community/libvirt/$name"
      sum=$(p3_171_sha "$STATE/www/$aports/$COMMIT/community/libvirt/$name")
      echo "file $name $sum"
    done
  } > "$rec/PINS"
  printf '{"id":"%s"}\n' "$COMMIT" > "$STATE/www/aports.test/api/commits/3.24-stable"
  printf -- '---\n-\n  title: "Mini root filesystem"\n  branch: v3.24\n  version: 3.24.1\n  flavor: alpine-minirootfs\n  iso: alpine-minirootfs-3.24.1-x86_64.tar.gz\n  sha256: %s\n' "$ROOTFS_SUM" > "$STATE/www/$mir/v3.24/releases/x86_64/latest-releases.yaml"
  CH="$MNT/apk/chroot/3.24-${ROOTFS_SUM:0:12}"
  OUTP="$MNT/out/pkgs/libvirt-apparmor"
}

# job: the runner's own messages go to the build log, so $output holds both
job() {
  run bash "$B/hps-apk-build.sh" --id "$ID" --src "$TEST_DIR/srctree" --recipe libvirt-apparmor
  output="$output"$'\n'"$(cat "$MNT/state/build-$ID.log" 2> /dev/null || true)"
}

scenario() {
  echo "$*" > "$STATE/scenario"
}

pins() { echo "$TEST_DIR/srctree/alpine/recipes/libvirt-apparmor/PINS"; }

# --- the runner: a good run --------------------------------------------------------------

@test "run: pins checked, chroot made from the verified minirootfs, phases in order, set verified, published in the layout pkg-fetch takes" {
  job
  [ "$status" -eq 0 ]
  jq -e '.mode == "apk" and .state == "ok" and .rc == 0 and .profiles == "apk:libvirt-apparmor" and (.detail | test("version=12.3.0-r100 packages=8"))' "$MNT/state/last.json"
  cmp "$MNT/state/last.json" "$MNT/state/$ID.json"
  [ -f "$CH/.hps-ready" ]
  [ "$(cat "$CH/etc/apk/repositories")" = $'https://mirror.test/alpine/v3.24/main\nhttps://mirror.test/alpine/v3.24/community' ]
  [ "$(cat "$CH/etc/resolv.conf")" = "nameserver 10.99.1.9" ]
  [ -x "$CH/usr/local/bin/hps-apk-inner" ]
  [ "$(cat "$CH/opt/hps/job.env")" = $'pkgname=libvirt\naports_dir=community/libvirt\npatch=APKBUILD.patch' ]
  [ -f "$CH/opt/hps/in/APKBUILD" ] && [ -f "$CH/opt/hps/in/libvirt.post-install" ] && cmp "$CH/opt/hps/in/APKBUILD.patch" "$RECIPE_DIR/APKBUILD.patch"
  # order: the sdk from Alpine's signed repository, prepare (root), build and meta (builder)
  n() { grep -n "$1" "$SHIM_LOG" | head -1 | cut -d: -f1; }
  [ "$(n 'chroot .* /sbin/apk add --no-progress --update-cache bash curl alpine-sdk')" -lt "$(n 'hps-apk-inner prepare')" ]
  [ "$(n 'hps-apk-inner prepare')" -lt "$(n 'hps-apk-inner build')" ]
  [ "$(n 'hps-apk-inner build')" -lt "$(n 'hps-apk-inner meta ')" ]
  # the builder phases run as the user `builder`; apk is never given a way to skip signatures
  grep -q 'chroot .* /bin/su -s /bin/bash -c /usr/local/bin/hps-apk-inner build builder' "$SHIM_LOG"
  run ! grep -q 'allow-untrusted' "$SHIM_LOG"
  # the environment of the chroot is cleared apart from the proxy
  grep -q 'chroot .* /usr/bin/env -i PATH=.* HOME=/root https_proxy=http://10.99.1.2:3128 http_proxy=http://10.99.1.2:3128 .* no_proxy=10.99.1.1,localhost,127.0.0.1 ' "$SHIM_LOG"
  # every fetch is https, through the proxy, by the pinned commit
  grep '^curl ' "$SHIM_LOG" | grep -v -- '--proto =https --proto-redir =https' && return 1
  grep -q "^curl-env https_proxy=http://10.99.1.2:3128 no_proxy=10.99.1.1," "$SHIM_LOG"
  grep -q "https://aports.test/-/raw/$COMMIT/community/libvirt/APKBUILD$" "$SHIM_LOG"
  run ! grep -q 'api/commits' "$SHIM_LOG"
  # the published layout
  [ "$(ls "$OUTP/files" | wc -l)" -eq 8 ]
  [ -f "$OUTP/files/libvirt-apparmor-12.3.0-r100.apk" ] && [ -f "$OUTP/files/libvirt-daemon-12.3.0-r100.apk" ]
  [ ! -e "$OUTP/files/libvirt-dev-12.3.0-r100.apk" ] && [ ! -e "$OUTP/files/libvirt-doc-12.3.0-r100.apk" ]
  (cd "$OUTP" && sha256sum -c --quiet SHA256SUMS)
  [ "$(grep -c 'files/' "$OUTP/SHA256SUMS")" -eq 8 ]
  jq -e --arg c "$COMMIT" '.attr == "libvirt-apparmor" and .kind == "apk" and .store_path == "apk:libvirt-apparmor-12.3.0-r100" and .aports_commit == $c and (.packages | length) == 8 and ([.packages[].version] | unique == ["12.3.0-r100"])' "$OUTP/pkg.json"
  [ "$(find "$OUTP" -type f | wc -l)" -eq 10 ]
}

@test "run: the helper is found in a package with a long listing (grep -q would end early and pipefail would report it missing)" {
  scenario big
  job
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified: usr/lib/libvirt/virt-aa-helper in libvirt-daemon;"* ]]
}

@test "run: the meta package depends on exactly the built subpackages at their built version-release, none written down" {
  job
  [ "$status" -eq 0 ]
  grep -qxF 'meta-deps libvirt=12.3.0-r100 libvirt-client=12.3.0-r100 libvirt-daemon=12.3.0-r100 libvirt-daemon-openrc=12.3.0-r100 libvirt-libs=12.3.0-r100 libvirt-qemu=12.3.0-r100 libvirt-common-drivers=12.3.0-r100' "$SHIM_LOG"
  grep -q 'hps-apk-inner meta libvirt-apparmor 12.3.0 100 ' "$SHIM_LOG"
  # nothing of the recipe's tree or the runner names a version-release
  run ! grep -rE '12\.3\.0|-r100' "$ROOT/node-manager/nixos-26/boot/hps-apk-build.sh" "$ROOT/node-manager/nixos-26/boot/hps-apk-inner.sh"
  # a different built version is followed, not corrected
  rm -rf "$MNT" && mkdir -p "$MNT/state" "$MNT/out" "$MNT/tmp"
  p3_202_prepared
  scenario baddep
  job
  [ "$status" -eq 1 ]
}

@test "run: the abuild key is throwaway: it is gone afterwards and nothing of it is published" {
  job
  [ "$status" -eq 0 ]
  [ ! -e "$CH/home/builder/.abuild" ]
  [ -z "$(find "$OUTP" -name '*.rsa*' -o -name '.abuild')" ]
  run ! grep -rl 'key' "$OUTP/files"
  # a failed build leaves none either
  scenario fail-build
  FAKE_FAIL=build job
  [ "$status" -ne 0 ]
  [ ! -e "$CH/home/builder/.abuild" ]
}

@test "run: the chroot is kept, not made again" {
  job
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  echo marker > "$CH/keep"
  job
  [ "$status" -eq 0 ]
  [ -f "$CH/keep" ]
  [ "$(grep -c '^curl .*minirootfs' "$SHIM_LOG")" -eq 0 ]
}

@test "run: in the namespaces: a private mount, PID, IPC and UTS namespace, a tmpfs /dev of six nodes, the PID namespace's /proc" {
  export HPS_BUILDER_NO_NS=0
  cat > "$TEST_DIR/bin/unshare" <<'SHIM'
#!/usr/bin/env bash
echo "unshare $*" >> "$SHIM_LOG"
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
SHIM
  for c in mount mknod; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\n' "$c" > "$TEST_DIR/bin/$c"
  done
  chmod +x "$TEST_DIR/bin/unshare" "$TEST_DIR/bin/mount" "$TEST_DIR/bin/mknod"
  job
  [ "$status" -eq 0 ]
  grep -q '^unshare --mount --pid --fork --ipc --uts --propagation private -- ' "$SHIM_LOG"
  grep -q "^mount -t proc proc $CH/proc$" "$SHIM_LOG"
  grep -q "^mount -t tmpfs -o mode=0755,size=16m tmpfs $CH/dev$" "$SHIM_LOG"
  [ "$(grep -c '^mknod -m 0666 ' "$SHIM_LOG")" -eq 6 ]
  grep -q "^mount -t tmpfs -o mode=1777,size=1g tmpfs $CH/dev/shm$" "$SHIM_LOG"
  # no bind of the host's /dev, /sys or anything else into the chroot
  run ! grep -qE '^mount .*(--bind|--rbind| bind)' "$SHIM_LOG"
}

# --- the runner: what makes it refuse or fail --------------------------------------------

@test "run: a file of the aports commit that does not have its pinned sha256 fails the job before the chroot is used" {
  echo 'tampered' > "$STATE/www/aports.test/-/raw/$COMMIT/community/libvirt/APKBUILD"
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"APKBUILD of aports $COMMIT has sha256"* ]]
  run ! grep -q '^chroot ' "$SHIM_LOG"
  [ ! -e "$OUTP" ]
  jq -e '.state == "failed" and .rc == 1' "$MNT/state/last.json"
}

@test "run: a minirootfs that does not have its pinned sha256 is refused and removed; nothing is unpacked" {
  echo tamper >> "$STATE/www/mirror.test/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz"
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"the minirootfs has sha256"* ]]
  [ ! -e "$CH" ]
  [ ! -e "$MNT/apk/dl/alpine-minirootfs-3.24.1-x86_64.tar.gz" ]
}

@test "run: no hps.proxy= on the kernel line: refused (3) before any fetch; the builder has no other way out" {
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1" > "$HPS_CMDLINE"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps.proxy="* ]]
  run ! grep -q '^curl ' "$SHIM_LOG"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.proxy=https://10.99.1.2:3128" > "$HPS_CMDLINE"
  job
  [ "$status" -eq 3 ]
}

@test "run: the shipped recipe parses (with the real recipe.conf and PINS): the run reaches the proxy check" {
  rm -rf "$TEST_DIR/srctree/alpine/recipes"
  mkdir -p "$TEST_DIR/srctree/alpine/recipes"
  cp -r "$RECIPE_DIR" "$TEST_DIR/srctree/alpine/recipes/libvirt-apparmor"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1" > "$HPS_CMDLINE"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps.proxy="* ]]
}

@test "run: the recipe is data read strictly: an unknown key, a value of the wrong shape, a second line for a key's file, a link, a meta that is not the recipe's name" {
  local pins want
  pins=$(pins)
  cp "$pins" "$TEST_DIR/PINS.good"
  echo 'run_this=1' >> "$pins"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown key 'run_this'"* ]]
  cp "$TEST_DIR/PINS.good" "$pins"
  sed -i 's|^alpine_mirror=.*|alpine_mirror=http://mirror.test/alpine|' "$pins"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"alpine_mirror"*"does not fit its pattern"* ]]
  cp "$TEST_DIR/PINS.good" "$pins"
  sed -i 's|^aports_commit=.*|aports_commit=3.24-stable|' "$pins"
  job
  [ "$status" -eq 3 ]
  cp "$TEST_DIR/PINS.good" "$pins"
  grep '^file APKBUILD' "$pins" > "$TEST_DIR/dup" && cat "$TEST_DIR/dup" >> "$pins"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"names APKBUILD twice"* ]]
  cp "$TEST_DIR/PINS.good" "$pins"
  sed -i 's|^file libvirt.confd .*|file libvirt.confd 12345|' "$pins"
  job
  [ "$status" -eq 3 ]
  cp "$TEST_DIR/PINS.good" "$pins"
  echo 'a command; reboot' >> "$pins"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot read the line"* ]]
  cp "$TEST_DIR/PINS.good" "$pins"
  mv "$pins" "$TEST_DIR/PINS.real"
  ln -s "$TEST_DIR/PINS.real" "$pins"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"no plain file PINS"* ]]
  rm -f "$pins"
  cp "$TEST_DIR/PINS.good" "$pins"
  want="$TEST_DIR/srctree/alpine/recipes/libvirt-apparmor/recipe.conf"
  sed -i 's|^meta=.*|meta=other|' "$want"
  job
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not the recipe name"* ]]
  run ! grep -q '^chroot \|^curl ' "$SHIM_LOG"
}

@test "run: a bad id, a bad recipe name or a missing source is usage (2)" {
  run bash "$B/hps-apk-build.sh" --id x --src "$TEST_DIR/srctree" --recipe libvirt-apparmor
  [ "$status" -eq 2 ]
  run bash "$B/hps-apk-build.sh" --id "$ID" --src "$TEST_DIR/srctree" --recipe '../x'
  [ "$status" -eq 2 ]
  run bash "$B/hps-apk-build.sh" --id "$ID" --src "$TEST_DIR/none" --recipe libvirt-apparmor
  [ "$status" -eq 2 ]
  run bash "$B/hps-apk-build.sh" --id "$ID" --src "$TEST_DIR/srctree" --recipe libvirt-apparmor --free-form x
  [ "$status" -eq 2 ]
}

# --- record mode ----------------------------------------------------------------------------

@test "record mode: a RECORD-ME in PINS fetches what the pins name, prints every value, uses none of it and fails (4)" {
  local pins
  pins=$(pins)
  sed -i -e 's|^minirootfs_file=.*|minirootfs_file=RECORD-ME|' -e 's|^minirootfs_sha256=.*|minirootfs_sha256=RECORD-ME|' -e 's|^aports_commit=.*|aports_commit=RECORD-ME|' \
    -e 's|^file libvirt.confd .*|file libvirt.confd RECORD-ME|' "$pins"
  job
  [ "$status" -eq 4 ]
  [[ "$output" == *"RECORD MODE"* ]]
  grep -q "^PIN-OBSERVED aports_commit=$COMMIT new" "$MNT/state/build-$ID.log"
  grep -q "^PIN-OBSERVED file.APKBUILD=$(p3_171_sha "$STATE/www/aports.test/-/raw/$COMMIT/community/libvirt/APKBUILD") matches-pin" "$MNT/state/build-$ID.log"
  grep -q "^PIN-OBSERVED file.libvirt.confd=$(p3_171_sha "$STATE/www/aports.test/-/raw/$COMMIT/community/libvirt/libvirt.confd") new" "$MNT/state/build-$ID.log"
  grep -q '^PIN-OBSERVED minirootfs_file=alpine-minirootfs-3.24.1-x86_64.tar.gz new' "$MNT/state/build-$ID.log"
  grep -q "^PIN-OBSERVED minirootfs_sha256=$ROOTFS_SUM new" "$MNT/state/build-$ID.log"
  jq -e '.state == "failed" and .rc == 4' "$MNT/state/last.json"
  run ! grep -q '^chroot ' "$SHIM_LOG"
  [ ! -e "$CH" ] && [ ! -e "$OUTP" ]
}

@test "record mode: a pinned value that differs from what is observed says so" {
  local pins
  pins=$(pins)
  sed -i -e 's|^aports_commit=.*|aports_commit=RECORD-ME|' -e "s|^file APKBUILD .*|file APKBUILD $(printf '0%.0s' {1..64})|" "$pins"
  job
  [ "$status" -eq 4 ]
  grep -q "^PIN-OBSERVED file.APKBUILD=.* DIFFERS-from-pin(" "$MNT/state/build-$ID.log"
}

@test "the shipped PINS: one file, every external value in it, placeholders marked RECORD-ME, the hosts a proxy must allow" {
  local p="$RECIPE_DIR/PINS"
  grep -q '^aports_commit=' "$p"
  grep -q '^minirootfs_sha256=' "$p"
  [ "$(grep -c '^file ' "$p")" -ge 7 ]
  # the one place URLs of other hosts are written
  run ! grep -E 'https?://' "$RECIPE_DIR/recipe.conf"
  grep -q 'https://dl-cdn.alpinelinux.org/alpine' "$p"
  grep -q 'https://gitlab.alpinelinux.org/alpine/aports/-/raw' "$p"
  # the one other host is the libvirt tarball's, in the patch's source line (the sha512 is the APKBUILD's)
  [ "$(grep -E '^\+.*https?://' "$RECIPE_DIR/APKBUILD.patch" | grep -vc 'https://download.libvirt.org/libvirt-\$pkgver.tar.xz')" -eq 0 ]
}

# --- the set is checked ----------------------------------------------------------------------

@test "verify: a set without the helper fails, naming it; nothing is published and an older output is kept" {
  mkdir -p "$OUTP/files"
  echo old > "$OUTP/files/old.apk"
  scenario nohelper
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"no package of the set holds usr/lib/libvirt/virt-aa-helper"* ]]
  [ -f "$OUTP/files/old.apk" ]
  run ! grep -q 'hps-apk-inner meta' "$SHIM_LOG"
}

@test "verify: a set whose libraries do not carry the AppArmor driver (the stock build) fails" {
  scenario nodriver
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"carries /usr/lib/libvirt/virt-aa-helper: the build has no AppArmor security driver"* ]]
  [ ! -e "$OUTP" ]
}

@test "verify: upstream's profile texts in the set (a build with apparmor_profiles on) fail it: one source for the texts" {
  scenario forbid
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds a file under etc/apparmor.d"* ]]
}

@test "verify: a release below the recipe's minimum (the patch did not set pkgrel) fails" {
  scenario lowrel
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"below min_pkgrel 100"* ]]
}

@test "verify: a package of the split that is missing, or a dependency on the package's own name outside the set, fails" {
  scenario nopart
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"the build made no package libvirt-qemu"* ]]
  scenario baddep
  job
  [ "$status" -eq 1 ]
  [[ "$output" == *"libvirt-daemon-openrc depends on libvirt-daemon=12.3.0-r5, which is not in the set"* ]]
}

@test "run: a failing build phase is recorded failed with the exit status and publishes nothing" {
  scenario fail-meta
  FAKE_FAIL=meta job
  [ "$status" -eq 1 ] || [ "$status" -eq 7 ]
  jq -e '.state == "failed"' "$MNT/state/last.json"
  [ ! -e "$OUTP" ]
}

# --- builder-apk-build: the action ----------------------------------------------------------

a_source() {
  SUM=$(p3_202_source "$TEST_DIR/srctree")
}

a_runner() {
  export HPS_APK_RUN="$TEST_DIR/bin/fake-apk-run"
  printf '#!/usr/bin/env bash\necho "fake-apk-run $*" >> "$SHIM_LOG"\n' > "$HPS_APK_RUN"
  chmod +x "$HPS_APK_RUN"
}

@test "action: fetches the source from the IPS, checks it, finds the recipe among the source's directories and starts the unit with the recipe name only" {
  a_source
  a_runner
  run bash "$S/builder-apk-build" "$SUM" libvirt-apparmor
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" =~ ^BUILDER-APK-BUILD\ started\ id=[0-9]{8}T[0-9]{6}Z\ source=${SUM:0:16}\ recipe=libvirt-apparmor\ unit=hps-builder-build\ log=$MNT/state/build-[0-9T]+Z\.log$ ]]
  grep -qE "^curl .*--noproxy \* .*--proto =http .*http://10\.99\.1\.1/packages/cnh/hps-system-${SUM:0:16}\.tar\.gz$" "$SHIM_LOG"
  grep -qE "^systemd-run --quiet --collect --unit hps-builder-build --description HPS Alpine package build [0-9T]+Z --setenv PATH=.* -- $HPS_APK_RUN --id [0-9T]+Z --src $MNT/src/${SUM:0:16} --recipe libvirt-apparmor$" "$SHIM_LOG"
  # nothing else is passed: no source path, URL or option from the caller
  [ "$(grep '^systemd-run' "$SHIM_LOG" | grep -oE -- ' --[a-z]+' | sort | tr -d '\n')" = " --collect --description --id --quiet --recipe --setenv --src --unit" ]
}

@test "action: a recipe the source does not hold, a link, a directory without its files, or a name of another shape is refused; nothing is started" {
  mkdir -p "$TEST_DIR/srctree/alpine/recipes/empty" "$TEST_DIR/srctree/alpine/recipes/linked"
  ln -s ../libvirt-apparmor/PINS "$TEST_DIR/srctree/alpine/recipes/linked/PINS"
  ln -s ../libvirt-apparmor/recipe.conf "$TEST_DIR/srctree/alpine/recipes/linked/recipe.conf"
  ln -s libvirt-apparmor "$TEST_DIR/srctree/alpine/recipes/alias"
  a_source
  a_runner
  local r
  for r in nothing empty linked alias; do
    run bash "$S/builder-apk-build" "$SUM" "$r"
    [ "$status" -eq 3 ]
  done
  for r in '../libvirt-apparmor' 'Libvirt' 'libvirt apparmor' '/etc' 'a;b' '1x' "$(printf 'a%.0s' {1..41})" '' ; do
    run bash "$S/builder-apk-build" "$SUM" "$r"
    [ "$status" -eq 3 ] || [ "$status" -eq 2 ]
  done
  run ! grep -q '^systemd-run' "$SHIM_LOG"
}

@test "action: usage and refusals: arguments other than a source and a recipe, a bad sha256, a tarball that does not match, a running job, no disk, no IPS address" {
  a_source
  a_runner
  run bash "$S/builder-apk-build"
  [ "$status" -eq 2 ]
  run bash "$S/builder-apk-build" "$SUM"
  [ "$status" -eq 2 ]
  run bash "$S/builder-apk-build" "$SUM" libvirt-apparmor extra
  [ "$status" -eq 2 ]
  run bash "$S/builder-apk-build" "$SUM" --recipe
  [ "$status" -eq 2 ]
  run bash "$S/builder-apk-build" --src libvirt-apparmor
  [ "$status" -eq 2 ]
  run bash "$S/builder-apk-build" "${SUM:0:63}" libvirt-apparmor
  [ "$status" -eq 3 ]
  other=$(printf 'f%.0s' {1..64})
  cp "$STATE/www/packages/cnh/hps-system-${SUM:0:16}.tar.gz" "$STATE/www/packages/cnh/hps-system-${other:0:16}.tar.gz"
  run bash "$S/builder-apk-build" "$other" libvirt-apparmor
  [ "$status" -eq 3 ]
  [[ "$output" == *"has sha256 $SUM, not $other"* ]]
  [ ! -e "$MNT/src/${other:0:16}" ]
  echo active > "$STATE/unit-state"
  run bash "$S/builder-apk-build" "$SUM" libvirt-apparmor
  [ "$status" -eq 3 ]
  [[ "$output" == *"a job is running"* ]]
  rm -f "$STATE/unit-state"
  echo "BOOT_IMAGE=bzImage hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  run bash "$S/builder-apk-build" "$SUM" libvirt-apparmor
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps.ips="* ]]
  rm -f "$STATE/mounts"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1" > "$HPS_CMDLINE"
  run bash "$S/builder-apk-build" "$SUM" libvirt-apparmor
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not mounted"* ]]
  run ! grep -q '^systemd-run' "$SHIM_LOG"
}

# --- hps-apk-inner ---------------------------------------------------------------------------

inner_setup() {
  export HPS_INNER_ROOT="$TEST_DIR/iroot"
  IN="$HPS_INNER_ROOT/opt/hps"
  mkdir -p "$IN/in" "$HPS_INNER_ROOT/home/builder" "$HPS_INNER_ROOT/var/cache"
  printf 'pkgname=libvirt\naports_dir=community/libvirt\npatch=APKBUILD.patch\n' > "$IN/job.env"
  cat > "$IN/in/APKBUILD" <<'EOF'
pkgname=libvirt
pkgver=1
pkgrel=0
_daemon_deps="
	bridge-utils
	iproute2-tc
	"
depends_dev="$pkgname=$pkgver-r$pkgrel"
makedepends="
	$_daemon_deps
	$depends_dev
	meson
	"
case "$CARCH" in
x86_64) makedepends="$makedepends ceph-dev qemu>=5.2.0" ;;
esac
source="https://dist.test/libvirt/libvirt-1.tar.xz
	libvirt.initd
	patched-name::https://dist.test/other/thing.tar.gz
	"
EOF
  cat > "$IN/in/APKBUILD.patch" <<'EOF'
--- a/APKBUILD
+++ b/APKBUILD
@@ -2,3 +2,3 @@
 pkgver=1
-pkgrel=0
+pkgrel=100
 _daemon_deps="
@@ -12,2 +12,3 @@
 	meson
+	libapparmor-dev
 	"
EOF
  echo "libvirt other" > "$IN/in/libvirt.initd"
  local c
  for c in addgroup adduser chown apk abuild abuild-keygen id; do
    cat > "$TEST_DIR/bin/$c" <<'SHIM'
#!/usr/bin/env bash
n=${0##*/}
echo "$n $*" >> "$SHIM_LOG"
case "$n" in
  id) exit 1 ;;
  apk) [[ "$1" == --print-arch ]] && echo x86_64 ;;
  abuild-keygen) mkdir -p "$HPS_INNER_ROOT/home/builder/.abuild"; echo k > "$HPS_INNER_ROOT/home/builder/.abuild/k.rsa" ;;
  abuild) [[ -d "$HPS_INNER_ROOT/home/builder/.abuild" ]] || exit 9; [[ -z "${FAKE_ABUILD_FAIL:-}" ]] || exit 1 ;;
esac
exit 0
SHIM
    chmod +x "$TEST_DIR/bin/$c"
  done
  # install without the owner options (the test does not run as root)
  cat > "$TEST_DIR/bin/install" <<'SHIM'
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
SHIM
  cat > "$TEST_DIR/bin/su" <<'SHIM'
#!/usr/bin/env bash
echo "su $*" >> "$SHIM_LOG"
cmd=""
while [[ $# -gt 0 ]]; do
  case "$1" in -s) shift 2 ;; -c) cmd=$2; shift 2 ;; *) shift ;; esac
done
exec bash -c "$cmd"
SHIM
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --output) out=$2; shift ;; esac
  shift
done
echo "source data" > "$out"
SHIM
  chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/su" "$TEST_DIR/bin/curl"
  mkdir -p "$HPS_INNER_ROOT/var/cache/distfiles"
  INNER="$B/hps-apk-inner.sh"
}

@test "inner prepare: the user, a clean tree, the staged files, and the makedepends read from the APKBUILD with the package's own name left out" {
  inner_setup
  run bash "$INNER" prepare
  [ "$status" -eq 0 ]
  grep -q '^adduser -D -u 1000 -s /bin/bash builder' "$SHIM_LOG"
  grep -q '^addgroup builder abuild' "$SHIM_LOG"
  [ -f "$HPS_INNER_ROOT/home/builder/aports/community/libvirt/APKBUILD" ] && [ -f "$HPS_INNER_ROOT/home/builder/aports/community/libvirt/libvirt.initd" ]
  # the patch is applied first and the makedepends are those of the patched file (libapparmor-dev is the patch's)
  grep -qxF 'apk add --no-progress --virtual .makedepends-libvirt bridge-utils iproute2-tc meson libapparmor-dev ceph-dev qemu>=5.2.0' "$SHIM_LOG"
  grep -qx 'pkgrel=100' "$HPS_INNER_ROOT/home/builder/aports/community/libvirt/APKBUILD"
  [ ! -e "$HPS_INNER_ROOT/home/builder/aports/community/libvirt/APKBUILD.patch" ]
  run ! grep -q 'libvirt=1-r0' "$SHIM_LOG"
}

@test "inner prepare: a job.env with an unknown key, or a path of another shape, is refused" {
  inner_setup
  echo 'run=x' >> "$HPS_INNER_ROOT/opt/hps/job.env"
  run bash "$INNER" prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown key 'run'"* ]]
  printf 'pkgname=libvirt\naports_dir=../x\npatch=APKBUILD.patch\n' > "$HPS_INNER_ROOT/opt/hps/job.env"
  run bash "$INNER" prepare
  [ "$status" -eq 1 ]
}

@test "inner build: a key is made before abuild runs with dependency checking off, and the key is removed after" {
  inner_setup
  cd "$HPS_INNER_ROOT/home/builder"
  bash "$INNER" prepare > /dev/null 2>&1
  : > "$SHIM_LOG"
  run bash "$INNER" build
  [ "$status" -eq 0 ] || { echo "$output" >&3; false; }
  grep -qx 'pkgrel=100' aports/community/libvirt/APKBUILD
  # abuild's busybox wget cannot CONNECT through the proxy: the https sources are fetched with curl
  # into the distfiles directory first (under their own name, or the name before ::), files of the
  # aports directory are not fetched, and the patch file is not left for abuild to warn about
  [ -s "$HPS_INNER_ROOT/var/cache/distfiles/libvirt-1.tar.xz" ] && [ -s "$HPS_INNER_ROOT/var/cache/distfiles/patched-name" ]
  grep -q -- '^curl --fail .*--proto =https --proto-redir =https .*--output .*/libvirt-1.tar.xz.part https://dist.test/libvirt/libvirt-1.tar.xz$' "$SHIM_LOG"
  [ "$(grep -c '^curl ' "$SHIM_LOG")" -eq 2 ]
  [ "$(grep -n '^curl' "$SHIM_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^abuild -d' "$SHIM_LOG" | cut -d: -f1)" ]
  # a source already in the distfiles is not fetched again
  : > "$SHIM_LOG"
  run bash "$INNER" build
  [ "$status" -eq 0 ]
  run ! grep -q '^curl ' "$SHIM_LOG"
  grep -qx 'abuild-keygen -a -n' "$SHIM_LOG"
  grep -qx 'abuild -d' "$SHIM_LOG"
  [ "$(grep -n '^abuild-keygen' "$SHIM_LOG" | cut -d: -f1)" -lt "$(grep -n '^abuild -d' "$SHIM_LOG" | cut -d: -f1)" ]
  [ ! -e .abuild ]
}

@test "inner prepare: a patch that does not fit stops the job before any package is installed, key or abuild" {
  inner_setup
  sed -i 's/^pkgrel=0/pkgrel=3/' "$HPS_INNER_ROOT/opt/hps/in/APKBUILD"
  run bash "$INNER" prepare
  [ "$status" -ne 0 ]
  run ! grep -q '^apk add\|^abuild' "$SHIM_LOG"
}

@test "inner build: a failing abuild still removes the key" {
  inner_setup
  cd "$HPS_INNER_ROOT/home/builder"
  bash "$INNER" prepare > /dev/null 2>&1
  FAKE_ABUILD_FAIL=1 run bash "$INNER" build
  [ "$status" -ne 0 ]
  [ ! -e .abuild ]
}

@test "inner meta: an APKBUILD whose depends are exactly the arguments; anything that is not name=version-release is refused" {
  inner_setup
  cd "$HPS_INNER_ROOT/home/builder"
  run bash "$INNER" meta libvirt-apparmor 12.3.0 100 libvirt=12.3.0-r100 libvirt-daemon=12.3.0-r100
  [ "$status" -eq 0 ]
  grep -qx 'depends="libvirt=12.3.0-r100 libvirt-daemon=12.3.0-r100"' meta/APKBUILD
  grep -qx 'pkgname=libvirt-apparmor' meta/APKBUILD
  grep -q '^url="https://' meta/APKBUILD
  grep -q '^license=' meta/APKBUILD
  grep -qx 'pkgrel=100' meta/APKBUILD
  grep -qx 'abuild -d' "$SHIM_LOG"
  [ ! -e .abuild ]
  : > "$SHIM_LOG"
  run bash "$INNER" meta libvirt-apparmor 12.3.0 100 'libvirt;reboot=1-r1'
  [ "$status" -eq 1 ]
  run bash "$INNER" meta libvirt-apparmor 12.3.0 100
  [ "$status" -eq 1 ]
  run bash "$INNER" meta 'x y' 12.3.0 100 libvirt=1-r1
  [ "$status" -eq 1 ]
  run ! grep -q '^abuild' "$SHIM_LOG"
  run bash "$INNER" frobnicate
  [ "$status" -eq 2 ]
}

# --- the patch ---------------------------------------------------------------------------------

@test "the APKBUILD patch: the two meson options and the profile switch, libapparmor-dev, pkgrel 100, --libexec untouched" {
  local p="$RECIPE_DIR/APKBUILD.patch"
  grep -qx '+		-Dapparmor=enabled \\' "$p"
  grep -qx '+		-Dsecdriver_apparmor=enabled \\' "$p"
  grep -qx '+		-Dapparmor_profiles=disabled \\' "$p"
  grep -qx '+	libapparmor-dev' "$p"
  grep -qx '+pkgrel=100' "$p"
  grep -qx -- '-pkgrel=0' "$p"
  run ! grep -q 'libexec' <(grep '^[-+]' "$p")
  # Alpine's other build paths and options are not touched: only additions, apart from pkgrel and the source host
  [ "$(grep -c '^-[^-]' "$p")" -eq 2 ]
}

@test "the APKBUILD patch applies to the APKBUILD the step 5 fetch read, when that copy is at hand" {
  local seen=/srv/projects/hps/tmp/step5/fetched/apkbuild-libvirt/files
  [ -d "$seen" ] || skip "the fetched APKBUILD of step 5 is not here"
  mkdir -p "$TEST_DIR/pt"
  cp "$seen"/*-APKBUILD "$TEST_DIR/pt/APKBUILD"
  cd "$TEST_DIR/pt"
  run patch -p1 -F0 --no-backup-if-mismatch -i "$RECIPE_DIR/APKBUILD.patch"
  [ "$status" -eq 0 ]
  grep -qx 'pkgrel=100' APKBUILD
  grep -q -- '-Dapparmor=enabled' APKBUILD
  [ "$(sha256sum "$seen"/*-APKBUILD | cut -d' ' -f1)" = "$(sed -n 's/^file APKBUILD //p' "$RECIPE_DIR/PINS")" ]
}

@test "the Nix wiring: the action and both boot files are in the builder profile, nowhere else" {
  grep -qxF '      builder-apk-build.source = mkScript "builder-apk-build" (scriptsDir + "/builder-apk-build");' "$ROOT/nix/modules/profiles/builder.nix"
  grep -qxF '      builder-apk-build.options.profile = "node";' "$ROOT/nix/modules/profiles/builder.nix"
  grep -q 'environment.etc."hps/hps-apk-build"' "$ROOT/nix/modules/profiles/builder.nix"
  grep -q 'environment.etc."hps/hps-apk-inner"' "$ROOT/nix/modules/profiles/builder.nix"
  run ! grep -rq 'builder-apk-build\|hps-apk-build' "$ROOT/nix/modules/hps-ctrl-exec.nix" "$ROOT/nix/modules/profiles/container-host.nix"
}
