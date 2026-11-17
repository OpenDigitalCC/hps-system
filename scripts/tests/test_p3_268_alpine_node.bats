#!/usr/bin/env bats
#
# Plan step 4 (node-manager/bundle/adapter/alpine.sh, docs/BUNDLE.md "Alpine"): what the
# bundle's init does on an Alpine node, run against shims of curl, apk, rc-service and
# the user tools, with the bundle the IPS really builds. The same init and the same role
# file as the NixOS node (test_p3_265, test_p3_266); this is the adapter's part. No
# network, no root, no Alpine.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-268.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TEST_DIR ROOT
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  export HPS_RUN_DIR="$TEST_DIR/run" HPS_ROOT="$TEST_DIR/root" HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_PKG_PREFIX="$TEST_DIR/usr" HPS_PKG_ETC="$TEST_DIR/root/etc"
  export HPS_OPENRC_DIR="$TEST_DIR/initd" HPS_LIB_MODULES="$TEST_DIR/lib/modules"
  export HPS_ZVOL_ID="$TEST_DIR/zvol_id"
  export HPS_UDHCPC="$TEST_DIR/bin/udhcpc"
  export HPS_APK="$TEST_DIR/bin/apk" HPS_RC_SERVICE="$TEST_DIR/bin/rc-service"
  export HPS_PATH_EXTRA="$TEST_DIR/bin:$TEST_DIR/usr/bin" HPS_CPUINFO="$TEST_DIR/cpuinfo" HPS_FETCH_RETRY=0
  printf "#!/bin/bash\n" > "$TEST_DIR/zvol_id"; chmod +x "$TEST_DIR/zvol_id"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/serve" "$TEST_DIR/home/sysadmin" "$HPS_ROOT/etc/ssh" "$HPS_ROOT/etc/iscsi" \
    "$TEST_DIR/usr/bin" "$TEST_DIR/usr/sbin" "$TEST_DIR/usr/lib/hps-nagios-plugins" "$HPS_LIB_MODULES/6.18.63-0-lts" "$TEST_DIR/svc"
  echo "BOOT_IMAGE=vmlinuz-lts console=ttyS0 hps.ips=10.9.9.9 hps.mac=aa:bb:cc:dd:ee:ff hps.os=x86_64:alpine:3.24 hps.profile=STARTER hps.domain=lab.test hps.zfs_hostid=1a2b3c4d" > "$HPS_CMDLINE"
  printf 'vendor_id\t: GenuineIntel\n' > "$HPS_CPUINFO"
  printf '# the starter\nPermitRootLogin yes\n' > "$HPS_ROOT/etc/ssh/sshd_config"
  printf '# the package iscsid.conf\nnode.startup = manual\nnode.session.timeo.replacement_timeout = 120\n' > "$HPS_ROOT/etc/iscsi/iscsid.conf"
  shims
  programs
  source "$ROOT/lib/functions.d/node-bundle-functions.sh"
  hps_log() { :; }
  node_bundle_tar "$ROOT" > "$TEST_DIR/serve/bundle.tgz"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 admin@site' > "$TEST_DIR/serve/keys"
  printf '%s\n' linux-lts linux-firmware-none local/ctrl-exec-agent jq zfs zfs-lts targetcli local/nagios-check local/hps-nagios-plugins > "$TEST_DIR/serve/packages"
  echo "SCH" > "$TEST_DIR/serve/type"
  mkdir -p "$TEST_DIR/bundle"
  tar -xzf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/bundle"
  printf '#!/bin/bash\necho "hps-pair $*" >> "$CALLS"\nhostname sch-001.lab.test\n' > "$TEST_DIR/bundle/lib/hps-pair"
  for s in lib/hps-time actions/host-reserve-apply actions/net-bridge-ensure; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "${s##*/}" > "$TEST_DIR/bundle/$s"
  done
  printf '#!/bin/bash\necho "hps-iscsi-name $(hostname)" >> "$CALLS"\nmkdir -p "$HPS_RUN_DIR"\necho InitiatorName=iqn.test > "$HPS_RUN_DIR/initiatorname.iscsi"\n' > "$TEST_DIR/bundle/lib/hps-iscsi-name"
}

teardown() {
  rm -rf "$TEST_DIR"
}

shims() {
  local b="$TEST_DIR/bin" s
  cat > "$b/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CALLS"
out=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  prev="$a"
  case "$a" in http://*) url="$a" ;; esac
done
emit() { if [[ -n "$out" ]]; then cp "$1" "$out"; else cat "$1"; fi; }
case "$url" in
  *cmd=node_bundle) emit "$TEST_DIR/serve/bundle.tgz" ;;
  *cmd=node_sysadmin_keys) emit "$TEST_DIR/serve/keys" ;;
  *cmd=node_packages) emit "$TEST_DIR/serve/packages" ;;
  *"cmd=host_variable&name=TYPE") [[ -f "$TEST_DIR/serve/type" ]] || exit 22; emit "$TEST_DIR/serve/type" ;;
  *cmd=log_message*) echo "$*" >> "$TEST_DIR/iplog"; exit 0 ;;
  *) exit 22 ;;
