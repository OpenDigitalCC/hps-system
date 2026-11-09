#!/usr/bin/env bash
#===============================================================================
# hps-iscsi-test.sh <target-ip> <target-iqn> [--initiator-name <iqn>]
# -------------------------------------------------------------------
# IPS-side proof that a node's iSCSI export works end to end, using open-iscsi
# in the IPS container: discover the target, log in, write a 4 MiB random
# pattern at offset 1 GiB - 8 MiB of the LUN, read it back and compare, log
# out. This is the ONLY place HPS writes to a LUN: the LUN is a test zvol
# (lab runsheet step 7), never a device holding data.
#
# --initiator-name <iqn>: the initiator name the target's ACL names. It is
# written to /etc/iscsi/initiatorname.iscsi when it differs from what is there
# (iscsid is restarted so it takes effect).
#
# Needs the HOST kernel's iscsi_tcp module: a container cannot load modules.
# The script checks /sys/module/iscsi_tcp and refuses with a clear message
# otherwise (on the host: modprobe iscsi_tcp). iscsid is started here when it
# is not running, and stopped again when this script started it.
#
# Output: one verdict line on stdout ("ISCSI TEST OK ..." or "ISCSI TEST
# FAILED: <why>"); every command is logged to stderr as "+ <command>".
# Environment (tests): HPS_ISCSI_SYS_MODULE, HPS_ISCSI_INITIATORNAME,
# HPS_ISCSI_BYPATH, HPS_ISCSI_LOGIN_WAIT (seconds, default 20).
# Exit: 0 verified, 2 usage, 3 the test failed.
#===============================================================================
set -euo pipefail

SYS_MODULE=${HPS_ISCSI_SYS_MODULE:-/sys/module/iscsi_tcp}
INITIATORNAME_FILE=${HPS_ISCSI_INITIATORNAME:-/etc/iscsi/initiatorname.iscsi}
BYPATH=${HPS_ISCSI_BYPATH:-/dev/disk/by-path}
LOGIN_WAIT=${HPS_ISCSI_LOGIN_WAIT:-20}

# 4 MiB at 1 GiB - 8 MiB, in MiB units for dd.
BLOCK_MIB=4
OFFSET_MIB=1016
MIN_BYTES=$(((OFFSET_MIB + BLOCK_MIB) * 1048576))

TARGET_IP=""
TARGET_IQN=""
INITIATOR=""
WORK=/tmp/hps-iscsi-test-$$
LOGGED_IN=0
ISCSID_STARTED=0
DEVICE=""

