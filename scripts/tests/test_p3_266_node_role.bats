#!/usr/bin/env bats
#
# Plan step 3 (node-manager/bundle/role, docs/BUNDLE.md "Storage and compute"):
# what the bundle's init does for a storage (SCH) and a compute (TCH) node, run
# against shims of curl, systemctl, modprobe and the rest, with the bundle the IPS
# really builds and the node scripts of the tree. No network, no root.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-266.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TEST_DIR ROOT
  export AGENT_V1=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ctrl-exec-agent-0.14.7
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_ROOT="$TEST_DIR/root"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_NIX_PROFILE="$TEST_DIR/profile"
  export HPS_SYSTEMD_DIR="$TEST_DIR/systemd"
  export HPS_PATH_EXTRA="$TEST_DIR/bin"
  export HPS_CPUINFO="$TEST_DIR/cpuinfo"
  export HPS_FETCH_RETRY=0
  export HPS_SYSTEMD_RUN="$TEST_DIR/bin/systemd-run"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/serve" "$TEST_DIR/home/sysadmin" "$HPS_ROOT/etc/ssh" "$HPS_NIX_PROFILE/bin" "$HPS_NIX_PROFILE/sbin"
  echo "BOOT_IMAGE=bzImage console=ttyS0 hps.ips=10.9.9.9 hps.mac=aa:bb:cc:dd:ee:ff hps.os=x86_64:nixos:26.05 hps.profile=STARTER hps.domain=lab.test" > "$HPS_CMDLINE"
  printf 'vendor_id\t: GenuineIntel\n' > "$HPS_CPUINFO"
  printf '# the starter\nPermitRootLogin yes\n' > "$HPS_ROOT/etc/ssh/sshd_config"
  shims
  programs
  source "$ROOT/lib/functions.d/node-bundle-functions.sh"
  hps_log() { :; }
  node_bundle_tar "$ROOT" > "$TEST_DIR/serve/bundle.tgz"
  export HPS_AGENT_FS="$TEST_DIR/agentpkg"
  mkdir -p "$HPS_AGENT_FS/bin"
  printf '#!/bin/sh\necho "ctrl-exec-agent 0.14.7"\n' > "$HPS_AGENT_FS/bin/ctrl-exec-agent"
  printf '#!/bin/sh\n' > "$HPS_AGENT_FS/bin/ctrl-exec-executor"
  chmod +x "$HPS_AGENT_FS"/bin/*
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 admin@site' > "$TEST_DIR/serve/keys"
  printf '%s\n' "$AGENT_V1" > "$TEST_DIR/serve/packages"
  echo "SCH,TCH" > "$TEST_DIR/serve/type"
  extract_bundle
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
  *.narinfo) printf 'StorePath: x\n' ;;
  *cmd=log_message*) exit 0 ;;
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
  cat > "$b/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$CALLS"
touch "$TEST_DIR/user-${!#}"
EOF
  cat > "$b/groupadd" <<'EOF'
#!/bin/bash
echo "groupadd $*" >> "$CALLS"
touch "$TEST_DIR/group-${!#}"
EOF
  cat > "$b/install" <<'EOF'
#!/bin/bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
/usr/bin/install "${args[@]}"
EOF
  cat > "$b/hostname" <<'EOS'
#!/bin/bash
if [[ $# -gt 0 ]]; then printf '%s\n' "$1" > "$TEST_DIR/khost"; else cat "$TEST_DIR/khost" 2> /dev/null || echo nixos; fi
EOS
  for s in usermod chown chgrp passwd systemctl iptables sshd modprobe; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n[[ "%s" == iptables && "$1" == -C ]] && exit 1\n[[ "%s" == modprobe && -n "${FAIL_MODPROBE:-}" && "$1" == "$FAIL_MODPROBE" ]] && exit 1\nexit 0\n' "$s" "$s" "$s" > "$b/$s"
  done
  cat > "$b/nix" <<'EOF'
#!/bin/bash
echo "nix $*" >> "$CALLS"
for a in "$@"; do [[ "$a" == /nix/store/* ]] && echo "$a" >> "$HPS_NIX_PROFILE/manifest.json"; done
exit 0
EOF
  printf '#!/bin/bash\necho "nix-store $*" >> "$CALLS"\n' > "$b/nix-store"
  printf '#!/bin/bash\necho "systemd-run $*" >> "$CALLS"\n' > "$b/systemd-run"
  # the pairing, the hostname it sets, and the actions run once at boot are stand-ins here:
  # each has its own tests (test_p1_102, test_p3_*), this file is about what init does around them
  cat > "$TEST_DIR/hps-pair-stub" <<'EOF'
#!/bin/bash
echo "hps-pair $*" >> "$CALLS"
hostname sch-001.lab.test
exit "${PAIR_RC:-0}"
EOF
  chmod +x "$b"/* "$TEST_DIR/hps-pair-stub"
}

# programs: the packages' programs, as the profile and the packages' own store paths would have them
programs() {
  local p
  for p in virsh qemu-img tcpdump jq mdadm targetcli smartctl xxd om zpool zfs; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$p" > "$HPS_NIX_PROFILE/bin/$p"
  done
  mkdir -p "$TEST_DIR/qemu/bin" "$TEST_DIR/qemu/share/qemu" "$TEST_DIR/iscsi/sbin" "$TEST_DIR/iscsi/etc/iscsi"
  printf '#!/bin/bash\n' > "$TEST_DIR/qemu/bin/qemu-system-x86_64"
  touch "$TEST_DIR/qemu/share/qemu/edk2-x86_64-code.fd" "$TEST_DIR/qemu/share/qemu/edk2-i386-vars.fd" "$TEST_DIR/qemu/share/qemu/edk2-licenses.txt"
  ln -s "$TEST_DIR/qemu/bin/qemu-system-x86_64" "$HPS_NIX_PROFILE/bin/qemu-system-x86_64"
  printf '# the package iscsid.conf\nnode.startup = manual\nnode.session.timeo.replacement_timeout = 120\n' > "$TEST_DIR/iscsi/etc/iscsi/iscsid.conf"
  printf '#!/bin/bash\n' > "$TEST_DIR/iscsi/sbin/iscsid"
  printf '#!/bin/bash\n' > "$TEST_DIR/iscsi/sbin/iscsiadm"
  ln -s "$TEST_DIR/iscsi/sbin/iscsid" "$HPS_NIX_PROFILE/sbin/iscsid"
  ln -s "$TEST_DIR/iscsi/sbin/iscsiadm" "$HPS_NIX_PROFILE/sbin/iscsiadm"
  for p in libvirtd rsyslogd; do
    printf '#!/bin/bash\n' > "$HPS_NIX_PROFILE/sbin/$p"
  done
  chmod +x "$HPS_NIX_PROFILE"/bin/* "$HPS_NIX_PROFILE"/sbin/* "$TEST_DIR"/qemu/bin/* "$TEST_DIR"/iscsi/sbin/*
}

# extract_bundle: the bundle the IPS built, with stand-ins for the pairing and for the
# scripts that talk to the IPS for their own purposes
extract_bundle() {
  mkdir -p "$TEST_DIR/bundle"
  tar -xzf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/bundle"
  cp "$TEST_DIR/hps-pair-stub" "$TEST_DIR/bundle/lib/hps-pair"
  local s
  for s in lib/hps-time lib/hps-log-target actions/host-reserve-apply actions/net-bridge-ensure; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "${s##*/}" > "$TEST_DIR/bundle/$s"
  done
  # the initiator name is the FQDN that pairing set
  printf '#!/bin/bash\necho "hps-iscsi-name $(hostname)" >> "$CALLS"\nmkdir -p "$HPS_RUN_DIR"\necho InitiatorName=iqn.test > "$HPS_RUN_DIR/initiatorname.iscsi"\n' > "$TEST_DIR/bundle/lib/hps-iscsi-name"
}

