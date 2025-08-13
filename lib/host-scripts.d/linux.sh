

# Commands in this file are sourced on the host node, not IPS


# Initialise OpenSVC cluster settings on this node from HPS configs
initialise_opensvc_cluster() {
  local cluster_name node_tags rc unit

  remote_log "Initialising OpenSVC cluster (server-side MAC resolution in effect)"

  # --- 1) Read desired values from HPS configs ---
  cluster_name="$(cluster_config get CLUSTER_NAME 2>/dev/null || true)"
  if [[ -z "$cluster_name" ]]; then
    remote_log "CLUSTER_NAME not found in cluster_config; aborting."
    return 1
  fi
  # TYPE -> tags (leave as-is if you already store proper tags)
  node_tags="$(host_config get TYPE 2>/dev/null || true)"
  [[ -n "$node_tags" ]] && node_tags="$(echo "$node_tags" | tr '[:upper:]' '[:lower:]')"

  # --- 2) Apply cluster name (idempotent-friendly: just set; agent handles no-op) ---
  _osvc_run "set cluster.name=${cluster_name}" \
    om cluster config update --kw "cluster.name=${cluster_name}" || return 1

  # --- 3) Apply node tags (optional) ---
  if [[ -n "$node_tags" ]]; then
    _osvc_run "set node tags=${node_tags}" \
      om node config update --kw "tags=${node_tags}" || return 1
  else
    remote_log "No TYPE in host_config; skipping node tags"
  fi

  # --- 4) Restart OpenSVC daemon (try systemd units first, then 'om daemon') ---
  rc=1
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opensvc-server opensvc opensvc-agent; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${unit}.service"; then
        if _osvc_run "restart ${unit}.service" systemctl restart "${unit}.service"; then
          rc=0; break
        fi
      fi
    done
  fi
  if (( rc != 0 )); then
    if om daemon running >/dev/null 2>&1; then
      _osvc_run "restart opensvc daemon" om daemon restart || \
      _osvc_run "start opensvc daemon"   om daemon start
      rc=$?
    else
      _osvc_run "start opensvc daemon" om daemon start
      rc=$?
    fi
  fi
  (( rc == 0 )) || { remote_log "Warning: failed to restart OpenSVC daemon"; return 1; }

  remote_log "OpenSVC cluster initialisation complete: cluster='${cluster_name}' tags='${node_tags:-none}'"
}



# Fetch opensvc.conf from boot_manager and apply safely
load_opensvc_conf() {
  local conf_dir="/etc/opensvc"
  local conf_file="${conf_dir}/opensvc.conf"
  local gateway tmp rc unit

  # Resolve provisioning node
  gateway="$(get_provisioning_node 2>/dev/null)" || gateway=""
  if [[ -z "$gateway" ]]; then
    remote_log "load_opensvc_conf: no provisioning gateway detected"
    return 1
  fi

  mkdir -p "$conf_dir" || { remote_log "mkdir ${conf_dir} failed"; return 1; }

  # Fetch to a temp file
  tmp="$(mktemp "${conf_file}.XXXXXX")" || return 1
  if ! _osvc_run "fetch opensvc.conf from ${gateway}" \
        curl -fsS --connect-timeout 3 --retry 3 --retry-connrefused \
        "http://${gateway}/cgi-bin/boot_manager.sh?cmd=generate_opensvc_conf" \
        -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Minimal sanity check
  if [[ ! -s "$tmp" ]] || ! grep -q '^\[agent\]' "$tmp"; then
    remote_log "Downloaded opensvc.conf invalid or missing [agent] section"
    rm -f "$tmp"
    return 1
  fi

  # If unchanged, skip
  if [[ -f "$conf_file" ]] && cmp -s "$tmp" "$conf_file"; then
    rm -f "$tmp"
    remote_log "OpenSVC config unchanged; no restart required"
    echo "Unchanged ${conf_file}"
    return 0
  fi

  # Backup and install
  if [[ -f "$conf_file" ]]; then
    cp -a "$conf_file" "${conf_file}.$(date -u +%Y%m%dT%H%M%SZ).bak" || true
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$conf_file"
  command -v restorecon >/dev/null 2>&1 && restorecon -q "$conf_file" || true

  remote_log "OpenSVC config updated"
  echo "Updated ${conf_file}, restarting…"

  # Restart daemon with _osvc_run logging
  rc=1
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opensvc-server opensvc opensvc-agent; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${unit}.service"; then
        if _osvc_run "restart ${unit}.service" systemctl restart "${unit}.service"; then
          rc=0; break
        fi
      fi
    done
  fi
  if (( rc != 0 )); then
    if om daemon running >/dev/null 2>&1; then
      _osvc_run "restart opensvc daemon" om daemon restart || \
      _osvc_run "start opensvc daemon"   om daemon start
      rc=$?
    else
      _osvc_run "start opensvc daemon" om daemon start
      rc=$?
    fi
  fi

  (( rc == 0 )) && remote_log "OpenSVC daemon restarted" || {
    remote_log "Warning: failed to restart OpenSVC daemon"
    return 1
  }
}




