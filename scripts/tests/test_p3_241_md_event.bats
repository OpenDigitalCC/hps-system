#!/usr/bin/env bats
#
# hps-md-event: the mdadm monitor's PROGRAM on compute nodes. One structured
# "HPS-ISSUE open|resolve kind=mirror-leg ..." line (logger -t hps-issue) for
# the events that open or close a mirror-leg issue; the IPS issue watcher
# parses this exact format. Shims: logger, iscsiadm, mdadm.

bats_require_minimum_version 1.5.0
load p2_30_helpers

IQN="iqn.2026-01.hps.example:vm1-disk0"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-241.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  EV="$ROOT/node-manager/nixos-26/boot/hps-md-event.sh"
  COMPUTE="$ROOT/nix/modules/profiles/compute.nix"
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_SYS="$TEST_DIR/sys"
  export HPS_HOSTNAME_FILE="$TEST_DIR/hostname"
  echo "tch-001.lab.example" > "$HPS_HOSTNAME_FILE"
  mkdir -p "$HPS_DEV/md" "$HPS_SYS/block/md127/md"
  : > "$HPS_DEV/md127"
  : > "$HPS_DEV/sdc"
  ln -s ../md127 "$HPS_DEV/md/vm1-disk0"
  echo 1 > "$HPS_SYS/block/md127/md/degraded"
  cat > "$TEST_DIR/bin/logger" <<'SHIM'
#!/usr/bin/env bash
echo "logger $*" >> "$SHIM_LOG"
exit "${FAKE_LOGGER_RC:-0}"
SHIM
  cat > "$TEST_DIR/bin/iscsiadm" <<'SHIM'
#!/usr/bin/env bash
echo "iscsiadm $*" >> "$SHIM_LOG"
[[ -e "$STATE/p3" ]] || exit 21
cat "$STATE/p3"
SHIM
  cat > "$TEST_DIR/bin/mdadm" <<'SHIM'
#!/usr/bin/env bash
echo "mdadm $*" >> "$SHIM_LOG"
[[ -e "$STATE/detail" ]] || exit 1
cat "$STATE/detail"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

# iscsiadm -m session -P3 as open-iscsi prints it: sdb on another target, sdc
# on the leg's target.
p241_sessions() {
  cat > "$STATE/p3" <<P3
iSCSI Transport Class version 2.0-870
version 2.1.13
Target: iqn.2026-01.hps.example:other (non-flash)
	Current Portal: 10.99.1.3:3260,1
	Persistent Portal: 10.99.1.3:3260,1
		**********
		Interface:
		**********
		Iface Name: default
		SID: 1
		iSCSI Connection State: LOGGED IN
		iSCSI Session State: LOGGED_IN
		************************
		Attached SCSI devices:
		************************
		Host Number: 3	State: running
		scsi3 Channel 00 Id 0 Lun: 0
			Attached scsi disk sdb		State: running
Target: $IQN (non-flash)
	Current Portal: 10.99.1.2:3260,1
	Persistent Portal: 10.99.1.2:3260,1
		**********
		Interface:
		**********
		SID: 2
		iSCSI Connection State: TRANSPORT WAIT
		iSCSI Session State: FAILED
		************************
		Attached SCSI devices:
		************************
		Host Number: 4	State: running
		scsi4 Channel 00 Id 0 Lun: 0
			Attached scsi disk sdc		State: running
P3
}

# the message logger was given (everything after "-t hps-issue --")
p241_line() {
  sed -n 's/^logger -t hps-issue -- //p' "$SHIM_LOG"
}

@test "is executable, env shebang, shellcheck clean; not a ctrl-exec script" {
  [ -x "$EV" ]
  [ "$(head -1 "$EV")" = "#!/usr/bin/env bash" ]
  shellcheck -S warning "$EV"
  run ! grep -q 'hps-md-event' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  [ ! -e "$ROOT/node-manager/nixos-26/scripts/hps-md-event" ]
}

@test "Fail on an iSCSI leg: one open line with the leg, tag hps-issue" {
  p241_sessions
  run bash "$EV" Fail /dev/md/vm1-disk0 "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^logger' "$SHIM_LOG")" -eq 1 ]
  grep -q '^logger -t hps-issue -- ' "$SHIM_LOG"
  [ "$(p241_line)" = "HPS-ISSUE open kind=mirror-leg host=tch-001 mirror=vm1-disk0 component=$HPS_DEV/sdc event=Fail leg=$IQN@10.99.1.2:3260" ]
}

@test "FailSpare: open line; a component that is no iSCSI disk has no leg=" {
  p241_sessions
  : > "$HPS_DEV/zd16"
  run bash "$EV" FailSpare /dev/md/vm1-disk0 "$HPS_DEV/zd16"
  [ "$status" -eq 0 ]
  [ "$(p241_line)" = "HPS-ISSUE open kind=mirror-leg host=tch-001 mirror=vm1-disk0 component=$HPS_DEV/zd16 event=FailSpare" ]
}

