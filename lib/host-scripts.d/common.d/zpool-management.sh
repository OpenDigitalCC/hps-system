


# - zpool management


check_zfs_loaded() {
  # Check for zfs command
  if ! command -v zfs >/dev/null 2>&1; then
    echo "❌ 'zfs' command not found. Is ZFS installed?"
    return 1
  fi

  # Check if ZFS kernel module is loaded
  if ! lsmod | grep -q "^zfs"; then
    echo "⚠️ ZFS module not loaded. Attempting to load..."
    if modprobe zfs 2>/dev/null; then
      echo "✅ ZFS module loaded successfully."
    else
      echo "❌ Failed to load ZFS kernel module. Check DKMS or installation status."
      return 1
    fi
  else
    echo "✅ ZFS module is loaded."
  fi

  return 0
}

# zpool_slug
# ----------
# Normalize cluster names for pool IDs.
# - Lowercase, keep [a-z0-9-], collapse dashes, trim, cap length.
# Usage: zpool_slug "Prod-A" [maxlen]
zpool_slug() {
  local s="$1" maxlen="${2:-12}"
  s="${s,,}"; s="${s//[^a-z0-9-]/-}"
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"
  printf '%.*s' "$maxlen" "$s"
}

# zpool_name_generate
# -------------------
# Canonical pool name: z<cluster>-p<class>-u<hexsecs><hexrand6>
# - <cluster> read from cluster_config CLUSTER_NAME and slugified.
# - <class> must be: nvme|ssd|hdd|arc|mix
# - <uid> is time-ordered unique id, no host/NIC dependence.
# Usage: zpool_name_generate <class>
zpool_name_generate() {
  local class="$1"
  [[ -n "$class" ]] || { echo "usage: zpool_name_generate <class>" >&2; return 2; }
  class="${class,,}"
  case "$class" in nvme|ssd|hdd|arc|mix) ;; *)
    echo "invalid class: $class (nvme|ssd|hdd|arc|mix)" >&2; return 2 ;;
  esac

  local cluster secs rand
  cluster="$(cluster_config get CLUSTER_NAME 2>/dev/null | tr -d '"')"
  cluster="${cluster:-default}"
  cluster="$(zpool_slug "$cluster" 12)"
  secs=$(printf '%08x' "$(date +%s)")
  if command -v od >/dev/null 2>&1; then
    rand=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  else
    rand=$(printf '%06x' "$((RANDOM<<16 ^ RANDOM))")
  fi
  echo "z${cluster}-p${class}-u${secs}${rand}"
}