# helper: run a command, log stdout+stderr, return code intact
_osvc_run() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  remote_log "[osvc] ${desc} rc=${rc}\n${out}"
  return $rc
}



# ----- ------------

opensvc_create_zvol_iscsi() {
  _require_cmd om zpool zfs || return 127

  local svc="$1" pool="$2" zname="$3" size="$4"; shift 4 || {
    remote_log "usage: opensvc_create_zvol_iscsi <svc> <pool> <zvol_name> <size> [...]"
    return 2
  }

  local vbs="32k" sparse="yes" comp="lz4" placement="tags=storage" iqn="" initiators=""
  local a
  for a in "$@"; do
    case "$a" in
      --volblocksize=*) vbs="${a#*=}";;
      --sparse=*)       sparse="${a#*=}";;
      --compression=*)  comp="${a#*=}";;
      --placement=*)    placement="${a#*=}";;
      --iqn=*)          iqn="${a#*=}";;
      --initiators=*)   initiators="${a#*=}";;
      *) remote_log "unknown arg: $a"; return 2;;
    esac
  done

  zpool list -H -o name | grep -qx "$pool" || { remote_log "pool '$pool' not found"; return 1; }
  [[ "$size" =~ ^[0-9]+[kKmMgGtTpP]?$ ]] || { remote_log "invalid size: $size"; return 2; }
  [[ -n "$iqn" ]] || iqn="iqn.$(date +%Y-%m).local.hps:${svc}.${zname}"

  remote_log "Defining OpenSVC service '${svc}' zvol=${pool}/${zname} size=${size} iqn=${iqn} (local node)"

  # If service already exists, warn (avoid duplicate disk# indexes)
  if om "${svc}" print config >/dev/null 2>&1; then
    remote_log "WARN: service '${svc}' already exists. Validation errors may indicate duplicate resource indexes (disk#1, disk#2, share#1)."
  fi

  # create/update in one go; capture output
  if ! _osvc_run "om ${svc} create" \
        om "$svc" create \
          --kw placement="$placement" \
          --kw disk#1.type=zpool \
          --kw disk#1.name="$pool" \
          --kw disk#2.type=zvol \
          --kw disk#2.name="${pool}/${zname}" \
          --kw disk#2.size="$size" \
          --kw disk#2.volblocksize="$vbs" \
          --kw disk#2.compression="$comp" \
          --kw disk#2.sparse="$sparse" \
          --kw share#1.type=iscsi \
          --kw share#1.name="$iqn" \
          --kw share#1.backstore=disk#2 \
          ${initiators:+--kw share#1.initiators="$initiators"} \
          --wait
  then
    # dump validation & current config for diagnostics
    _osvc_run "om ${svc} print validation" om "$svc" print validation || true
    _osvc_run "om ${svc} print config"     om "$svc" print config     || true
    return 1
  fi

  if ! _osvc_run "om ${svc} provision" om "$svc" provision --wait; then
    _osvc_run "om ${svc} print validation" om "$svc" print validation || true
    _osvc_run "om ${svc} print config"     om "$svc" print config     || true
    return 1
  fi

  local dev="/dev/zvol/${pool}/${zname}"
  if [[ -e "$dev" ]]; then
    remote_log "ZVOL ready: $dev"
  else
    remote_log "WARN: zvol device not present yet: $dev (udev delay?)"
  fi
  remote_log "iSCSI target exported as: $iqn"
}