@test "no iSCSI session at all: open line without leg=" {
  run bash "$EV" Fail /dev/md/vm1-disk0 "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  [ "$(p241_line)" = "HPS-ISSUE open kind=mirror-leg host=tch-001 mirror=vm1-disk0 component=$HPS_DEV/sdc event=Fail" ]
}

@test "DegradedArray (no component): component=-, no iSCSI lookup" {
  run bash "$EV" DegradedArray /dev/md/vm1-disk0
  [ "$status" -eq 0 ]
  [ "$(p241_line)" = "HPS-ISSUE open kind=mirror-leg host=tch-001 mirror=vm1-disk0 component=- event=DegradedArray" ]
  run ! grep '^iscsiadm' "$SHIM_LOG"
}

@test "an md device named /dev/mdX: the mirror name comes from its /dev/md/<name> link" {
  run bash "$EV" Fail "$HPS_DEV/md127" "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  [[ "$(p241_line)" == *" mirror=vm1-disk0 "* ]]
  run ! grep '^mdadm' "$SHIM_LOG"
}

@test "no /dev/md link: the Name of mdadm --detail, without its host: prefix" {
  rm "$HPS_DEV/md/vm1-disk0"
  printf '           Version : 1.2\n              Name : tch-001:vm1-disk0  (local to host tch-001)\n' > "$STATE/detail"
  run bash "$EV" Fail "$HPS_DEV/md127" "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  [[ "$(p241_line)" == *" mirror=vm1-disk0 "* ]]
  grep -qxF "mdadm --detail $HPS_DEV/md127" "$SHIM_LOG"
}

@test "nothing names the array: the kernel name stands in" {
  rm "$HPS_DEV/md/vm1-disk0"
  run bash "$EV" DegradedArray "$HPS_DEV/md127"
  [ "$status" -eq 0 ]
  [[ "$(p241_line)" == *" mirror=md127 "* ]]
}

@test "RebuildFinished on a clean array: one resolve line" {
  echo 0 > "$HPS_SYS/block/md127/md/degraded"
  run bash "$EV" RebuildFinished /dev/md/vm1-disk0
  [ "$status" -eq 0 ]
  [ "$(p241_line)" = "HPS-ISSUE resolve kind=mirror-leg host=tch-001 mirror=vm1-disk0 event=RebuildFinished" ]
}

@test "SpareActive and RecoveryFinished on a clean array resolve too (no component in the line)" {
  echo 0 > "$HPS_SYS/block/md127/md/degraded"
  run bash "$EV" SpareActive "$HPS_DEV/md127" "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  run bash "$EV" RecoveryFinished /dev/md/vm1-disk0
  [ "$status" -eq 0 ]
  [ "$(p241_line | sed -n 1p)" = "HPS-ISSUE resolve kind=mirror-leg host=tch-001 mirror=vm1-disk0 event=SpareActive" ]
  [ "$(p241_line | sed -n 2p)" = "HPS-ISSUE resolve kind=mirror-leg host=tch-001 mirror=vm1-disk0 event=RecoveryFinished" ]
}

@test "a finished rebuild on a still degraded array (or unreadable degraded) writes nothing" {
  run bash "$EV" RebuildFinished /dev/md/vm1-disk0
  [ "$status" -eq 0 ]
  rm "$HPS_SYS/block/md127/md/degraded"
  run bash "$EV" SpareActive /dev/md/vm1-disk0 "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  run ! grep '^logger' "$SHIM_LOG"
}

@test "other events write no marker" {
  local e
  for e in NewArray DeviceDisappeared RebuildStarted Rebuild20 SparesMissing MoveSpare TestMessage ""; do
    run bash "$EV" "$e" /dev/md/vm1-disk0 "$HPS_DEV/sdc"
    [ "$status" -eq 0 ]
  done
  run ! grep '^logger' "$SHIM_LOG"
}

@test "always exits 0: logger failing, no arguments" {
  FAKE_LOGGER_RC=1 run bash "$EV" Fail /dev/md/vm1-disk0 "$HPS_DEV/sdc"
  [ "$status" -eq 0 ]
  run bash "$EV"
  [ "$status" -eq 0 ]
}

@test "the line carries no secret-shaped word" {
  p241_sessions
  run bash "$EV" Fail /dev/md/vm1-disk0 "$HPS_DEV/sdc"
  run ! grep -iE 'password|secret|chap|token|key=' <(p241_line)
}

@test "compute profile: mdadm PROGRAM is /etc/hps/hps-md-event, a wrapper with the tools on PATH" {
  grep -q 'PROGRAM /etc/hps/hps-md-event' "$COMPUTE"
  run ! grep -E '^[^#]*PROGRAM \$\{pkgs.coreutils\}/bin/true' "$COMPUTE"
  grep -q 'environment.etc."hps/hps-md-event".source = mdEvent;' "$COMPUTE"
  grep -q 'mdEvent = pkgs.writeShellScript "hps-md-event"' "$COMPUTE"
  grep -q 'node-manager/nixos-26/boot/hps-md-event.sh' "$COMPUTE"
  local p
  p=$(grep 'export PATH=' "$COMPUTE")
  for t in coreutils gnused util-linux mdadm openiscsi; do
    [[ "$p" == *"pkgs.$t"* ]]
  done
}