unit() { cat "$HPS_SYSTEMD_DIR/$1.service"; }

# --- the bundle carries it ----------------------------------------------------

@test "the bundle carries the role file and the boot scripts the pinned images run as units" {
  tar -xzf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR" ./role lib
  for f in role lib/hps-time lib/hps-log-target lib/hps-iscsi-name lib/hps-osvc-config lib/hps-md-event lib/hps-shutdown-storage lib/hps-pair; do
    [ -f "$TEST_DIR/$f" ] || { echo "no $f"; return 1; }
  done
  [ -x "$TEST_DIR/lib/hps-md-event" ]
  # the same file as in the tree: nothing forked
  cmp "$TEST_DIR/lib/hps-md-event" "$ROOT/node-manager/nixos-26/boot/hps-md-event.sh"
  cmp "$TEST_DIR/lib/hps-shutdown-storage" "$ROOT/node-manager/nixos-26/boot/hps-shutdown-storage.sh"
}

@test "every action the starter node may run is a file of the bundle, including the waiting fixes" {
  for n in vm-resume vm-save vm-restore mirror-stop mirror-detach-leg leg-resolve host-reserve-apply osvc-secret-set; do
    grep -q "^$n " "$ROOT/node-manager/bundle/allowlist" || { echo "$n not in the allowlist"; return 1; }
    [ -x "$ROOT/node-manager/bundle/../nixos-26/scripts/$n" ] || { echo "no script $n"; return 1; }
  done
}