log() {
  printf '[hps-iscsi-test] %s\n' "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

usage() {
  cat >&2 <<'USAGE'
Usage: hps-iscsi-test.sh <target-ip> <target-iqn> [--initiator-name <iqn>]
Exit: 0 verified, 2 usage, 3 failed.
USAGE
}

fail() {
  printf 'ISCSI TEST FAILED: %s\n' "$*"
  log "failed: $*"
  exit 3
}

# Logs out when logged in; stops iscsid when this script started it.
teardown() {
  if [[ $LOGGED_IN -eq 1 ]]; then
    LOGGED_IN=0
    run iscsiadm -m node -T "$TARGET_IQN" -p "$TARGET_IP" --logout || log "logout failed: the session may still be open"
  fi
  if [[ $ISCSID_STARTED -eq 1 ]]; then
    stop_iscsid
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT
  teardown
  rm -rf "$WORK"
  exit "$rc"
}

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg=$1
    case "$arg" in
      --initiator-name)
        [[ $# -ge 2 ]] || { log "--initiator-name needs a value"; usage; exit 2; }
        INITIATOR=$2
        shift 2
        ;;
      -*) log "unknown option: $arg"; usage; exit 2 ;;
      *)
        if [[ -z "$TARGET_IP" ]]; then
          TARGET_IP=$arg
        elif [[ -z "$TARGET_IQN" ]]; then
          TARGET_IQN=$arg
        else
          usage
          exit 2
        fi
        shift
        ;;
    esac
  done
  [[ -n "$TARGET_IP" && -n "$TARGET_IQN" ]] || { usage; exit 2; }
  if [[ ! "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    fail "target address '$TARGET_IP' is not an IPv4 address"
  fi
  if [[ ! "$TARGET_IQN" =~ ^iqn\.[0-9]{4}-[0-9]{2}\.[a-z0-9.-]+(:[A-Za-z0-9._:-]+)?$ ]]; then
    fail "target '$TARGET_IQN' is not an iqn name"
  fi
  if [[ -n "$INITIATOR" && ! "$INITIATOR" =~ ^iqn\.[0-9]{4}-[0-9]{2}\.[a-z0-9.-]+(:[A-Za-z0-9._:-]+)?$ ]]; then
    fail "initiator '$INITIATOR' is not an iqn name"
  fi
}

require_module() {
  if [[ ! -d "$SYS_MODULE" ]]; then
    fail "the iscsi_tcp kernel module is not loaded on the host ($SYS_MODULE is missing); a container cannot load it: run 'modprobe iscsi_tcp' on the host"
  fi
}

iscsid_running() {
  pgrep -x iscsid > /dev/null 2>&1
}

stop_iscsid() {
  run pkill -x iscsid || true
  ISCSID_STARTED=0
}

# Writes the initiator name when it differs; returns 0 if the file changed.
set_initiator_name() {
  local want="InitiatorName=$INITIATOR" have=""
  if [[ -r "$INITIATORNAME_FILE" ]]; then
    have=$(grep -E '^InitiatorName=' "$INITIATORNAME_FILE" | head -n 1 || true)
  fi
  if [[ "$have" == "$want" ]]; then
    log "initiator name already $INITIATOR"
    return 1
  fi
  log "writing $INITIATORNAME_FILE: $want"
  mkdir -p -- "$(dirname -- "$INITIATORNAME_FILE")"
  printf '%s\n' "$want" > "$INITIATORNAME_FILE"
  return 0
}

ensure_iscsid() {
  local changed=$1
  if iscsid_running && [[ $changed -eq 1 ]]; then
    log "iscsid is running with the old initiator name; restarting it"
    stop_iscsid
    sleep 1
  fi
  if ! iscsid_running; then
    run iscsid
    ISCSID_STARTED=1
    sleep 1
  fi
}

discover() {
  local found
  found=$(run iscsiadm -m discovery -t sendtargets -p "$TARGET_IP") || fail "discovery against $TARGET_IP failed"
  printf '%s\n' "$found" >&2
  if ! printf '%s\n' "$found" | grep -qF "$TARGET_IQN"; then
    fail "target $TARGET_IQN was not offered by $TARGET_IP (the ACL must name this initiator)"
  fi
}

login() {
  run iscsiadm -m node -T "$TARGET_IQN" -p "$TARGET_IP" --login || fail "login to $TARGET_IQN failed"
  LOGGED_IN=1
}

# Sets DEVICE to the whole-disk node of the logged-in LUN.
find_device() {
  local waited=0 link
  while ((waited < LOGIN_WAIT)); do
    for link in "$BYPATH"/*iscsi*"$TARGET_IQN"*; do
      if [[ -e "$link" && "$link" != *-part* ]]; then
        DEVICE=$(readlink -f -- "$link")
        log "block device: $DEVICE ($link)"
        return 0
      fi
    done
    sleep 1
    waited=$((waited + 1))
  done
  fail "no block device for $TARGET_IQN appeared under $BYPATH within ${LOGIN_WAIT}s"
}

check_size() {
  local bytes
  bytes=$(run blockdev --getsize64 "$DEVICE") || fail "cannot read the size of $DEVICE"
  if ((bytes < MIN_BYTES)); then
    fail "$DEVICE is $bytes bytes; the test needs at least $MIN_BYTES (a 1 GiB zvol)"
  fi
}

write_and_verify() {
  mkdir -p -- "$WORK"
  run dd if=/dev/urandom of="$WORK/pattern" bs=1M count="$BLOCK_MIB" status=none || fail "cannot make the test pattern"
  run dd if="$WORK/pattern" of="$DEVICE" bs=1M seek="$OFFSET_MIB" count="$BLOCK_MIB" oflag=direct conv=fsync status=none || fail "writing to $DEVICE failed"
  run dd if="$DEVICE" of="$WORK/readback" bs=1M skip="$OFFSET_MIB" count="$BLOCK_MIB" iflag=direct status=none || fail "reading back from $DEVICE failed"
  run cmp "$WORK/pattern" "$WORK/readback" || fail "read-back differs from what was written on $DEVICE"
}

main() {
  local changed=0
  parse_args "$@"
  trap cleanup EXIT
  require_module
  if [[ -n "$INITIATOR" ]]; then
    if set_initiator_name; then
      changed=1
    fi
  fi
  ensure_iscsid "$changed"
  discover
  login
  find_device
  check_size
  write_and_verify
  teardown
  printf 'ISCSI TEST OK %s via %s: %s MiB written and read back at offset %s MiB of %s\n' \
    "$TARGET_IQN" "$TARGET_IP" "$BLOCK_MIB" "$OFFSET_MIB" "$DEVICE"
}

main "$@"