# ----- zvol etc in bash

add_zvol_to_iscsi_target() {
  local remote_host="$1"
  local zvol_suffix="$2"
  local size="$3"

  if [[ -z "$remote_host" || -z "$zvol_suffix" || -z "$size" ]]; then
    echo "Usage: add_zvol_to_iscsi_target <remote_host> <suffix> <size>"
    return 1
  fi

  local pool
  pool="$(get_zfs_pool)"
  local zvol_name="${remote_host}-${zvol_suffix}"
  local zvol_path="/dev/zvol/${pool}/${zvol_name}"
  local backstore_name="${zvol_name}_bs"
  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  create_zvol_for_iscsi "$zvol_name" "$size" "$pool"
  rtslib_add_lun "$remote_host" "$zvol_path"
  
  echo "✅ Added zvol '${zvol_name}' to existing target '${iqn}'"
}


create_iscsi_target() {
  local remote_host="$1"
  local ip="${2:-0.0.0.0}"
  local port="${3:-3260}"

  if [[ -z "$remote_host" ]]; then
    echo "Usage: create_iscsi_target <remote_host> [ip] [port]"
    return 1
  fi

  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  if ! check_iscsi_export_available; then
    echo "❌ iSCSI target prerequisites not met"
    return 1
  fi

  targetcli <<EOF
/iscsi create ${iqn}
/iscsi/${iqn}/tpg1/portals create ${ip} ${port}
/iscsi/${iqn}/tpg1 set attribute authentication=0
/iscsi/${iqn}/tpg1 set attribute generate_node_acls=1
/iscsi/${iqn}/tpg1 set attribute demo_mode_write_protect=0
EOF
  rtslib_save_config
  echo "✅ Created iSCSI target '${iqn}' on ${ip}:${port}"
}


get_zfs_pool() {
  hostname | tr '[:upper:]' '[:lower:]'
}

zvol_exists() {
  local pool="$1"
  local zvol="$2"
  zfs list -H -o name | grep -q "^${pool}/${zvol}$"
}

create_zvol_for_iscsi() {
  local zvol_name="$1"
  local size="$2"
  local pool="${3:-$(get_zfs_pool)}"

  local full_path="${pool}/${zvol_name}"

  if ! zpool list -H -o name | grep -qw "$pool"; then
    echo "❌ Zpool '$pool' does not exist. Aborting."
    return 1
  fi

  if zvol_exists "$pool" "$zvol_name"; then
    echo "⚠️ ZVOL '${full_path}' already exists"
    return 0
  fi

  echo "Creating ZVOL '${full_path}' (${size}) for iSCSI use..."
  zfs create -V "$size" \
    -s \
    -b 4096 \
    -o compression=lz4 \
    -o logbias=throughput \
    -o sync=disabled \
    -o primarycache=metadata \
    "$full_path"

  udevadm settle
  echo "✅ ZVOL created: /dev/zvol/${full_path}"
}


