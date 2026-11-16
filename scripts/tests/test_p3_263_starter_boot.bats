#!/usr/bin/env bats
#
# Plan step 1: a host assigned HOST_PROFILE STARTER boots the stock starter
# that hps-starter put under <resources>/starter/nixos/<release>/, not a built
# pinned image (nixos-boot-functions.sh). Plan step 2 adds the hook and the hps.*
# arguments the node bundle needs. Pinned boots stay as they were.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-263.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  ipxe_header() { printf '#!ipxe\n'; }
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
  SDIR="$TEST_DIR/res/starter/nixos/26.05"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# starter_files [cmdline]: what hps-starter sync leaves for release 26.05
starter_files() {
  mkdir -p "$SDIR"
  printf 'kernel' > "$SDIR/bzImage"
  printf 'initrd' > "$SDIR/initrd"
  printf '{"schema":"hps-starter/1","cmdline":"%s"}\n' \
    "${1:-init=/nix/store/abc-nixos-system-nixos-kexec-26.05.1.abc/init initrd=initrd nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf}" > "$SDIR/manifest.json"
}

@test "starter boot lines: stock kernel and initramfs from the IPS, the stock arguments first, a serial console" {
  starter_files
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "kernel http://10.0.0.1/starter/nixos/26.05/bzImage init=/nix/store/abc-nixos-system-nixos-kexec-26.05.1.abc/init initrd=initrd nohibernate root=fstab loglevel=4 lsm=landlock,yama,apparmor,bpf apparmor=1 console=ttyS0,115200 hps.ips=10.0.0.1 hps.mac=$MAC hps.os=x86_64:nixos:26.05 hps.profile=STARTER "* ]]
  [ "${lines[1]}" = "initrd http://10.0.0.1/starter/nixos/26.05/initrd" ]
  [ "${lines[2]}" = "boot" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "starter boot lines: AppArmor is in the lsm list and on, as on a pinned node (lsm=landlock,yama,apparmor,bpf apparmor=1)" {
  # the stock starter's kernel has AppArmor built in but its lsm= list leaves it out
  run nixos_starter_apparmor_args "init=/x/init nohibernate lsm=landlock,yama,bpf loglevel=4"
  [ "$status" -eq 0 ]
  [ "$output" = "init=/x/init nohibernate lsm=landlock,yama,apparmor,bpf loglevel=4 apparmor=1" ]
  # a list that already has it is left, a stock apparmor=0 is replaced, no second copy
  run nixos_starter_apparmor_args "a lsm=landlock,yama,apparmor,bpf apparmor=0 b"
  [ "$output" = "a lsm=landlock,yama,apparmor,bpf b apparmor=1" ]
  # no bpf: appended; no lsm= at all: the pinned list
  run nixos_starter_apparmor_args "a lsm=yama b"
  [ "$output" = "a lsm=yama,apparmor b apparmor=1" ]
  run nixos_starter_apparmor_args "a b"
  [ "$output" = "a b lsm=landlock,yama,apparmor,bpf apparmor=1" ]
}

@test "starter boot lines: the pinned images' own lines are not touched" {
  # one caller, in the starter's line maker
  [ "$(grep -c 'nixos_starter_apparmor_args "' "$ROOT/lib/functions.d/nixos-boot-functions.sh")" -eq 1 ]
}

@test "starter boot lines carry what the node bundle needs: the IPS, the MAC, the OS, the profile, the DNS domain" {
  starter_files
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  printf 'cluster.test' > "$TEST_DIR/cluster/network_dns_domain"
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  for a in hps.ips=10.0.0.1 "hps.mac=$MAC" hps.os=x86_64:nixos:26.05 hps.profile=STARTER hps.domain=cluster.test; do
    [[ "${lines[0]}" == *" $a "* ]] || { echo "missing $a"; return 1; }
  done
  # no pin, no secret, no host key beyond those
  [[ "${lines[0]}" != *"hps.pin"* ]]
}

@test "the hook: systemd.run runs one pipe, curl to the IPS into a shell, and does not power off" {
  run nixos_starter_hook 10.0.0.1
  [ "$status" -eq 0 ]
  [[ "$output" == 'systemd.run="/bin/sh -c '\''/run/current-system/sw/bin/curl '* ]]
  [[ "$output" == *"http://10.0.0.1/cgi-bin/boot_manager.sh?cmd=node_bootstrap | /bin/sh'\"" ]] || [[ "$output" == *"http://10.0.0.1/cgi-bin/boot_manager.sh?cmd=node_bootstrap | /bin/sh'\" "* ]]
  [[ "$output" == *" systemd.run_success_action=none"* ]]
  [[ "$output" == *" systemd.run_failure_action=none"* ]]
  # NixOS's default target beats the generated one: without this the unit never starts
  [[ "$output" == *" systemd.wants=kernel-command-line.service" ]]
}

@test "the hook has none of the characters iPXE or the kernel line would mangle" {
  run nixos_starter_hook 10.0.0.1
  # iPXE reads && and || (and ;) as operators of its own: the lab trial found this
  [[ "$output" != *"&"* && "$output" != *"||"* && "$output" != *";"* ]]
  [[ "$output" != *'$'* && "$output" != *'\'* && "$output" != *'`'* && "$output" != *'#'* ]]
  # exactly one quoted argument: the kernel reads systemd.run="..." as one word
  [ "$(printf '%s' "$output" | tr -cd '"' | wc -c)" -eq 2 ]
  # and it fetches nothing but this IPS
  [ "$(printf '%s\n' "$output" | grep -o 'http://[^/ ]*' | sort -u)" = "http://10.0.0.1" ]
}

@test "the hook fetches the one bootstrap script and nothing is built into the image: no key, no token in the line" {
  starter_files
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"key"* && "${lines[0]}" != *"token"* && "${lines[0]}" != *"secret"* && "${lines[0]}" != *"password"* ]]
}

@test "an IPS address that is not safe in a kernel line is refused" {
  starter_files
  printf '10.0.0.1 evil=1' > "$TEST_DIR/cluster/network_dhcp_ip"
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 1 ]
  grep -q "not usable in a kernel line" "$TEST_DIR/hps.log"
}

@test "a host with profile STARTER gets the starter script of its os_id release, pin or no pin" {
  starter_files
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == "#!ipxe"* ]]
  [[ "$output" == *"imgfree"* ]]
  [[ "$output" == *"kernel http://10.0.0.1/starter/nixos/26.05/bzImage "* ]]
  [[ "$output" == *$'\nboot' ]]
  [[ "$output" != *"/nixos/"*"/node-"* ]]
}

@test "the starter boot ignores a leftover system_pin and opens the pairing window, as a pinned boot does" {
  starter_files
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  p1_50_host "$MAC" system_pin oldpin
  ce_pairing_window_open() { echo "window $1" >> "$CALL_LOG"; }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" != *"oldpin"* ]]
  grep -q "^window 300" "$CALL_LOG"
}

@test "a starter host is offered pairing like a pinned one: the old pairing record is cleared" {
  starter_files
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  p1_50_host "$MAC" ctrl_exec_paired_at 123
  p1_50_host "$MAC" ctrl_exec_paired 123
  ce_pairing_window_open() { :; }
  # the shared stub has no delete: this one removes the key
  host_registry() {
    local d="$TEST_DIR/hosts/${1//:/}"
    case "$2" in
      get) [[ -f "$d/$3" ]] && cat "$d/$3" ;;
      delete) rm -f "$d/$3" ;;
      *) return 0 ;;
    esac
  }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_DIR/hosts/525400aabb01/ctrl_exec_paired_at" ]
  [ ! -e "$TEST_DIR/hosts/525400aabb01/ctrl_exec_paired" ]
}

@test "no window is opened for a boot that failed (no starter synced)" {
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  ce_pairing_window_open() { echo "window" >> "$CALL_LOG"; }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 1 ]
  ! grep -q window "$CALL_LOG"
}

@test "a pinned CONVERGED host still boots its built image" {
  p1_50_manifest hostpin node-converged
  p1_50_host "$MAC" system_pin hostpin
  p1_50_host "$MAC" HOST_PROFILE CONVERGED
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  starter_files
  ce_pairing_window_open() { :; }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel http://10.0.0.1/nixos/hostpin/node-converged/bzImage "* ]]
  [[ "$output" != *"/starter/"* ]]
}

@test "no starter synced: the host gets an error screen that says to run hps-starter" {
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: NixOS starter 26.05 unavailable: run hps-starter sync nixos"* ]]
  grep -q "hps-starter sync nixos" "$TEST_DIR/hps.log"
}

@test "a manifest without init= in its cmdline is not booted" {
  starter_files "quiet loglevel=4"
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 1 ]
  grep -q "no init=" "$TEST_DIR/hps.log"
}

@test "the release comes from os_id and is path-safe" {
  starter_files
  run nixos_starter_boot_lines "$MAC" "../26.05"
  [ "$status" -eq 1 ]
  run nixos_starter_boot_lines "$MAC" ""
  [ "$status" -eq 1 ]
}

# Plan step 3: the stock starter has one hostid for every node, so the boot line gives
# each node its own, as the pinned images' lines do (spl reads it when the module loads).
@test "starter boot lines carry the node's own ZFS hostid: the same on every boot, different per host, recorded" {
  source "$ROOT/lib/functions.d/network-functions.sh"
  starter_files
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  p1_50_host 52:54:00:aa:bb:02 os_id x86_64:nixos:26.05
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ \ spl\.spl_hostid=0x([0-9a-f]{8})\  ]]
  h1="${BASH_REMATCH[1]}"
  [ "$h1" = "$(nixos_zfs_hostid "$MAC")" ]
  [ "$h1" != 00000000 ]
  run nixos_starter_boot_lines "$MAC" 26.05
  [[ "${lines[0]}" == *" spl.spl_hostid=0x$h1 "* ]]
  run nixos_starter_boot_lines 52:54:00:aa:bb:02 26.05
  [[ "${lines[0]}" =~ \ spl\.spl_hostid=0x([0-9a-f]{8})\  ]]
  [ "${BASH_REMATCH[1]}" != "$h1" ]
  # nothing else about the line changed: the hook is still the last thing on it
  [[ "${lines[0]}" == *" systemd.wants=kernel-command-line.service" ]]
}