# --- a storage and compute node -----------------------------------------------

@test "init, SCH and TCH: role services are started before pairing, the initiator after it" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"role: SCH,TCH"* ]]
  [[ "$output" == *"done: bundle"* ]]
  ln() { grep -nE "$1" "$CALLS" | head -1 | cut -d: -f1; }
  pair="$(ln '^hps-pair')"
  for u in hps-rsyslog hps-mdmonitor libvirtd opensvc-daemon hps-shutdown-storage; do
    [ "$(ln "^systemctl start $u.service")" -lt "$pair" ] || { echo "$u not before pairing"; return 1; }
  done
  [ "$(ln '^systemctl start iscsid.service')" -gt "$pair" ]
  [ "$(ln '^hps-iscsi-name')" -gt "$pair" ]
  # the name is the FQDN pairing set
  grep -qx 'hps-iscsi-name sch-001.lab.test' "$CALLS"
  # clock, reserve and bridges first, then the services
  [ "$(ln '^hps-time')" -lt "$(ln '^systemctl start hps-rsyslog')" ]
  [ "$(ln '^host-reserve-apply')" -lt "$pair" ]
  [ "$(ln '^net-bridge-ensure')" -lt "$pair" ]
}

@test "init: the registry TYPE is what decides; the node does not guess a role" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  grep -q 'cmd=host_variable&name=TYPE' "$CALLS"
  rm "$TEST_DIR/serve/type"
  : > "$CALLS"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"neither SCH nor TCH"* ]]
  ! grep -q 'systemctl start libvirtd' "$CALLS"
  ! grep -q '^modprobe' "$CALLS"
}

@test "init: a CNH or any other type gets the agent and nothing of storage or compute" {
  echo CNH > "$TEST_DIR/serve/type"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  ! grep -qE 'systemctl start (libvirtd|iscsid|opensvc|hps-rsyslog|hps-mdmonitor)' "$CALLS"
  [ ! -e "$HPS_SYSTEMD_DIR/libvirtd.service" ]
}

@test "compute: libvirt is configured as compute.nix does, except AppArmor, with the firmware where vm-define looks" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  q="$HPS_ROOT/var/lib/libvirt/qemu.conf"
  for l in 'user = "qemu-libvirtd"' 'group = "qemu-libvirtd"' 'namespaces = []' 'seccomp_sandbox = 1' 'clear_emulator_capabilities = 1' \
    'dynamic_ownership = 1' 'allow_disk_format_probing = 0' 'security_default_confined = 1' 'security_require_confined = 0'; do
    grep -qxF "$l" "$q" || { echo "qemu.conf lacks: $l"; return 1; }
  done
  # no AppArmor in the starter's kernel: libvirtd would refuse to start with that driver
  ! grep -q 'security_driver' "$q"
  grep -q 'security_driver = "apparmor"' "$ROOT/nix/modules/profiles/compute.nix"
  # the qemu.conf of the pinned image has the other settings too: none is lost
  for k in $(grep -oE '^ +[a-z_]+ = ' "$ROOT/nix/modules/profiles/compute.nix" | sed -n '/namespaces/,/security_driver/p' | tr -d ' =' | grep -v security_driver); do
    grep -q "^$k = " "$q" || { echo "qemu.conf lacks the setting $k of compute.nix"; return 1; }
  done
  # the guests' firmware: the files of the QEMU package, linked where vm-define reads them
  [ -L "$HPS_ROOT/run/libvirt/nix-ovmf/edk2-x86_64-code.fd" ]
  [ -L "$HPS_ROOT/run/libvirt/nix-ovmf/edk2-i386-vars.fd" ]
  [ "$(readlink "$HPS_ROOT/run/libvirt/nix-ovmf/edk2-x86_64-code.fd")" = "$TEST_DIR/qemu/share/qemu/edk2-x86_64-code.fd" ]
  grep -q 'HPS_OVMF_CODE:=/run/libvirt/nix-ovmf/edk2-x86_64-code.fd' "$ROOT/node-manager/nixos-26/scripts/vm-define"
  # the unprivileged qemu user, in the kvm group
  grep -q '^useradd --system --no-create-home --gid qemu-libvirtd --groups kvm .* qemu-libvirtd' "$CALLS"
  # KVM: the vendor's module, and the modules the bridges and the mirrors need
  grep -qx 'modprobe kvm_intel' "$CALLS"
  ! grep -qx 'modprobe kvm_amd' "$CALLS"
  for m in vhost_net 8021q bridge raid1 iscsi_tcp; do grep -qx "modprobe $m" "$CALLS" || { echo "no modprobe $m"; return 1; }; done
}