iscsi_targetcli_export() {
  local iqn="$1"
  local zvol_path="$2"
  local backstore_name="$3"
  local bind_ip="$4"
  local port="$5"
  local new_target="$6"  # 1 if new target, 0 if existing

  targetcli <<EOF
/backstores/block create ${backstore_name} ${zvol_path}
$( [[ "$new_target" == 1 ]] && echo "/iscsi create ${iqn}" )
/iscsi/${iqn}/tpg1/luns create /backstores/block/${backstore_name}
$( [[ "$new_target" == 1 ]] && echo "/iscsi/${iqn}/tpg1/portals create ${bind_ip} ${port}" )
$( [[ "$new_target" == 1 ]] && cat <<EOT
/iscsi/${iqn}/tpg1 set attribute authentication=0
/iscsi/${iqn}/tpg1 set attribute generate_node_acls=1
/iscsi/${iqn}/tpg1 set attribute demo_mode_write_protect=0
EOT
)
EOF
rtslib_save_config
}




enable_iscsi_target_reload_on_boot() {
  # Check for required files and services
  if [[ ! -f /etc/target/saveconfig.json ]]; then
    echo "⚠️ No saved iSCSI configuration found at /etc/target/saveconfig.json"
    return 1
  fi

  if ! systemctl list-unit-files | grep -q '^target.service'; then
    echo "❌ 'target.service' not found. Is 'rtslib-fb-target' installed?"
    return 1
  fi

  echo "🔧 Enabling iSCSI target config reload at boot..."

  systemctl enable target && systemctl restart target

  if systemctl is-enabled target &>/dev/null; then
    echo "✅ iSCSI target.service enabled and started."
  else
    echo "❌ Failed to enable target.service."
    return 1
  fi
}


check_iscsi_export_available() {
  # Check for targetcli
  if ! command -v targetcli >/dev/null 2>&1; then
    echo "❌ 'targetcli' not found. Please install the targetcli package."
    return 1
  fi

  # Check for configfs mount (used by LIO)
  if ! mountpoint -q /sys/kernel/config; then
    echo "⚠️ configfs not mounted. Attempting to mount..."
    if ! mount -t configfs configfs /sys/kernel/config 2>/dev/null; then
      echo "❌ Failed to mount configfs. iSCSI export via LIO not available."
      return 1
    fi
  fi

  # Check if LIO kernel modules are available (needed for /sys/kernel/config/target)
  if [[ ! -d /sys/kernel/config/target ]]; then
    echo "❌ LIO kernel target modules are not loaded or supported."
    return 1
  fi

  echo "✅ iSCSI export environment is ready (targetcli + LIO)"
  return 0
}




create_zpool_for_iscsi() {
  check_zfs_loaded
  local pool="$1"           # e.g. tank
  local main_dev="$2"       # e.g. /dev/sdX
  local slog_dev="$3"       # optional: SLOG device Used for sync writes. Use high-endurance, low-latency devices (e.g. Optane).
  local l2arc_dev="$4"      # optional: L2ARC device Secondary read cache. Use large fast NVMe if reads dominate.

  if [[ -z "$pool" || -z "$main_dev" ]]; then
    echo "Usage: create_zpool_for_iscsi <poolname> <main_dev> [slog_dev] [l2arc_dev]"
    return 1
  fi

  for dev in "$main_dev" "$slog_dev" "$l2arc_dev"; do
    [[ -n "$dev" && ! -b "$dev" ]] && {
      echo "❌ Device $dev is not a valid block device"
      return 1
    }
  done

  if zpool list -H -o name | grep -qw "$pool"; then
    echo "❌ Zpool '$pool' already exists"
    return 1
  fi

  local args=(create -f -o ashift=12 -o autoreplace=on \
    -O compression=off \
    -O sync=disabled \
    -O logbias=throughput \
    -O xattr=sa \
    -O atime=off)

  args+=("$pool" "$main_dev")

  [[ -n "$slog_dev" ]] && args+=("log" "$slog_dev")
  [[ -n "$l2arc_dev" ]] && args+=("cache" "$l2arc_dev")

  echo "Creating zpool '${pool}' with:"
  echo "  main: $main_dev"
  [[ -n "$slog_dev" ]] && echo "  slog: $slog_dev"
  [[ -n "$l2arc_dev" ]] && echo "  l2arc: $l2arc_dev"

  zpool "${args[@]}"
}

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


