


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
  cluster="$(remote_cluster_variable CLUSTER_NAME 2>/dev/null | tr -d '"')"
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


# zfs_get_defaults
# -----------------
# Return recommended defaults. NOTE: properties that are immutable after
# dataset creation (e.g., normalization, casesensitivity) are intentionally
# omitted here to avoid post-create failures.
zfs_get_defaults() {
  local -n _POOL_OPTS="$1"
  local -n _ZFS_PROPS="$2"

  _POOL_OPTS=(
    -o ashift=12          # 4K-sector safe default for SSD/NVMe/HDD
    # TODO: when zpool_create_on_disk supports extra -O props, consider:
    # -O casesensitivity=sensitive
    # -O normalization=formD
  )

  _ZFS_PROPS=(
    compression=zstd
    atime=off
    relatime=on
    xattr=sa
    acltype=posixacl
    aclinherit=passthrough
    aclmode=passthrough
    dnodesize=auto
    logbias=throughput
  )
}


# expects: remote_log, remote_host_variable, zpool_name_generate, zpool_create_on_disk, zfs_get_defaults
zpool_create_on_free_disk() {
  local strategy="first" mpoint="/srv/storage" force=0 dry_run=0 apply_defaults=1
  local host_short; host_short="$(hostname -s)"

  _log() { remote_log "[zpool_create_on_free_disk] $*"; [[ "${LOG_ECHO:-1}" -eq 1 ]] && echo "[zpool_create_on_free_disk] $*"; }

  # --- single canonical getter for existing ZPOOL_NAME ---
  _get_existing_zpool_name() {
    local v
    v="$(remote_host_variable ZPOOL_NAME 2>/dev/null || true)"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
    return 1
  }

  # ---------- args ----------
  while (( $# )); do
    case "$1" in
      --strategy)    strategy="${2:?--strategy requires value: first|largest}"; shift 2 ;;
      --mountpoint)  mpoint="${2:?--mountpoint requires value}"; shift 2 ;;
      -f)            force=1; shift ;;
      --dry-run)     dry_run=1; shift ;;
      --no-defaults) apply_defaults=0; shift ;;
      *) _log "ERROR: unknown arg '$1'"; return 2 ;;
    esac
  done

  # ---------- PREFLIGHT 1: check ZPOOL_NAME before anything else ----------
  local configured_pool=""
  if configured_pool="$(_get_existing_zpool_name)"; then
    _log "ZPOOL_NAME is configured for host '${host_short}': '${configured_pool}'. Verifying state…"

    if ! command -v zpool >/dev/null 2>&1; then
      _log "ZPOOL_NAME='${configured_pool}' configured, but 'zpool' CLI not found to verify. Aborting per policy."
      return 4
    fi

    local pools; pools="$(zpool list -H -o name 2>/dev/null | awk 'NF')"
    if printf '%s\n' "${pools}" | grep -qx -- "${configured_pool}"; then
      _log "Configured pool '${configured_pool}' is present. Nothing to do."
      return 4
    fi
    if [[ -n "${pools}" ]]; then
      _log "Configured pool '${configured_pool}' is NOT imported; other pools present: ${pools//$'\n'/, }. Aborting per policy."
      return 4
    else
      _log "Configured pool '${configured_pool}' is NOT imported; no pools present. Aborting per policy."
      return 4
    fi
  fi
  # At this point, ZPOOL_NAME is NOT set — we may proceed.

  # ---------- name & disk selection ----------
  if ! declare -F zpool_name_generate >/dev/null; then _log "ERROR: missing helper 'zpool_name_generate'"; return 2; fi
  local pool; pool="$(zpool_name_generate ssd)" || { _log "ERROR: zpool_name_generate failed"; return 1; }
  [[ -n "$pool" ]] || { _log "ERROR: failed to generate pool name"; return 1; }

  local disk=""
  if declare -F disks_free_list_simple >/dev/null; then
    case "$strategy" in
      first)   disk="$(disks_free_list_simple | head -n1)";;
      largest) disk="$(disks_free_list_simple \
                        | xargs -r -I{} sh -c 'd="{}"; sz=$(lsblk -bndo SIZE "$d" 2>/dev/null || echo 0); echo "$sz $d"' \
                        | sort -nrk1,1 | awk 'NR==1{print $2}')";;
      *) _log "ERROR: invalid --strategy '${strategy}' (use: first|largest)"; return 2 ;;
    esac
  else
    disk="$(
      lsblk -dprno NAME,TYPE | awk '$2=="disk"{print $1}' \
      | while read -r d; do
          lsblk -rno TYPE "$d" | grep -q '^part$' && continue
          lsblk -rno MOUNTPOINTS "$d" | grep -q '.'   && continue
          lsblk -rno FSTYPE "$d" | grep -Eq 'LVM2_member|linux_raid_member|zfs_member' && continue
          echo "$d"
        done | { case "$strategy" in
                   largest) while read -r d; do sz=$(lsblk -bndo SIZE "$d" 2>/dev/null || echo 0); echo "$sz $d"; done | sort -nrk1,1 | awk 'NR==1{print $2}' ;;
                   *) head -n1 ;;
                 esac; }
    )"
  fi
  [[ -n "$disk" ]] || { _log "ERROR: no free whole disks detected"; return 1; }

  _log "Selected free disk: ${disk}"
  _log "Planned pool name: ${pool} (mountpoint='${mpoint}', strategy='${strategy}', force=${force}, defaults=${apply_defaults})"

  # ---------- defaults ----------
  if ! declare -F zfs_get_defaults >/dev/null; then _log "ERROR: missing helper 'zfs_get_defaults'"; return 2; fi
  local -a POOL_OPTS ZFS_PROPS
  zfs_get_defaults POOL_OPTS ZFS_PROPS

  # ---------- dry-run ----------
  if (( dry_run )); then
    _log "DRY-RUN: would run -> zpool_create_on_disk '${pool}' '${disk}' --mountpoint '${mpoint}'$([[ $force -eq 1 ]] && echo ' -f')$([[ $apply_defaults -eq 0 ]] && echo ' --no-defaults')"
    _log "DRY-RUN: pool options (create-time): ${POOL_OPTS[*]}"
    (( apply_defaults )) && _log "DRY-RUN: zfs props to apply on '${pool}': ${ZFS_PROPS[*]}"
    return 0
  fi

  # ---------- create ----------
  if ! declare -F zpool_create_on_disk >/dev/null; then _log "ERROR: missing helper 'zpool_create_on_disk'"; return 2; fi
  local -a args=( "$pool" "$disk" --mountpoint "$mpoint" )
  (( force )) && args+=( -f )
  (( apply_defaults == 0 )) && args+=( --no-defaults )

  _log "Executing pool creation..."
  if ! zpool_create_on_disk "${args[@]}"; then _log "ERROR: pool creation failed for ${pool} on ${disk}"; return 1; fi
  _log "Pool created successfully: ${pool}"

  if (( apply_defaults )); then
    local kv
    for kv in "${ZFS_PROPS[@]}"; do
      _log "Applying zfs property on ${pool}: ${kv}"
      zfs set "${kv}" "${pool}" || _log "WARNING: failed to apply property '${kv}' on ${pool}"
    done
  else
    _log "apply_defaults disabled; skipping property tuning."
  fi

  # ---------- persist ----------
  if remote_host_variable ZPOOL_NAME "$pool"; then
    _log "Persisted host variable: ZPOOL_NAME=${pool}"
  else
    _log "ERROR: failed to persist host variable ZPOOL_NAME=${pool}"; return 1
  fi

  return 0
}