@test "compute: an AMD host gets kvm_amd" {
  printf 'vendor_id\t: AuthenticAMD\n' > "$HPS_CPUINFO"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  grep -qx 'modprobe kvm_amd' "$CALLS"
  ! grep -qx 'modprobe kvm_intel' "$CALLS"
}

@test "compute: libvirtd is a unit of its own that leaves the guests running when it stops, run as the node bundle's service" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  unit libvirtd | grep -qx "ExecStart=$HPS_NIX_PROFILE/sbin/libvirtd"
  unit libvirtd | grep -qx 'KillMode=process'
  unit libvirtd | grep -q "^Environment=\"PATH=$HPS_NIX_PROFILE/bin:$HPS_NIX_PROFILE/sbin:"
}

@test "compute: md assembles nothing by itself, and its monitor reports through hps-md-event (the iscsi-failfast settings)" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  grep -qx "PROGRAM $HPS_RUN_DIR/bundle/lib/hps-md-event" "$HPS_ROOT/etc/mdadm.conf"
  grep -qx 'AUTO -all' "$HPS_ROOT/etc/mdadm.conf"
  # compute.nix says the same
  grep -q 'PROGRAM /etc/hps/hps-md-event' "$ROOT/nix/modules/profiles/compute.nix"
  grep -q '^AUTO -all\|^      AUTO -all' "$ROOT/nix/modules/profiles/compute.nix"
  unit hps-mdmonitor | grep -q "^ExecStart=$HPS_NIX_PROFILE/bin/mdadm --monitor --scan --config=$HPS_ROOT/etc/mdadm.conf"
  unit hps-mdmonitor | grep -qx 'Restart=always'
  # the degraded-start timers are off for this boot
  [ "$(readlink "$HPS_SYSTEMD_DIR/mdadm-last-resort@.timer")" = /dev/null ]
  [ "$(readlink "$HPS_SYSTEMD_DIR/mdadm-last-resort@.service")" = /dev/null ]
}

@test "compute: the iSCSI initiator has the package's configuration and the fail-fast timeouts, the same as leg-resolve writes" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  c="$HPS_ROOT/etc/iscsi/iscsid.conf"
  grep -qx 'node.startup = manual' "$c"
  # the four values, the later line winning over the package's 120
  [ "$(grep -c 'replacement_timeout' "$c")" -eq 2 ]
  [ "$(tail -n 5 "$c" | grep 'replacement_timeout')" = 'node.session.timeo.replacement_timeout = 15' ]
  for kv in $(sed -n '/^ISCSI_TIMEOUTS=(/,/^)/p' "$ROOT/node-manager/nixos-26/scripts/leg-resolve" | grep -oE '"[^"]+"' | tr -d '"'); do
    grep -qxF "${kv%%=*} = ${kv#*=}" "$c" || { echo "iscsid.conf lacks ${kv}"; return 1; }
  done
  [ -L "$HPS_ROOT/etc/iscsi/initiatorname.iscsi" ]
  [ "$(readlink "$HPS_ROOT/etc/iscsi/initiatorname.iscsi")" = "$HPS_RUN_DIR/initiatorname.iscsi" ]
  unit iscsid | grep -qx "ExecStart=$HPS_NIX_PROFILE/sbin/iscsid -f --config=$c"
  unit iscsid | grep -qx 'KillMode=process'
  [ -d "$HPS_ROOT/var/lib/iscsi" ]
}