# lib/functions.d/rtslib.sh

# Check if rtslib is usable
rtslib_check_available() {
  python3 -c 'import rtslib_fb' 2>/dev/null || {
    echo "❌ python3-rtslib_fb is not available"
    return 1
  }
  return 0
}


# ---- Bash Python wrappers




# Check if rtslib is usable
rtslib_check_available() {
  python3 -c 'import rtslib_fb' 2>/dev/null || {
    echo "❌ python3-rtslib_fb is not available"
    return 1
  }
  return 0
}

# Save config persistently
rtslib_save_config() {
  python3 - <<'EOF'
from rtslib_fb import RTSRoot
RTSRoot().save_to_file()
EOF
}

# Create iSCSI target for remote host
rtslib_create_target() {
  local remote_host="$1"
  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  python3 - <<EOF
from rtslib_fb import RTSRoot, Target, TPG, FabricModule

name = "$iqn"
fm = FabricModule("iscsi")
try:
    target = Target(fm, wwn=name)
    tpg = TPG(target, mode="create")
    tpg.set_attribute("generate_node_acls", True)
    tpg.set_attribute("authentication", False)
    tpg.set_attribute("demo_mode_write_protect", False)
    tpg.enable = True
    RTSRoot().save_to_file()
except Exception as e:
    print(f"❌ Failed to create target: {e}")
    exit(1)
EOF
}

# Add LUN (zvol) to target
rtslib_add_lun() {
  local remote_host="$1"
  local zvol_path="$2"
  local zvol_name
  zvol_name=$(basename "$zvol_path")
  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  python3 - <<EOF
from rtslib_fb import RTSRoot, BlockStorageObject

iqn = "$iqn"
zvol_path = "$zvol_path"
zvol_name = "$zvol_name"
found = False

for target in RTSRoot().targets:
    if target.wwn == iqn:
        found = True
        tpg = target.tpgs[0]
        bs = BlockStorageObject(name=zvol_name, dev=zvol_path)
        tpg.luns.append(bs)
        break

if not found:
    print("❌ Target not found")
    exit(1)

RTSRoot().save_to_file()
EOF
}

# List all iSCSI targets
rtslib_list_targets() {
  python3 - <<EOF
from rtslib_fb import RTSRoot

for t in RTSRoot().targets:
    if t.fabric_module.name == "iscsi":
        print(t.wwn)
EOF
}

# List LUNs for a given target
rtslib_list_luns_for_target() {
  local remote_host="$1"
  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  echo "📦 LUNs for iSCSI target '${iqn}':"

  python3 - <<EOF
from rtslib_fb import RTSRoot

iqn = "$iqn"
found = False
for t in RTSRoot().targets:
    if t.wwn == iqn:
        found = True
        for tpg in t.tpgs:
            for i, lun in enumerate(tpg.luns):
                try:
                    obj = lun.storage_object
                    print(f"   {i} → {obj.name} ({obj.udev_path})")
                except Exception as e:
                    print(f"   {i} → <error: {e}>")
        break
if not found:
    print("   ❌ Target not found")
EOF
}

# Delete a target by hostname
rtslib_delete_target() {
  local remote_host="$1"
  local iqn="iqn.$(date +%Y-%m).local.hps:${remote_host}"

  python3 - <<EOF
from rtslib_fb import RTSRoot

iqn = "$iqn"
for t in list(RTSRoot().targets):
    if t.wwn == iqn:
        t.delete()
        RTSRoot().save_to_file()
        print("✅ Target deleted")
        break
else:
    print("❌ Target not found")
EOF
}


