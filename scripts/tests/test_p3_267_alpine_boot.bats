#!/usr/bin/env bats
#
# Plan step 4, the IPS side of an Alpine starter node: the kernel line and the apkovl the
# stock initramfs fetches (lib/functions.d/alpine-boot-functions.sh, node_apkovl_tar),
# and the package list an Alpine node asks for (node_role_packages). The starter and the
# repository are what hps-starter sync alpine leaves (t/282-starter-alpine.t).

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-267.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  source "$ROOT/lib/functions.d/alpine-boot-functions.sh"
  source "$ROOT/lib/functions.d/node-bundle-functions.sh"
  p1_50_stubs
  ipxe_header() { printf '#!ipxe\n'; }
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:02
  SDIR="$TEST_DIR/res/starter/alpine/3.24"
  RDIR="$TEST_DIR/res/packages/alpine/3.24"
  mkdir -p "$SDIR" "$RDIR"
  printf 'kernel' > "$SDIR/vmlinuz-lts"
  printf 'initrd' > "$SDIR/initramfs-lts"
  printf '{"schema":"hps-starter/1","cmdline":"ip=dhcp modloop=none"}\n' > "$SDIR/manifest.json"
  printf '{"schema":"hps-repo/1","roots":{"linux-lts":"linux-lts-6.18.63-r0","ctrl-exec-agent":"local/ctrl-exec-agent","jq":"jq-1.8-r0","zfs":"zfs-2.4.4-r0","targetcli":"targetcli-2.1.58-r4"}}\n' > "$RDIR/manifest.json"
  p1_50_host "$MAC" os_id x86_64:alpine:3.24
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "alpine starter boot lines: the kernel and initramfs of the matched set, the stock arguments, the IPS repository, the apkovl, the hps arguments" {
  run alpine_starter_boot_lines "$MAC" 3.24
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "kernel http://10.0.0.1/starter/alpine/3.24/vmlinuz-lts initrd=initramfs-lts ip=dhcp modloop=none console=ttyS0,115200 alpine_repo=http://10.0.0.1/packages/alpine/3.24/main,http://10.0.0.1/packages/alpine/3.24/community apkovl=http://10.0.0.1/cgi-bin/boot_manager.sh?cmd=node_apkovl/node.apkovl.tar.gz hps.ips=10.0.0.1 hps.mac=$MAC hps.os=x86_64:alpine:3.24 hps.profile=STARTER"* ]]
  [ "${lines[1]}" = "initrd http://10.0.0.1/starter/alpine/3.24/initramfs-lts" ]
  [ "${lines[2]}" = "boot" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "alpine starter boot lines: nothing in them is an iPXE operator, and the apkovl URL ends in .tar.gz (the stock init unpacks by that suffix)" {
  run alpine_starter_boot_lines "$MAC" 3.24
  [ "$status" -eq 0 ]
  k="${lines[0]}"
  [[ "$k" != *'&'* && "$k" != *';'* && "$k" != *'|'* && "$k" != *'$'* && "$k" != *'\'* && "$k" != *'`'* ]]
  url="$(printf '%s\n' "$k" | tr ' ' '\n' | sed -n 's/^apkovl=//p')"
  # what the stock init does with it: the name after the last "/", without the query
  name="${url##*/}"
  name="${name%%\?*}"
  [ "${name##*.}" = gz ]
}

@test "alpine starter boot lines: the ZFS hostid, the DNS domain and the unconfined acknowledgement when the installation has them" {
  source "$ROOT/lib/functions.d/network-functions.sh"
  printf 'lab.test' > "$TEST_DIR/cluster/network_dns_domain"
  run alpine_starter_boot_lines "$MAC" 3.24
  [[ "${lines[0]}" == *" hps.zfs_hostid="* ]]
  [[ "${lines[0]}" == *" hps.domain=lab.test"* ]]
  [[ "${lines[0]}" != *"hps.unconfined"* ]]
  printf 'true' > "$TEST_DIR/cluster/allow_unconfined_guests"
  run alpine_starter_boot_lines "$MAC" 3.24
  [[ "${lines[0]}" == *" hps.unconfined=ack"* ]]
  printf 'false' > "$TEST_DIR/cluster/allow_unconfined_guests"
  run alpine_starter_boot_lines "$MAC" 3.24
  [[ "${lines[0]}" != *"hps.unconfined"* ]]
}

@test "alpine starter boot lines: no starter, no repository, no IPS address, a bad release: refused with a log line" {
  rm "$SDIR/vmlinuz-lts"
  run alpine_starter_boot_lines "$MAC" 3.24
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'Alpine starter 3.24 missing.*hps-starter sync alpine' "$TEST_DIR/hps.log"
  printf 'kernel' > "$SDIR/vmlinuz-lts"
  rm "$RDIR/manifest.json"
  run alpine_starter_boot_lines "$MAC" 3.24
  [ "$status" -eq 1 ]
  grep -q 'Alpine repository 3.24 missing' "$TEST_DIR/hps.log"
  run alpine_starter_boot_lines "$MAC" '3.24;x'
  [ "$status" -eq 1 ]
  grep -q "invalid release" "$TEST_DIR/hps.log"
}

@test "alpine_emit_starter_boot: a full iPXE script; an unusable starter is the error screen" {
  run alpine_emit_starter_boot "$MAC" 3.24
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "#!ipxe" ]
  [[ "$output" == *"imgfree"* && "$output" == *"initrd http://10.0.0.1/starter/alpine/3.24/initramfs-lts"* ]]
  rm "$SDIR/manifest.json"
  run alpine_emit_starter_boot "$MAC" 3.24
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: Alpine starter 3.24 unavailable: run hps-starter sync alpine"* ]]
}

@test "ipxe_boot_alpine: HOST_PROFILE STARTER takes the starter path and opens the pairing window; anything else keeps the older path" {
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  nixos_open_pairing_window() { echo "window $1" >> "$TEST_DIR/calls.log"; }
  p1_50_host "$MAC" HOST_PROFILE STARTER
  mac="$MAC"
  run ipxe_boot_alpine
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel http://10.0.0.1/starter/alpine/3.24/vmlinuz-lts"* ]]
  grep -q "window $MAC" "$TEST_DIR/calls.log"
  # not a starter host: the older code runs (it needs a cluster and an old repository: it says so, and does not boot the starter)
  p1_50_host "$MAC" HOST_PROFILE TCH
  run ipxe_boot_alpine
  [[ "$output" != *"starter/alpine"* ]]
}

@test "the apkovl: a world file, the marker for the stock boot services, OpenRC's local service and the one hook script; deterministic; no secret" {
  node_apkovl_tar "$ROOT" > "$TEST_DIR/a.tgz"
  node_apkovl_tar "$ROOT" > "$TEST_DIR/b.tgz"
  cmp "$TEST_DIR/a.tgz" "$TEST_DIR/b.tgz"
  mkdir "$TEST_DIR/x" && tar -xzf "$TEST_DIR/a.tgz" -C "$TEST_DIR/x"
  [ -f "$TEST_DIR/x/etc/apk/world" ]
  [ -f "$TEST_DIR/x/etc/.default_boot_services" ]
  [ -L "$TEST_DIR/x/etc/runlevels/default/local" ]
  [ "$(readlink "$TEST_DIR/x/etc/runlevels/default/local")" = /etc/init.d/local ]
  [ -x "$TEST_DIR/x/etc/local.d/hps-bootstrap.start" ]
  [ -f "$TEST_DIR/x/etc/network/interfaces" ]
  # the base the bundle needs before it can install anything else
  for p in alpine-base ssl_client bash curl openssh sudo shadow; do grep -qx "$p" "$TEST_DIR/x/etc/apk/world" || { echo "world lacks $p"; return 1; }; done
  # the hook runs node_bootstrap from hps.ips= and nothing else
  grep -q 'cmd=node_bootstrap' "$TEST_DIR/x/etc/local.d/hps-bootstrap.start"
  grep -q 'hps.ips=' "$TEST_DIR/x/etc/local.d/hps-bootstrap.start"
  sh -n "$TEST_DIR/x/etc/local.d/hps-bootstrap.start"
  ! grep -rqiE 'secret|password|BEGIN .*PRIVATE|authorized_keys' "$TEST_DIR/x"
  # the stock init unpacks a .gz with tar: owner root, nothing group or world writable
  tar -tvzf "$TEST_DIR/a.tgz" | grep -q ' 0/0 '
  ! tar -tvzf "$TEST_DIR/a.tgz" | grep -E '^.{5}w|^.{8}w'
}

@test "the apkovl is not in the bundle: the bundle of a NixOS node is what it was" {
  node_bundle_tar "$ROOT" > "$TEST_DIR/bundle.tgz"
  ! tar -tzf "$TEST_DIR/bundle.tgz" | grep -q 'apkovl'
  tar -tzf "$TEST_DIR/bundle.tgz" | grep -q '^./adapter/alpine.sh$'
}

@test "the boot_manager CGI serves the apkovl under node_apkovl and node_apkovl/<file>" {
  grep -q 'cmd" == "node_apkovl" || "$cmd" == node_apkovl/\*' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'node_apkovl_tar > "$apkovl_tmp"' "$ROOT/http/cgi-bin/boot_manager.sh"
}

# --- the package list ---------------------------------------------------------------------

roles_fixture() {
  cp "$ROOT/lib/starter/alpine.roles" "$TEST_DIR/roles.in"
  mkdir -p "$TEST_DIR/tree/lib/starter"
  printf '*: linux-lts ctrl-exec-agent jq\nSCH: zfs targetcli\nTCH: libvirt-daemon\n' > "$TEST_DIR/tree/lib/starter/alpine.roles"
}

@test "node_role_packages, alpine: names, the local ones marked, in role order, from the repository's roots" {
  roles_fixture
  run node_role_packages x86_64:alpine:3.24 SCH "$TEST_DIR/tree" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'linux-lts\nlocal/ctrl-exec-agent\njq\nzfs\ntargetcli')" ]
}

@test "node_role_packages, alpine: a name the repository does not hold is an error that names it" {
  roles_fixture
  run node_role_packages x86_64:alpine:3.24 TCH "$TEST_DIR/tree" "$TEST_DIR/res"
  [ "$status" -eq 1 ]
  grep -q 'repository does not hold: libvirt-daemon' "$TEST_DIR/hps.log"
}

@test "the shipped Alpine package list and role list agree: every role name is a package of the list" {
  names="$(sed 's/#.*//' "$ROOT/lib/starter/alpine.packages" | awk 'NF {print $1}' | sort -u)"
  for n in $(sed 's/#.*//' "$ROOT/lib/starter/alpine.roles" | awk -F: 'NF > 1 {print $2}' | tr ' ' '\n' | sort -u); do
    printf '%s\n' "$names" | grep -qx "$n" || { echo "role names $n, which alpine.packages lacks"; return 1; }
  done
}