@test "storage: the target directory, the portal in the firewall, the programs the scripts call" {
  echo SCH > "$TEST_DIR/serve/type"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [ -d "$HPS_ROOT/etc/target" ]
  grep -qx 'iptables -I nixos-fw 1 -p tcp --dport 3260 -j nixos-fw-accept' "$CALLS"
  grep -qx 'modprobe zfs' "$CALLS"
  grep -qx 'modprobe iscsi_target_mod' "$CALLS"
  # a storage node has no libvirt, no initiator, no md monitor
  [ ! -e "$HPS_SYSTEMD_DIR/libvirtd.service" ]
  [ ! -e "$HPS_SYSTEMD_DIR/iscsid.service" ]
  [ ! -e "$HPS_SYSTEMD_DIR/hps-mdmonitor.service" ]
  ! grep -q '^modprobe kvm' "$CALLS"
}

@test "compute only: no target directory and no portal" {
  echo TCH > "$TEST_DIR/serve/type"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [ ! -e "$HPS_ROOT/etc/target" ]
  ! grep -q 'dport 3260' "$CALLS"
}

@test "om3: its unit waits for the cluster secret, is restarted by osvc-secret-set under that name, ports 1215 and 10000" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  u="$(unit opensvc-daemon)"
  [[ "$u" == *"ConditionPathExists=$HPS_RUN_DIR/osvc-cluster-secret"* ]]
  [[ "$u" == *"StartLimitIntervalSec=0"* ]]
  [[ "$u" == *"EnvironmentFile=-$HPS_RUN_DIR/opensvc.env"* ]]
  [[ "$u" == *"ExecStart=$HPS_NIX_PROFILE/bin/om daemon run \$OSVC_DAEMON_ARGS"* ]]
  [[ "$u" == *"ExecStartPre="*"$HPS_RUN_DIR/bundle/lib/hps-osvc-config"* ]]
  [[ "$u" == *"WorkingDirectory=/var/lib/opensvc"* ]]
  [[ "$u" == *"HOME=/var/lib/opensvc"* ]]
  [[ "$u" == *"Restart=always"* ]]
  # the [Unit] options are in [Unit], the rest in [Service]
  [ "$(printf '%s\n' "$u" | sed -n '/^\[Unit\]/,/^\[Service\]/p' | grep -c StartLimitIntervalSec)" -eq 1 ]
  grep -q 'systemctl restart opensvc-daemon.service' "$ROOT/node-manager/nixos-26/scripts/osvc-secret-set"
  grep -qx 'iptables -I nixos-fw 1 -p tcp --dport 1215 -j nixos-fw-accept' "$CALLS"
  grep -qx 'iptables -I nixos-fw 1 -p tcp --dport 10000 -j nixos-fw-accept' "$CALLS"
  [ -d "$HPS_ROOT/etc/opensvc" ] && [ "$(stat -c %a "$HPS_ROOT/etc/opensvc")" = 700 ]
  grep -qx 'groupadd --system opensvc' "$CALLS"
}

@test "log forwarding: rsyslog reads the journal and sends it to the IPS through hps-log-target's file" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  c="$HPS_RUN_DIR/rsyslog.conf"
  grep -q 'module(load="imjournal"' "$c"
  grep -qF "include(file=\"$HPS_RUN_DIR/rsyslog-target.conf\" mode=\"optional\")" "$c"
  unit hps-rsyslog | grep -qx "ExecStart=$HPS_NIX_PROFILE/sbin/rsyslogd -n -f $c -i $HPS_RUN_DIR/rsyslogd.pid"
  grep -q '^hps-log-target' "$CALLS"
}

@test "power-off: the shutdown unit runs the bundle's script after the units it needs are still up, with the bundle's actions" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  u="$(unit hps-shutdown-storage)"
  [[ "$u" == *"Type=oneshot"* && "$u" == *"RemainAfterExit=yes"* && "$u" == *"TimeoutStopSec=300"* ]]
  [[ "$u" == *"ExecStop="*"$HPS_RUN_DIR/bundle/lib/hps-shutdown-storage"* ]]
  [[ "$u" == *"HPS_SCRIPTS_DIR=$HPS_RUN_DIR/bundle/actions"* ]]
  for dep in libvirtd.service iscsid.service ctrl-exec-agent.service hps-rsyslog.service network-online.target; do
    [[ "$(printf '%s\n' "$u" | grep '^After=' | tail -1)" == *"$dep"* ]] || { echo "not After=$dep"; return 1; }
  done
}

# --- failure and repeat ---------------------------------------------------------