# disks_free_list_simple
# ----------------------
# List whole disks that look unused (quick, explicit rules).
# Rules:
#   - TYPE=disk, non-removable, not loop/ram/md/dm
#   - has no partitions, not mounted anywhere,
#   - not flagged as LVM2_member/linux_raid_member/zfs_member,
#   - not present in current zpool status (paranoid).
# Output: newline-separated stable paths (/dev/disk/by-id if available).
# Usage: disks_free_list_simple
disks_free_list_simple() {
  lsblk -dn -o NAME,TYPE,RM | while read -r name type rm; do
    [[ "$type" == "disk" ]] || continue
    [[ "$rm" -eq 1 ]] && continue
    [[ "$name" =~ ^(loop|ram|md|dm-) ]] && continue
    local dev="/dev/$name"
    # no partitions
    lsblk -rno NAME,TYPE "$dev" | awk '$2=="part"{found=1} END{exit !found}' && continue
    # not mounted
    lsblk -rno MOUNTPOINTS "$dev" | grep -q '.' && continue
    # not PV/MD/ZFS member
    lsblk -rno FSTYPE "$dev" | grep -Eq 'LVM2_member|linux_raid_member|zfs_member' && continue
    # not already in a zpool
    if command -v zpool >/dev/null 2>&1; then
      local real; real="$(readlink -f "$dev")"
      zpool status -P 2>/dev/null | grep -q -- "$real" && continue
    fi
    # prefer by-id (WWN first)
    local real; real="$(readlink -f "$dev")"
    if [[ -d /dev/disk/by-id ]]; then
      local p
      for p in /dev/disk/by-id/wwn-* /dev/disk/by-id/*; do
        [[ -e "$p" ]] || continue
        [[ "$p" =~ -part[0-9]+$ ]] && continue
        [[ "$(readlink -f "$p")" == "$real" ]] && { echo "$p"; continue 2; }
      done
    fi
    echo "$real"
  done
}


# zpool_create_on_disk
# --------------------
# Create a zpool with a given name on a specific whole disk (DESTRUCTIVE),
# then automatically apply HPS defaults.
# Additionally, if --iscsi-root-name is provided, update host config:
#   remote_remote_host_variable <host> ISCSI_ROOT_0 <zvol-name>
# Usage:
#   zpool_create_on_disk <poolname> <disk> [--mountpoint <mp>] [-f] [--no-defaults]
#                         [--iscsi-root-name <zvol>] [--iscsi-host <host>]
zpool_create_on_disk() {
  local pool="$1" disk="$2"; shift 2 || true
  local mpoint="legacy" force=0 apply_defaults=1
  local iscsi_root_name="" iscsi_host=""

  while (( $# )); do
    case "$1" in
      --mountpoint)       mpoint="$2"; shift 2 ;;
      -f)                 force=1;     shift   ;;
      --no-defaults)      apply_defaults=0; shift ;;
      --iscsi-root-name)  iscsi_root_name="$2"; shift 2 ;;
      --iscsi-host)       iscsi_host="$2";      shift 2 ;;
      *) echo "zpool_create_on_disk: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [[ -n "$pool" && -n "$disk" ]] || {
    echo "usage: zpool_create_on_disk <poolname> <disk> [--mountpoint <mp>] [-f] [--no-defaults] [--iscsi-root-name <zvol>] [--iscsi-host <host>]" >&2
    return 2
  }

  # must be a whole block device and not obviously in-use
  [[ -b "$disk" ]] || { echo "not a block device: $disk" >&2; return 2; }
  local base; base="$(basename "$(readlink -f "$disk")")"
  [[ "$base" =~ [0-9]p?[0-9]+$ ]] && { echo "not a whole disk: $disk" >&2; return 2; }
  lsblk -rno NAME,TYPE "$disk" | awk '$2=="part"{found=1} END{exit !found}' && { echo "disk has partitions: $disk" >&2; return 2; }
  lsblk -rno MOUNTPOINTS "$disk" | grep -q '.' && { echo "disk is mounted: $disk" >&2; return 2; }
  lsblk -rno FSTYPE "$disk" | grep -Eq 'LVM2_member|linux_raid_member|zfs_member' && { echo "disk in use (LVM/MD/ZFS): $disk" >&2; return 2; }

  local -a cmd=( zpool create -o ashift=12 -m "$mpoint" )
  (( force )) && cmd+=( -f )
  cmd+=( "$pool" "$disk" )

  printf 'Creating zpool %s on %s:\n  ' "$pool" "$disk"; printf '%q ' "${cmd[@]}"; echo
  if ! "${cmd[@]}"; then
    echo "zpool create failed" >&2
    return 1
  fi

  (( apply_defaults )) && zfs_apply_hps_defaults "$pool"

  # Optional: set ISCSI_ROOT_0 in host config to provided zvol name
  if [[ -n "$iscsi_root_name" ]]; then
    local target_host="${iscsi_host:-$(hostname -s)}"
    if declare -F remote_remote_host_variable >/dev/null; then
      if remote_remote_host_variable "$target_host" ISCSI_ROOT_0 "$iscsi_root_name"; then
        echo "Updated host config: ${target_host} ISCSI_ROOT_0=${iscsi_root_name}"
      else
        echo "warning: failed to set ISCSI_ROOT_0 for ${target_host}" >&2
      fi
    else
      echo "warning: remote_remote_host_variable not found; skipping ISCSI_ROOT_0 update" >&2
    fi
  fi
}



# zpool_create_on_free_disk
# -------------------------
# Convenience wrapper: pick the first free disk and create the pool.
# Usage: zpool_create_on_free_disk <poolname> [--mountpoint <mp>] [-f]
zpool_create_on_free_disk() {
  local pool="$1"; shift || true
  local disk; disk="$(disks_free_list_simple | head -n1)"
  [[ -n "$disk" ]] || { echo "no free whole disks detected" >&2; return 1; }
  zpool_create_on_disk "$pool" "$disk" "$@"
}