esac
EOF
  cat > "$b/id" <<'EOF'
#!/bin/bash
case "$*" in
  "-gn "*) echo users ;;
  [a-z]*) [[ -e "$TEST_DIR/user-$1" ]] || exit 1; echo "uid=1001($1)" ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
  cat > "$b/getent" <<'EOF'
#!/bin/bash
case "$1" in
  group) [[ -e "$TEST_DIR/group-$2" ]] || exit 2; echo "$2:x:300:" ;;
  *) echo "sysadmin:x:1001:100::$TEST_DIR/home/sysadmin:/bin/bash" ;;
esac
EOF
  printf '#!/bin/bash\necho "useradd $*" >> "$CALLS"\ntouch "$TEST_DIR/user-${!#}"\n' > "$b/useradd"
  printf '#!/bin/bash\necho "groupadd $*" >> "$CALLS"\ntouch "$TEST_DIR/group-${!#}"\n' > "$b/groupadd"
  cat > "$b/install" <<'EOF'
#!/bin/bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
/usr/bin/install "${args[@]}"
EOF
  printf '#!/bin/bash\nif [[ $# -gt 0 ]]; then printf "%%s\\n" "$1" > "$TEST_DIR/khost"; else cat "$TEST_DIR/khost" 2> /dev/null || echo localhost; fi\n' > "$b/hostname"
  printf '#!/bin/bash\n[[ "$1" == -r ]] && echo 6.18.63-0-lts || /usr/bin/uname "$@"\n' > "$b/uname"
  # apk: logs, and the services of a package appear as the test needs them
  printf '#!/bin/bash\necho "apk $*" >> "$CALLS"\n[[ "$1" == info ]] && echo "${*: -1}-1.0-r0"\nexit 0\n' > "$b/apk"
  # rc-service: a service is started once it has been started
  cat > "$b/rc-service" <<'EOF'
#!/bin/bash
echo "rc-service $*" >> "$CALLS"
case "$2" in
  status) [[ -e "$TEST_DIR/svc/$1" ]] ;;
  start) touch "$TEST_DIR/svc/$1" ;;
  stop) rm -f "$TEST_DIR/svc/$1" ;;
  *) exit 0 ;;
