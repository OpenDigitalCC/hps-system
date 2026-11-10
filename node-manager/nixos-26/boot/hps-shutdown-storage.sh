#!/usr/bin/env bash
#
# hps-shutdown-storage - quiesce this node's storage before it powers off.
#
# Runs as the ExecStop of hps-shutdown-storage.service, so it runs on every
# poweroff or reboot however it was asked for (ACPI power button, `systemctl
# poweroff`, node-poweroff over ctrl-exec): after the unit's After= targets
# are still up (libvirt, the network, the iSCSI initiator, the log forwarder)
# and before they are stopped. Order, each step bounded by a timeout and logged
# when it is hit:
#   1. running guests    vm-stop <vm> --timeout N --force   (clean ACPI first)
#   2. md mirrors        mirror-stop <name>                 (each sidecar)
#   3. iSCSI targets     iscsi-unexport <iqn>               (each target)
#   4. iSCSI sessions    iscsiadm -m node --logoutall=all
#   5. ZFS pools         zpool export <pool>                (each imported pool)
# The node scripts of ctrl-exec are reused from HPS_SCRIPTS_DIR. A step that
# fails or times out is logged as a fault and the sequence goes on: a node that
# was asked to power off must not hang here. Exit 0 when every step was clean,
# 1 otherwise (the shutdown proceeds either way).
#
# Test hooks: HPS_SCRIPTS_DIR (default /opt/ctrl-exec-scripts), HPS_MIRROR_DIR
# (default /run/hps/mirrors), HPS_CONFIGFS_ISCSI (default
# /sys/kernel/config/target/iscsi), HPS_SHUTDOWN_STEP_TIMEOUT (per command,
# default 60 s), HPS_SHUTDOWN_GUEST_TIMEOUT (clean-stop wait per guest,
# default 60 s).

set -euo pipefail

: "${HPS_SCRIPTS_DIR:=/opt/ctrl-exec-scripts}"
: "${HPS_MIRROR_DIR:=/run/hps/mirrors}"
: "${HPS_CONFIGFS_ISCSI:=/sys/kernel/config/target/iscsi}"
: "${HPS_SHUTDOWN_STEP_TIMEOUT:=60}"
: "${HPS_SHUTDOWN_GUEST_TIMEOUT:=60}"

# The system profile is where virsh, mdadm, zpool and iscsiadm live on NixOS.
PATH="$PATH:/run/wrappers/bin:/run/current-system/sw/bin"

FAULTS=0

log() {
  printf '[hps-shutdown-storage] %s\n' "$*" >&2
}

fault() {
  log "FAULT: $*"
  FAULTS=$((FAULTS + 1))
}

# bounded <seconds> <command...>: log, run with a timeout, return its status.
# Status 124 (timeout) is logged as such.
bounded() {
  local secs=$1 rc=0
  shift
  printf '+ timeout %s %s\n' "$secs" "$*" >&2
  timeout "$secs" "$@" || rc=$?
  if [[ "$rc" -eq 124 ]]; then
    log "timeout after $secs s: $*"
  fi
  return "$rc"
}

# stop_guests: every running libvirt guest, clean stop then forced after the timeout.
stop_guests() {
  local vms vm budget
  if ! command -v virsh > /dev/null 2>&1; then
    log "no virsh on this node: no guests to stop"
    return 0
  fi
  if ! vms=$(timeout "$HPS_SHUTDOWN_STEP_TIMEOUT" virsh -c qemu:///system list --name 2> /dev/null); then
    log "virsh list failed or timed out: assuming no running guests"
    return 0
  fi
  budget=$((HPS_SHUTDOWN_GUEST_TIMEOUT + HPS_SHUTDOWN_STEP_TIMEOUT))
  for vm in $vms; do
    log "stopping guest $vm"
    bounded "$budget" "$HPS_SCRIPTS_DIR/vm-stop" "$vm" --timeout "$HPS_SHUTDOWN_GUEST_TIMEOUT" --force \
      || fault "guest $vm did not stop"
  done
}

# stop_mirrors: every mirror HPS assembled (one sidecar each).
stop_mirrors() {
  local f name
  for f in "$HPS_MIRROR_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    name=$(basename "$f" .json)
    log "stopping mirror $name"
    bounded "$HPS_SHUTDOWN_STEP_TIMEOUT" "$HPS_SCRIPTS_DIR/mirror-stop" "$name" \
      || fault "mirror $name did not stop"
  done
}

# unexport_targets: every iSCSI target this node serves (a zvol under a target
# is busy and would stop its pool exporting).
unexport_targets() {
  local d iqn
  for d in "$HPS_CONFIGFS_ISCSI"/iqn.*; do
    [[ -e "$d" ]] || continue
    iqn=$(basename "$d")
    log "removing iSCSI target $iqn"
    bounded "$HPS_SHUTDOWN_STEP_TIMEOUT" "$HPS_SCRIPTS_DIR/iscsi-unexport" "$iqn" \
      || fault "target $iqn was not removed"
  done
}

# logout_sessions: every iSCSI initiator session (mirror legs held on peers).
logout_sessions() {
  local rc=0
  if ! command -v iscsiadm > /dev/null 2>&1; then
    log "no iscsiadm on this node: no sessions to log out"
    return 0
  fi
  bounded "$HPS_SHUTDOWN_STEP_TIMEOUT" iscsiadm -m node --logoutall=all || rc=$?
  # 21: no matching sessions, nothing to do
  if [[ "$rc" -ne 0 && "$rc" -ne 21 ]]; then
    fault "iSCSI logout exited $rc"
  fi
}

# export_pools: every imported ZFS pool.
export_pools() {
  local pools pool
  if ! command -v zpool > /dev/null 2>&1; then
    log "no zpool on this node: no pools to export"
    return 0
  fi
  if ! pools=$(timeout "$HPS_SHUTDOWN_STEP_TIMEOUT" zpool list -H -o name 2> /dev/null); then
    log "zpool list failed or timed out: cannot tell which pools are imported"
    fault "pool list unavailable"
    return 0
  fi
  for pool in $pools; do
    log "exporting pool $pool"
    bounded "$HPS_SHUTDOWN_STEP_TIMEOUT" zpool export "$pool" || fault "pool $pool was not exported"
  done
}

main() {
  log "begin: guests, mirrors, iSCSI targets and sessions, pools"
  stop_guests
  stop_mirrors
  unexport_targets
  logout_sessions
  export_pools
  if [[ "$FAULTS" -eq 0 ]]; then
    log "done: storage quiesced"
    return 0
  fi
  log "done with $FAULTS fault(s); powering off anyway"
  return 1
}

main "$@"
