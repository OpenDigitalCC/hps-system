


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