esac
EOF
  printf '#!/bin/bash\nexit 0\n' > "$b/ip"
  printf '#!/bin/bash\necho "udhcpc $*" >> "$CALLS"\n' > "$b/udhcpc"
  for s in usermod chown chgrp passwd sshd ssh-keygen modprobe depmod zgenhostid mountpoint mount setsid; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n[[ "%s" == mountpoint ]] && exit 1\n[[ "%s" == modprobe && -n "${FAIL_MODPROBE:-}" && "$1" == "$FAIL_MODPROBE" ]] && exit 1\nexit 0\n' "$s" "$s" "$s" > "$b/$s"
  done
  chmod +x "$b"/*
}

programs() {
  local p
  for p in ctrl-exec-agent ctrl-exec-executor jq mdadm zpool zfs smartctl xxd targetcli om awk virsh qemu-img qemu-system-x86_64 tcpdump virtlogd libvirtd iscsid iscsiadm; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n[ "$1" = --version ] && echo "ctrl-exec-agent 0.14.7"\nexit 0\n' "$p" > "$TEST_DIR/usr/bin/$p"
  done
  mkdir -p "$TEST_DIR/usr/share/qemu"
  touch "$TEST_DIR/usr/share/qemu/edk2-x86_64-code.fd" "$TEST_DIR/usr/share/qemu/edk2-i386-vars.fd"
  printf '#!/bin/bash\necho "nagios-check $*" >> "$CALLS"\n' > "$TEST_DIR/usr/bin/nagios-check"
  for p in check_disk check_load check_procs check_mem; do printf '#!/bin/bash\n' > "$TEST_DIR/usr/lib/hps-nagios-plugins/$p"; done
  chmod +x "$TEST_DIR"/usr/bin/* "$TEST_DIR"/usr/lib/hps-nagios-plugins/*
}

ok0() { [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -30 >&3; return 1; }; }

svc() { cat "$HPS_OPENRC_DIR/$1"; }

# --- the node scripts are the same files ---------------------------------------

@test "the Alpine node runs the NixOS node's role file and node scripts: nothing is forked" {
  cmp "$TEST_DIR/bundle/role" "$ROOT/node-manager/bundle/role"
  cmp "$TEST_DIR/bundle/init" "$ROOT/node-manager/bundle/init"
  cmp "$TEST_DIR/bundle/actions/leg-resolve" "$ROOT/node-manager/nixos-26/scripts/leg-resolve"
  [ -f "$TEST_DIR/bundle/adapter/alpine.sh" ] && [ -f "$TEST_DIR/bundle/adapter/nixos.sh" ]
}

# --- boot: sysadmin, packages, the agent ---------------------------------------

@test "init, Alpine, SCH: sysadmin with the IPS key, sudo by sudoers.d, an unlocked account, root refused" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  [[ "$output" == *"done: bundle"* ]]
  grep -q '^useradd -m -s .*bash -G wheel sysadmin' "$CALLS"
  grep -qx "usermod -p \* sysadmin" "$CALLS"
  [ "$(cat "$HPS_ROOT/etc/sudoers.d/hps-sysadmin")" = 'sysadmin ALL=(ALL) NOPASSWD:ALL' ]
  [ "$(stat -c %a "$HPS_ROOT/etc/sudoers.d/hps-sysadmin")" = 440 ]
  grep -q 'ssh-ed25519 AAAAC3' "$TEST_DIR/home/sysadmin/.ssh/authorized_keys"
  head -n 3 "$HPS_ROOT/etc/ssh/sshd_config" | grep -qx 'PermitRootLogin no'
  grep -qx 'passwd -l root' "$CALLS"
  # the host keys exist before the configuration is checked (the first lab boot: "sshd: no hostkeys available")
  [ "$(grep -n '^ssh-keygen -A' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^sshd -t' "$CALLS" | head -1 | cut -d: -f1)" ]
  # sshd is installed by the package and started by the first run
  grep -qx 'rc-service sshd start' "$CALLS"
}

@test "init, Alpine: packages from the IPS repository only; kernel packages without scripts and then depmod; local ones unsigned, from the local repository" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  [ "$(cat "$HPS_ROOT/etc/apk/repositories")" = "$(printf 'http://10.9.9.9/packages/alpine/3.24/main\nhttp://10.9.9.9/packages/alpine/3.24/community')" ]
  grep -qx 'apk add --no-scripts --quiet linux-lts linux-firmware-none zfs-lts' "$CALLS"
  grep -qx 'depmod -a 6.18.63-0-lts' "$CALLS"
  grep -qx 'apk add --quiet jq zfs targetcli' "$CALLS"
  grep -q 'apk add --quiet --upgrade --allow-untrusted --repository http://10.9.9.9/packages/alpine/3.24/local ctrl-exec-agent' "$CALLS"
  # an upstream package is never installed unchecked
  ! grep -E '^apk add .*--allow-untrusted.* (jq|zfs|targetcli|linux-lts)( |$)' "$CALLS"
  # the kernel comes before what loads modules, depmod before the ordinary packages
  [ "$(grep -n '^depmod' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^apk add --quiet jq' "$CALLS" | head -1 | cut -d: -f1)" ]
}

@test "init, Alpine: a name that is not a package name is refused, not passed to apk" {
  printf '%s\n' 'jq; rm -rf /' linux-lts local/ctrl-exec-agent > "$TEST_DIR/serve/packages"
  run bash "$TEST_DIR/bundle/init" boot
  ! grep -q 'rm -rf' "$CALLS"
}

@test "init, Alpine: the agent and its executor are OpenRC services; the executor is root, the agent is the service user with no capability, and waits for its certificate" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  run svc ctrl-exec-executor
  [[ "$output" == *"#!/sbin/openrc-run"* ]]
  [[ "$output" == *"command=$TEST_DIR/usr/bin/ctrl-exec-executor"* ]]
  [[ "$output" == *"supervisor=supervise-daemon"* ]]
  [[ "$output" == *"checkpath -d -m 0755 /run/ctrl-exec-agent"* ]]
  [[ "$output" == *"# stamp: ctrl-exec-agent-1.0-r0"* ]]
  run svc ctrl-exec-agent
  [[ "$output" == *"--reuid=ctrl-exec-agent --regid=ctrl-exec-agent --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs --"* ]]
  [[ "$output" == *"ctrl-exec-agent/agent.crt"* && "$output" == *"promote-cert"* ]]
  [[ "$output" == *"# not applied (systemd only): ProtectSystem=strict"* ]]
  # no certificate before pairing: the agent is defined, not started; the executor runs
  grep -qx 'rc-service ctrl-exec-executor start' "$CALLS"
  ! grep -qx 'rc-service ctrl-exec-agent start' "$CALLS"
  # the agent's actions find the compatibility programs
  grep -q "^script_path = .*:$HPS_RUN_DIR/bin\$" "$HPS_ROOT/etc/ctrl-exec-agent/agent.conf"
  grep -qx "no_new_privileges = yes" <(sed -n '/\[profile node\]/,$p' "$HPS_ROOT/etc/ctrl-exec-agent/agent.conf" | sed -n 3p)
}

@test "init, Alpine: a new agent version is a changed service text, restarted a few seconds later, detached" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  printf '#!/bin/bash\necho "apk $*" >> "$CALLS"\n[[ "$1" == info ]] && echo "ctrl-exec-agent-2.0-r0"\nexit 0\n' > "$TEST_DIR/bin/apk"
  run bash "$TEST_DIR/bundle/init" refresh
  ok0
  [[ "$output" == *"the agent or its executor changed: restarting both in a few seconds"* ]]
  grep -q '# stamp: ctrl-exec-agent-2.0-r0' "$HPS_OPENRC_DIR/ctrl-exec-agent"
  [[ "$output" == *"+ (sleep 5; "*"rc-service ctrl-exec-executor restart; "*"rc-service ctrl-exec-agent restart;) detached"* ]]
}

# --- storage --------------------------------------------------------------------

@test "init, Alpine, SCH: the node's own ZFS hostid before the module, configfs mounted, dbus running, the services as OpenRC scripts" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  grep -qx 'zgenhostid -f 1a2b3c4d' "$CALLS"
  [ "$(grep -n '^zgenhostid' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^modprobe zfs' "$CALLS" | head -1 | cut -d: -f1)" ]
  grep -qx 'mount -t configfs none /sys/kernel/config' "$CALLS"
  grep -qx 'rc-service dbus start' "$CALLS"
  grep -qx 'modprobe target_core_mod' "$CALLS"
  # the dataset mount: a one-shot that stays "started" (the scripts start it by name)
  run svc hps-zfs-mount
  [[ "$output" == *"start() {"* && "$output" == *"zfs mount -a"* ]]
  [[ "$output" != *"supervise-daemon"* ]]
  # the power-off unit: nothing runs at start, the stop is the quiesce, after the services it needs
  run svc hps-shutdown-storage
  [[ "$output" == *"stop() {"* && "$output" == *"hps-shutdown-storage"* ]]
  [[ "$output" == *"use net libvirtd iscsid ctrl-exec-agent ctrl-exec-executor hps-log-journal"* ]]
  grep -qx 'rc-service hps-shutdown-storage start' "$CALLS"
}

@test "init, Alpine, SCH: om3 waits for its cluster secret, takes its arguments from the environment file, restarts itself" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  run svc opensvc-daemon
  [[ "$output" == *"supervisor=supervise-daemon"* ]]
  [[ "$output" == *'command_args="daemon run $OSVC_DAEMON_ARGS"'* ]]
  [[ "$output" == *"opensvc.env"* ]]
  [[ "$output" == *"osvc-cluster-secret"* ]]
  [[ "$output" == *"respawn_delay=5"* ]]
  ! grep -qx 'rc-service opensvc-daemon start' "$CALLS"
}

@test "init, Alpine: logs go to the IPS by syslog, one mirror monitor, no firewall to open" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  [ "$(cat "$HPS_ROOT/etc/conf.d/syslog")" = 'SYSLOGD_OPTS="-t -R 10.9.9.9:514 -L"' ]
  grep -qx 'rc-service syslog restart' "$CALLS"
  run svc mdmonitor
  [[ "$output" == *"--monitor --scan --foreground"* ]]
  [[ "$output" == *"supervisor=supervise-daemon"* ]]
  grep -q 'PROGRAM ' "$HPS_ROOT/etc/mdadm.conf"
}

# --- compute: AppArmor, as on NixOS, and no libvirt without the driver ---------------

tch_node() {
  echo TCH > "$TEST_DIR/serve/type"
  printf '%s\n' linux-lts local/ctrl-exec-agent jq local/libvirt-apparmor apparmor apparmor-profiles qemu-system-x86_64 open-iscsi local/nagios-check local/hps-nagios-plugins > "$TEST_DIR/serve/packages"
  # the AppArmor parser: lists what it was given as loaded, in enforce mode, in the file standing for the kernel's list
  cat > "$TEST_DIR/usr/sbin/apparmor_parser" <<'EOS'
#!/bin/bash
echo "apparmor_parser $*" >> "$CALLS"
f="${*: -1}"
[[ -f "$f" ]] || exit 1
name="$(grep -m1 -E ' (flags=\(.*\) )?\{$' "$f" | cut -d' ' -f1)"
echo "$name (enforce)" >> "$HPS_AA_PROFILES"
EOS
  chmod +x "$TEST_DIR/usr/sbin/apparmor_parser"
  mkdir -p "$HPS_PKG_ETC/apparmor.d/abstractions"
  export HPS_AA_ENABLED="$TEST_DIR/aa-enabled" HPS_AA_PROFILES="$TEST_DIR/aa-profiles"
  echo Y > "$HPS_AA_ENABLED"
  : > "$HPS_AA_PROFILES"
}

with_driver() {
  mkdir -p "$TEST_DIR/usr/libexec"
  printf '#!/bin/bash\n' > "$TEST_DIR/usr/libexec/virt-aa-helper"
  chmod +x "$TEST_DIR/usr/libexec/virt-aa-helper"
}

@test "init, Alpine, TCH: a libvirt without the AppArmor driver is refused, loudly, naming the local package: libvirtd is NOT started" {
  tch_node
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: this node's libvirt has no AppArmor driver"* ]]
  [[ "$output" == *"the local package libvirt-apparmor"* ]]
  [[ "$output" == *"libvirtd is NOT started"* ]]
  [[ "$output" == *"a role step failed: compute services"* ]]
  [ ! -e "$HPS_OPENRC_DIR/libvirtd" ]
  ! grep -qx 'rc-service libvirtd start' "$CALLS"
  grep -q 'role step failed: compute services' "$TEST_DIR/iplog"
}

@test "init, Alpine, TCH: AppArmor not active in the kernel is refused, with no fall back to the DAC model" {
  tch_node
  with_driver
  echo N > "$HPS_AA_ENABLED"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: AppArmor is not active in this kernel"* ]]
  [[ "$output" == *"libvirtd is NOT started"* ]]
  [ ! -e "$HPS_OPENRC_DIR/libvirtd" ]
}

@test "init, Alpine, TCH, with the driver and AppArmor active: the profiles are loaded in enforce mode with Alpine's paths before libvirtd starts; qemu.conf names apparmor" {
  tch_node
  with_driver
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  [[ "$output" == *"AppArmor active; libvirtd and virt-aa-helper profiles loaded (enforce)"* ]]
  # the profile of the daemon is for the real binary, not the nix wrapper's name
  grep -qx "$TEST_DIR/usr/bin/libvirtd (enforce)" "$HPS_AA_PROFILES"
  grep -q "^$TEST_DIR/usr/bin/libvirtd flags=" "$HPS_ROOT/etc/apparmor.d/hps/libvirtd"
  ! grep -q 'libvirtd-wrapped' "$HPS_ROOT/etc/apparmor.d/hps/libvirtd" "$HPS_ROOT/etc/apparmor.d/abstractions/libvirt-qemu"
  grep -q "$TEST_DIR/usr/sbin/apparmor_parser Ux" "$HPS_ROOT/etc/apparmor.d/hps/virt-aa-helper"
  # loaded before libvirtd starts
  [ "$(grep -n '^apparmor_parser' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^rc-service libvirtd start' "$CALLS" | head -1 | cut -d: -f1)" ]
  grep -qx 'security_driver = "apparmor"' "$HPS_ROOT/etc/libvirt/qemu.conf"
  run svc libvirtd
  [[ "$output" == *"need virtlogd"* && "$output" == *'rc_ulimit="-l unlimited"'* ]]
  # the parser is where /sbin/apparmor_parser would be: no link over itself
  [ ! -L "$HPS_ROOT/sbin/apparmor_parser" ] || [ "$(readlink -f "$HPS_ROOT/sbin/apparmor_parser")" = "$TEST_DIR/usr/sbin/apparmor_parser" ]
  # the UEFI firmware the guest definitions name
  [ -L "$HPS_ROOT/run/libvirt/nix-ovmf/edk2-x86_64-code.fd" ] && [ -L "$HPS_ROOT/run/libvirt/nix-ovmf/edk2-i386-vars.fd" ]
  # the initiator: the package's own iscsid.conf kept once beside the node's, the fail-fast lines once
  [ -f "$HPS_ROOT/etc/iscsi/iscsid.conf.hps-stock" ]
  [ "$(grep -c 'replacement_timeout = 15' "$HPS_ROOT/etc/iscsi/iscsid.conf")" -eq 1 ]
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$(grep -c 'replacement_timeout = 15' "$HPS_ROOT/etc/iscsi/iscsid.conf")" -eq 1 ]
}

@test "no cluster key makes an unconfined guest acceptable: the key is gone" {
  ! grep -rq 'allow_unconfined_guests\|hps.unconfined' "$ROOT/lib" "$ROOT/node-manager" "$ROOT/docs"
}

# --- the compatibility programs --------------------------------------------------

@test "the systemctl of an OpenRC node: the verbs the bundle's scripts use, over rc-service; what it cannot do it says" {
  run bash "$TEST_DIR/bundle/init" boot
  s="$HPS_RUN_DIR/bin/systemctl"
  [ -x "$s" ]
  : > "$CALLS"
  PATH="$TEST_DIR/bin:$PATH" run "$s" restart ctrl-exec-agent.service
  ok0
  grep -qx 'rc-service ctrl-exec-agent restart' "$CALLS"
  PATH="$TEST_DIR/bin:$PATH" run "$s" start --no-block hps-zfs-mount.service
  grep -qx 'rc-service hps-zfs-mount start' "$CALLS"
  # try-restart: only what runs
  : > "$CALLS"
  PATH="$TEST_DIR/bin:$PATH" run "$s" try-restart systemd-timesyncd.service
  ok0
  ! grep -q 'restart' "$CALLS"
  # cat: does the service exist (the scripts ask before they start the dataset mount)
  mkdir -p "$TEST_DIR/etc-init.d"
  PATH="$TEST_DIR/bin:$PATH" run "$s" cat hps-zfs-mount.service
  [ "$status" -eq 1 ]
  # a cgroup setting is not there, and says so
  PATH="$TEST_DIR/bin:$PATH" run "$s" set-property --runtime foo.slice CPUWeight=100
  [ "$status" -eq 1 ]
  [[ "$output" == *"not available on this OS (OpenRC)"* ]]
  PATH="$TEST_DIR/bin:$PATH" run "$HPS_RUN_DIR/bin/udevadm" settle --timeout=10
  ok0
  PATH="$TEST_DIR/bin:$PATH" run "$HPS_RUN_DIR/bin/udevadm" info /dev/sda
  [ "$status" -eq 1 ]
}

@test "the NixOS adapter and the Alpine adapter define the same functions" {
  names() { grep -oE '^[a-z_]+\(\)' "$1" | sort -u; }
  # the interface init and role call: every one is in both
  for f in adapter_init pkg_add pkg_realise pkg_kind pkg_agent_dir pkg_nagios_check pkg_nagios_plugins pkg_stamp svc_start svc_restart_later \
    svc_reload svc_ensure svc_mask svc_env fw_open user_unlock sudo_grant hostname_apply os_compat log_forward md_monitor zfs_hostid_set sshd_prepare refresh_watch zvol_links iscsid_conf_source aa_roots aa_parser_path aa_libvirtd_path aa_sed_args aa_libvirt_check; do
    grep -qE "^$f\(\)" "$ROOT/node-manager/bundle/adapter/nixos.sh" || { echo "nixos.sh lacks $f"; return 1; }
    grep -qE "^$f\(\)" "$ROOT/node-manager/bundle/adapter/alpine.sh" || { echo "alpine.sh lacks $f"; return 1; }
  done
}

@test "bundle-refresh without systemd asks the node's refresh service (no setns: the first lab try: 'nsenter: reassociate to namespaces failed: Operation not permitted'), waits, relays its output and its status" {
  mkdir -p "$HPS_RUN_DIR/bundle"
  printf '#!/bin/sh\necho "bootstrap ran with: $*"\n' > "$HPS_RUN_DIR/bundle/bootstrap.sh"
  # the service, run by hand here: the watch script the adapter writes, one pass
  run bash "$TEST_DIR/bundle/init" boot
  watch="$HPS_RUN_DIR/bin/hps-refresh-watch"
  [ -x "$watch" ]
  [ -e "$HPS_OPENRC_DIR/hps-refresh-watch" ]
  grep -qx 'rc-service hps-refresh-watch start' "$CALLS"
  ( HPS_RUN_DIR="$HPS_RUN_DIR" timeout 8 sh "$watch" > /dev/null 2>&1 & )
  HPS_SYSTEMD_RUN="$TEST_DIR/bin/no-systemd-run" run bash "$ROOT/node-manager/bundle/actions/bundle-refresh"
  ok0
  [[ "$output" == *"+ refresh requested of hps-refresh-watch"* ]]
  [[ "$output" == *"bootstrap ran with: refresh"* ]]
  [ ! -e "$HPS_RUN_DIR/refresh.request" ]
}

@test "bundle-refresh without systemd: no answer is an error that names the service; the status of the bootstrap is the action's" {
  mkdir -p "$HPS_RUN_DIR/bundle"
  printf '#!/bin/sh\nexit 0\n' > "$HPS_RUN_DIR/bundle/bootstrap.sh"
  HPS_REFRESH_TIMEOUT=2 HPS_SYSTEMD_RUN="$TEST_DIR/bin/no-systemd-run" run bash "$ROOT/node-manager/bundle/actions/bundle-refresh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no answer from hps-refresh-watch in 2 s"* ]]
  [ ! -e "$HPS_RUN_DIR/refresh.request" ]
  printf '#!/bin/sh\necho failing\nexit 7\n' > "$HPS_RUN_DIR/bundle/bootstrap.sh"
  mkdir -p "$HPS_RUN_DIR/bin"
  run bash "$TEST_DIR/bundle/init" boot
  ( HPS_RUN_DIR="$HPS_RUN_DIR" timeout 8 sh "$HPS_RUN_DIR/bin/hps-refresh-watch" > /dev/null 2>&1 & )
  HPS_SYSTEMD_RUN="$TEST_DIR/bin/no-systemd-run" run bash "$ROOT/node-manager/bundle/actions/bundle-refresh"
  [ "$status" -eq 7 ]
  [[ "$output" == *"failing"* ]]
}

@test "init, Alpine, SCH: zvol links for the zvols (mdev rule and hook, a scan), zfs-udev is the package that brings zvol_id" {
  printf '#!/bin/bash\n' > "$TEST_DIR/zvol_id"; chmod +x "$TEST_DIR/zvol_id"
  export HPS_ZVOL_ID="$TEST_DIR/zvol_id"
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  head -n 1 "$HPS_ROOT/etc/mdev.conf" | grep -q "^zd\[0-9\]+(p\[0-9\]+)?.root:disk 0660 @$HPS_RUN_DIR/bin/zvol-mdev\$"
  [ "$(grep -c zvol-mdev "$HPS_ROOT/etc/mdev.conf")" -eq 1 ]
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$(grep -c zvol-mdev "$HPS_ROOT/etc/mdev.conf")" -eq 1 ]
  # the hook: a zvol named by zvol_id gets its link
  mkdir -p "$TEST_DIR/devfake"
  grep -q 'ln -sf "/dev/$MDEV" "/dev/zvol/$name"' "$HPS_RUN_DIR/bin/zvol-mdev"
  sh -n "$HPS_RUN_DIR/bin/zvol-mdev"
  grep -qx 'zfs-udev' "$ROOT/lib/starter/alpine.packages"
  grep -q '^SCH: .*zfs-udev' "$ROOT/lib/starter/alpine.roles"
}

# --- the four gaps: time, lease, host reserve, node-journal --------------------------

@test "init, Alpine: the clock is kept in step with the IPS by busybox ntpd, the source the NixOS nodes use" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  [ "$(cat "$HPS_ROOT/etc/conf.d/ntpd")" = 'NTPD_OPTS="-N -p 10.9.9.9"' ]
  grep -qx 'rc-service ntpd start' "$CALLS"
  # once stepped by hps-time, then followed
  [ "$(grep -n '^hps-time' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n '^rc-service ntpd start' "$CALLS" | head -1 | cut -d: -f1)" ]
}

@test "init, Alpine: a DHCP client keeps the lease: udhcpc in the background on the interface that reaches the IPS, with the script that does not flush the address" {
  printf '#!/bin/bash\n[[ "$1 $2 $3" == "route get 10.9.9.9" ]] && echo "10.9.9.9 dev eth7 src 10.9.9.50 uid 0"\n' > "$TEST_DIR/bin/ip"
  printf '#!/bin/bash\necho "udhcpc $*" >> "$CALLS"\n' > "$TEST_DIR/bin/udhcpc"
  chmod +x "$TEST_DIR/bin/ip" "$TEST_DIR/bin/udhcpc"
  export HPS_ZVOL_ID="$TEST_DIR/zvol_id"
  export HPS_UDHCPC="$TEST_DIR/bin/udhcpc"
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  grep -q "^udhcpc -b -i eth7 -p /run/hps-udhcpc.eth7.pid -s $HPS_RUN_DIR/bin/udhcpc-hps -t 5\$" "$CALLS"
  # the script: deconfig is left alone, anything else is the stock script's
  mkdir -p "$TEST_DIR/fake/usr/share/udhcpc"
  run sh "$HPS_RUN_DIR/bin/udhcpc-hps" deconfig
  [ "$status" -eq 0 ]
  grep -q 'exec /usr/share/udhcpc/default.script' "$HPS_RUN_DIR/bin/udhcpc-hps"
}

cgfake() {
  export HPS_CGROUP_ROOT="$TEST_DIR/cg"
  mkdir -p "$HPS_CGROUP_ROOT"
  : > "$HPS_CGROUP_ROOT/cgroup.controllers"
  : > "$HPS_CGROUP_ROOT/cgroup.subtree_control"
}

@test "the host reserve on Alpine: systemctl set-property machine.slice writes cgroup v2 (cpuset, cpu.weight, io.weight, memory.max) with the figures host-reserve-apply passes; show reads them back" {
  run bash "$TEST_DIR/bundle/init" boot
  cgfake
  s="$HPS_RUN_DIR/bin/systemctl"
  PATH="$TEST_DIR/bin:$PATH" run "$s" set-property --runtime machine.slice AllowedCPUs=2-7 CPUWeight=900 IOWeight=900 MemoryMax=2048M
  ok0
  [ "$(cat "$HPS_CGROUP_ROOT/machine/cpuset.cpus")" = 2-7 ]
  [ "$(cat "$HPS_CGROUP_ROOT/machine/cpu.weight")" = 900 ]
  [ "$(cat "$HPS_CGROUP_ROOT/machine/io.weight")" = "default 900" ]
  [ "$(cat "$HPS_CGROUP_ROOT/machine/memory.max")" = 2147483648 ]
  grep -q '+memory' "$HPS_CGROUP_ROOT/cgroup.subtree_control"
  PATH="$TEST_DIR/bin:$PATH" run "$s" show machine.slice -p AllowedCPUs -p CPUWeight -p IOWeight -p MemoryMax
  [ "$output" = "$(printf 'AllowedCPUs=2-7\nCPUWeight=900\nIOWeight=900\nMemoryMax=2147483648')" ]
  # another unit, or a property it does not know, is refused and says so
  PATH="$TEST_DIR/bin:$PATH" run "$s" set-property foo.slice CPUWeight=1
  [ "$status" -eq 1 ]
  PATH="$TEST_DIR/bin:$PATH" run "$s" set-property machine.slice Nice=1
  [ "$status" -eq 1 ]
}

@test "the host reserve on Alpine: the role mounts cgroup v2 (rc-service cgroups) when it is not there" {
  export HPS_CGROUP_ROOT="$TEST_DIR/cg-none"
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  grep -qx 'rc-service cgroups start' "$CALLS"
  [[ "$output" == *"cgroup v2 is not mounted"* ]]
}

@test "node-journal on Alpine: the bundle's journalctl reads syslog, with the arguments node-journal passes, for a unit and a priority" {
  run bash "$TEST_DIR/bundle/init" boot
  export HPS_SYSLOG_FILE="$TEST_DIR/messages"
  cat > "$HPS_SYSLOG_FILE" <<'LOG'
Nov 16 21:00:00 sch-002 daemon.info libvirtd[212]: started
Nov 16 21:00:01 sch-002 daemon.err libvirtd[212]: failed thing
Nov 16 21:00:02 sch-002 kern.warning kernel: usb 1-1 reset
Nov 16 21:00:03 sch-002 daemon.debug iscsid: noise
Nov 16 21:00:04 sch-002 daemon.crit libvirtd[212]: very bad
LOG
  export PATH="$HPS_RUN_DIR/bin:$PATH"
  run bash "$ROOT/node-manager/nixos-26/scripts/node-journal" libvirtd --lines 10 --prio err
  ok0
  [[ "$output" == *"+ journalctl -b --no-pager -o short-monotonic -n 10 -u libvirtd.service -p err"* ]]
  [[ "$output" == *"failed thing"* && "$output" == *"very bad"* ]]
  [[ "$output" != *"started"* && "$output" != *"usb 1-1"* && "$output" != *"noise"* ]]
  run bash "$ROOT/node-manager/nixos-26/scripts/node-journal" --lines 2
  ok0
  [[ "$output" == *"noise"* && "$output" == *"very bad"* && "$output" != *"failed thing"* ]]
  rm "$HPS_SYSLOG_FILE"
  run bash "$ROOT/node-manager/nixos-26/scripts/node-journal"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not there (is syslog running?)"* ]]
}

@test "init, Alpine: when the IPS gives no package list the node says so, and what the IPS answered" {
  rm "$TEST_DIR/serve/packages"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"the IPS gave no package list for this node ("* ]]
  grep -q 'curl -sS --max-time 30 .*cmd=node_packages' "$CALLS"
}

@test "a service script's PATH keeps OpenRC's own helpers: ebegin, eend and mountinfo are in /usr/libexec/rc/bin (the first lab boot: 'ebegin: not found', three role steps failed)" {
  run bash "$TEST_DIR/bundle/init" boot
  ok0
  for s in hps-zfs-mount hps-shutdown-storage mdmonitor; do
    grep -q "^export PATH=.*:/usr/libexec/rc/bin:/usr/libexec/rc/sbin\$" "$HPS_OPENRC_DIR/$s" || { echo "$s lacks the helpers' directory"; return 1; }
  done
}

@test "the timedatectl of an ntpd node: show says whether ntpd runs (node-facts asks)" {
  run bash "$TEST_DIR/bundle/init" boot
  PATH="$TEST_DIR/bin:$PATH" run "$HPS_RUN_DIR/bin/timedatectl" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"NTPSynchronized=yes"* && "$output" == *"Timezone=UTC"* ]]
  rm -f "$TEST_DIR/svc/ntpd"
  PATH="$TEST_DIR/bin:$PATH" run "$HPS_RUN_DIR/bin/timedatectl" show
  [[ "$output" == *"NTPSynchronized=no"* ]]
}