@test "a failed role step is said, does not stop the pairing, and makes the exit 1 with its name" {
  rm "$HPS_NIX_PROFILE/bin/om"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"om (om3) is not installed"* ]]
  [[ "$output" == *"role step failed"* ]]
  [[ "$output" == *"a role step failed: om3"* ]]
  grep -q '^hps-pair' "$CALLS"
  # the rest of the role was done
  grep -q 'systemctl start libvirtd.service' "$CALLS"
  grep -q 'systemctl start iscsid.service' "$CALLS"
  grep -q 'message=error: role step failed: om3' "$CALLS"
}

@test "a package the role lacks is named, not found by the first action that needs it" {
  rm "$HPS_NIX_PROFILE/bin/xxd" "$HPS_NIX_PROFILE/bin/smartctl"
  echo SCH > "$TEST_DIR/serve/type"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing programs: smartctl xxd"* ]]
}

@test "a module the kernel does not have is said and does not fail the step" {
  FAIL_MODPROBE=target_core_iblock run bash -c "echo SCH > '$TEST_DIR/serve/type'; bash '$TEST_DIR/bundle/init' boot"
  [ "$status" -eq 0 ]
  [[ "$output" == *"module target_core_iblock not loaded"* ]]
}

@test "init run again (the refresh) changes nothing: the units are the same, nothing is restarted" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  cp -a "$HPS_SYSTEMD_DIR" "$TEST_DIR/units1"
  cp "$HPS_ROOT/var/lib/libvirt/qemu.conf" "$TEST_DIR/q1"
  : > "$CALLS"
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$status" -eq 0 ]
  diff -r "$TEST_DIR/units1" "$HPS_SYSTEMD_DIR"
  cmp "$TEST_DIR/q1" "$HPS_ROOT/var/lib/libvirt/qemu.conf"
  ! grep -qE 'systemctl (restart|try-restart)' "$CALLS"
  ! grep -q '^systemd-run' "$CALLS"
  # the accounts are not made twice
  ! grep -qE '^(useradd --system|groupadd)' "$CALLS"
}

@test "init: no secret is written for the role: no key, password or pool key in any file the role step writes" {
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  ! grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY|password *=|secret *=' "$HPS_SYSTEMD_DIR" "$HPS_ROOT/etc/iscsi" "$HPS_ROOT/etc/mdadm.conf" "$HPS_ROOT/var/lib/libvirt" "$HPS_RUN_DIR/rsyslog.conf"
}

# --- the sources agree -----------------------------------------------------------

@test "the roles and the package list agree: every name in a role line is a name of the package list" {
  names="$(sed 's/#.*//' "$ROOT/lib/starter/nixos.packages" | awk 'NF {print $1}' | sort -u)"
  for n in $(sed 's/#.*//' "$ROOT/lib/starter/nixos.roles" | awk -F: 'NF>1 {print $2}'); do
    printf '%s\n' "$names" | grep -qx "$n" || { echo "role names $n, not in the package list"; return 1; }
  done
}

@test "the new local package is om3, by store path, and nothing named by path is a guess: every path is one the lab's pinned images use" {
  grep -qE '^om3 /nix/store/[0-9a-z]{32}-om3-3\.0\.0-rc62$' "$ROOT/lib/starter/nixos.packages"
  # the flake pins the same tag
  grep -q 'v3.0.0-rc62' "$ROOT/flake.nix"
  # a package list line names a store path or a name, never both a path and a version search
  ! grep -E '^[a-z]' "$ROOT/lib/starter/nixos.packages" | grep -vE '^[A-Za-z0-9][A-Za-z0-9._+-]*( [a-z]+| /nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+)?$'
}

@test "the programs the storage and compute scripts call are all in the starter or in a role's packages" {
  # the programs a script calls that the starter (a NixOS installer image) does not have must come from a role line
  have="$(sed 's/#.*//' "$ROOT/lib/starter/nixos.packages" | awk 'NF {print $1}')"
  for want in "jq jq" "smartctl smartmontools" "xxd xxd" "tcpdump tcpdump" "targetcli targetcli-fb" "iscsiadm open-iscsi" "virsh libvirt" "qemu-img qemu-host-cpu-only" "om om3" "rsyslogd rsyslog" "mdadm mdadm"; do
    pkg="${want#* }"
    printf '%s\n' "$have" | grep -qx "$pkg" || { echo "no package $pkg for ${want%% *}"; return 1; }
  done
}
