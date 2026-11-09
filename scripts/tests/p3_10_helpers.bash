# Helpers for the CS-3.2 leg/mirror tests (test_p3_10_* .. test_p3_19_*). Load
# after p2_30_helpers (approval payloads, xxd shim, p2_setup_dirs).
# Shims log every call to $SHIM_LOG; fake machine state lives in $STATE:
#   detail.<mirror>     the array exists; the text is what mdadm --detail prints
#   examine.<dev name>  what mdadm --examine prints for that device (absent: rc 1)
#   blkid.<dev name>    the device carries a signature
#   sessions            logged-in iSCSI sessions (one line each)
#   nolun               a login does not make the by-path device appear

P3_LOC_SPEC="local:lab/enc/vm/vm1-disk0"
P3_REM_SPEC="iscsi:10.99.1.2:iqn.2026-01.hps.example:vm1-disk0"
P3_REM_NAME="ip-10.99.1.2:3260-iscsi-iqn.2026-01.hps.example:vm1-disk0-lun-0"
P3_LEGS_JSON='["iscsi:10.99.1.2:iqn.2026-01.hps.example:vm1-disk0","local:lab/enc/vm/vm1-disk0"]'

p3_setup() {
  p2_setup_dirs
  p2_shim_xxd
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_MIRROR_DIR="$TEST_DIR/mirrors"
  export HPS_LEG_TIMEOUT=2
  export HPS_SYS="$TEST_DIR/sys"
  export HPS_PROC_MOUNTS="$TEST_DIR/mounts"
  : > "$HPS_PROC_MOUNTS"
  mkdir -p "$HPS_DEV/zvol/lab/enc/vm" "$HPS_DEV/disk/by-path" "$HPS_SYS/block"
  LOCDEV="$HPS_DEV/zvol/lab/enc/vm/vm1-disk0"
  REMDEV="$HPS_DEV/disk/by-path/$P3_REM_NAME"
  S="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts"
  p3_shims
}

p3_make_local() { touch "$LOCDEV"; }
p3_make_remote() { touch "$REMDEV"; }

p3_shims() {
  cat > "$TEST_DIR/bin/mdadm" <<'SHIM'
#!/usr/bin/env bash
echo "mdadm $*" >> "$SHIM_LOG"
devs() { local a; for a in "$@"; do [[ "$a" == /* && "$a" != /dev/md/* ]] && echo "   $a"; done; return 0; }
name_of() { local a; for a in "$@"; do [[ "$a" == /dev/md/* ]] && { echo "${a##*/}"; return; }; done; }
case "$1" in
  --examine)
    f="$STATE/examine.${*: -1}"; f="${f%/*}/examine.${*: -1}"
    f="$STATE/examine.$(basename "${*: -1}")"
    [[ -e "$f" ]] && { cat "$f"; exit 0; }
    echo "mdadm: No md superblock detected on ${*: -1}." >&2; exit 1 ;;
  --detail)
    n=$(basename "$2")
    [[ -e "$STATE/detail.$n" ]] && { cat "$STATE/detail.$n"; exit 0; }
    echo "mdadm: cannot open $2: No such file or directory" >&2; exit 1 ;;
  --create)
    n=$(name_of "$@")
    { echo "           State : clean"; echo "   Active Devices : 2"; echo "    Intent Bitmap : Internal"; devs "$@"; } > "$STATE/detail.$n"
    exit "${FAKE_CREATE_RC:-0}" ;;
  --assemble)
    n=$(name_of "$@")
    { echo "           State : clean, degraded"; echo "   Active Devices : 1"; devs "$@"; } > "$STATE/detail.$n"
    exit "${FAKE_ASSEMBLE_RC:-0}" ;;
  --stop)
    rm -f "$STATE/detail.$(basename "$2")"; exit 0 ;;
  --zero-superblock) exit 0 ;;
  /dev/md/*)
    n=$(basename "$1")
    case "$2" in
      --re-add) [[ "${FAKE_READD_RC:-0}" -ne 0 ]] && exit "$FAKE_READD_RC"; echo "   $3" >> "$STATE/detail.$n"; exit 0 ;;
      --fail) exit 0 ;;
      --remove) grep -vF "$3" "$STATE/detail.$n" > "$STATE/detail.tmp" || true; mv "$STATE/detail.tmp" "$STATE/detail.$n"; exit 0 ;;
    esac ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/blkid" <<'SHIM'
#!/usr/bin/env bash
echo "blkid $*" >> "$SHIM_LOG"
[[ -e "$STATE/blkid.$(basename "${*: -1}")" ]] && { echo 'TYPE="ext4"'; exit 0; }
exit 2
SHIM
  cat > "$TEST_DIR/bin/wipefs" <<'SHIM'
#!/usr/bin/env bash
echo "wipefs $*" >> "$SHIM_LOG"
SHIM
  cat > "$TEST_DIR/bin/udevadm" <<'SHIM'
#!/usr/bin/env bash
echo "udevadm $*" >> "$SHIM_LOG"
SHIM
  cat > "$TEST_DIR/bin/iscsiadm" <<'SHIM'
#!/usr/bin/env bash
echo "iscsiadm $*" >> "$SHIM_LOG"
case "$2" in
  session)
    [[ -s "$STATE/sessions" ]] && { cat "$STATE/sessions"; exit 0; }
    exit 21 ;;
  discovery) echo "$6:3260,1 iqn.fake"; exit 0 ;;
  node)
    iqn="$4"; ip="$6"
    echo "tcp: [1] $ip:3260,1 $iqn (non-flash)" >> "$STATE/sessions"
    [[ -e "$STATE/nolun" ]] || touch "$HPS_DEV/disk/by-path/ip-$ip:3260-iscsi-$iqn-lun-0"
    exit "${FAKE_LOGIN_RC:-0}" ;;
esac
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

# p3_sb <device> <uuid> <events> <update time> <slot> <array state>
p3_sb() {
  cat > "$STATE/examine.$(basename "$1")" <<SB
$1:
          Magic : a92b4efc
        Version : 1.2
     Array UUID : $2
           Name : node:vm1-disk0
     Raid Level : raid1
    Update Time : $4
         Events : $3
    Device Role : Active device $5
    Array State : $6 ('A' == active, '.' == missing, 'R' == replacing)
SB
}

P3_UUID=aaaaaaaa:bbbbbbbb:cccccccc:dddddddd
P3_T1="Mon Nov  9 10:00:00 2026"
P3_T2="Mon Nov  9 11:00:00 2026"

# Both legs carry a clean, agreeing superblock (local slot 0, remote slot 1).
p3_sb_agreeing() {
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  p3_sb "$REMDEV" "$P3_UUID" 50 "$P3_T1" 1 AA
}

# p3_declaration [action] [pool] [expires] [mac] [legs-json]: a signed document.
p3_declaration() {
  p2_payload "$(p2_approval "${1:-peer-gone}" "${2:-vm1-disk0}" "${6:-0}" "${3:-4102444800}" "${4:-aabbccddeeff}" "${5:-$P3_LEGS_JSON}")"
}

# Anything that changes md state or the machine.
p3_no_state_change() {
  run ! grep -E -- '--assemble|--create|--re-add|--add|--run|--fail|--remove|--stop|--zero-superblock|^wipefs|--login' "$SHIM_LOG"
}
