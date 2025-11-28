#!/bin/bash
#===============================================================================
# HPS iSCSI/LIO Functions for Alpine Linux
# iSCSI target management for SCH (Storage Cluster Host) nodes
#===============================================================================

#===============================================================================
# n_lio_initialize
# ----------------
# Initialize LIO kernel subsystem and start targetcli service.
#
# Behaviour:
#   - Mounts configfs at /sys/kernel/config if not mounted
#   - Loads required kernel modules
#   - Starts targetcli OpenRC service (required for Alpine's Python targetcli)
#   - Verifies LIO is accessible via targetcli
#   - Logs progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on initialization failure
#
# Example usage:
#   n_lio_initialize
#
#===============================================================================
n_lio_initialize() {
  n_remote_log "[LIO] Initializing LIO kernel subsystem"
  
  # Check and mount configfs
  if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    n_remote_log "[LIO] Mounting configfs at /sys/kernel/config"
    
    if ! mount -t configfs configfs /sys/kernel/config 2>/dev/null; then
      n_remote_log "[LIO] ERROR: Failed to mount configfs"
      return 1
    fi
    
    n_remote_log "[LIO] configfs mounted successfully"
  else
    n_remote_log "[LIO] configfs already mounted"
  fi
  
  # Load required kernel modules
  local modules=(
    "target_core_mod"
    "target_core_iblock"
    "target_core_file"
    "target_core_pscsi"
    "iscsi_target_mod"
  )
  
  n_remote_log "[LIO] Loading kernel modules..."
  
  for mod in "${modules[@]}"; do
    # Check if already loaded
    if lsmod | grep -q "^${mod} "; then
      n_remote_log "[LIO] Module already loaded: $mod"
      continue
    fi
    
    n_remote_log "[LIO] Loading module: $mod"
    if ! modprobe "$mod" 2>/dev/null; then
      n_remote_log "[LIO] WARNING: Could not load module: $mod (may be optional)"
    else
      n_remote_log "[LIO] Module loaded: $mod"
    fi
  done
  
  # Ensure dbus is installed and running (required by targetcli service)
  n_remote_log "[LIO] Ensuring dbus is available..."
  
  if ! command -v dbus-daemon >/dev/null 2>&1; then
    n_remote_log "[LIO] dbus not found, installing..."
    if ! apk add --quiet dbus 2>/dev/null; then
      n_remote_log "[LIO] ERROR: Failed to install dbus"
      return 1
    fi
  fi
  
  # Start dbus if not running
  if ! rc-service dbus status >/dev/null 2>&1; then
    n_remote_log "[LIO] Starting dbus service..."
    if ! rc-service dbus start 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done; then
      n_remote_log "[LIO] WARNING: dbus service may have issues"
    fi
  else
    n_remote_log "[LIO] dbus service already running"
  fi
  
  # Start targetcli service
  n_remote_log "[LIO] Starting targetcli service..."
  
  if rc-service targetcli status >/dev/null 2>&1; then
    n_remote_log "[LIO] targetcli service already running"
  else
    local service_output
    service_output=$(rc-service targetcli start 2>&1)
    local service_rc=$?
    
    # Log all output
    echo "$service_output" | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
    
    if [[ $service_rc -ne 0 ]]; then
      n_remote_log "[LIO] ERROR: Failed to start targetcli service (exit code: $service_rc)"
      return 1
    fi
    
    n_remote_log "[LIO] targetcli service started successfully"
  fi
  
  # Enable service for boot
  if ! rc-update show default | grep -q targetcli; then
    n_remote_log "[LIO] Enabling targetcli service at boot"
    rc-update add targetcli default 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
  fi
  
  # Also enable dbus at boot
  if ! rc-update show default | grep -q dbus; then
    n_remote_log "[LIO] Enabling dbus service at boot"
    rc-update add dbus default 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
  fi
  
  # Give service time to initialize
  sleep 1
  
  # Verify LIO is accessible via targetcli
  n_remote_log "[LIO] Verifying LIO accessibility..."
  if targetcli ls >/dev/null 2>&1; then
    n_remote_log "[LIO] LIO subsystem initialized and accessible"
    return 0
  else
    n_remote_log "[LIO] ERROR: targetcli command still fails after service start"
    targetcli ls 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
    return 1
  fi
}

#===============================================================================
# n_install_iscsi_packages
# -------------------------
# Install iSCSI target packages for Alpine Linux.
#
# Behaviour:
#   - Installs targetcli and targetcli-openrc packages
#   - Initializes LIO kernel subsystem
#   - Starts and enables targetcli service
#   - Verifies targetcli command is available
#   - Logs progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on installation failure
#
# Example usage:
#   n_install_iscsi_packages
#
#===============================================================================
n_install_iscsi_packages() {
  n_remote_log "[iSCSI] Installing iSCSI target packages"
  
  local packages=("targetcli" "targetcli-openrc")
  
  n_remote_log "[iSCSI] Packages to install: ${packages[*]}"
  
  if ! n_install_packages "${packages[@]}"; then
    n_remote_log "[iSCSI] ERROR: Failed to install iSCSI packages"
    return 1
  fi
  
  # Verify installation
  if ! command -v targetcli >/dev/null 2>&1; then
    n_remote_log "[iSCSI] ERROR: targetcli command not found after installation"
    return 1
  fi
  
  n_remote_log "[iSCSI] Successfully installed iSCSI packages"
  n_remote_log "[iSCSI] targetcli command: $(command -v targetcli)"
  
  # Initialize LIO
  if ! n_lio_initialize; then
    n_remote_log "[iSCSI] ERROR: Failed to initialize LIO subsystem"
    return 1
  fi
  
  return 0
}

#===============================================================================
# n_lio_create
# ------------
# Create iSCSI target with backstore and optional ACL.
#
# Behaviour:
#   - Validates required parameters (iqn, device)
#   - Creates block backstore from device
#   - Creates iSCSI target with specified IQN
#   - Creates LUN mapping
#   - Optionally configures initiator ACL
#   - If no ACL specified, disables authentication (demo mode)
#   - Saves configuration
#   - Uses n_remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>              iSCSI Qualified Name (required)
#   --device <device>        Block device path (required)
#   --acl <initiator-iqn>    Optional: initiator IQN for ACL
#
# Returns:
#   0 on success
#   1 on invalid parameters or missing device
#   2 on targetcli failure
#
# Example usage:
#   # Simple target (no authentication)
#   n_lio_create --iqn iqn.2025-11.local.hps:vm-a-disk1 --device /dev/zvol/mypool/vol1
#
#   # Target with ACL
#   n_lio_create --iqn iqn.2025-11.local.hps:vm-a-disk1 \
#     --device /dev/zvol/mypool/vol1 \
#     --acl iqn.2025-11.local.hps:initiator-01
#
#===============================================================================
n_lio_create() {
  local iqn=""
  local device=""
  local acl=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iqn)
        iqn="$2"
        shift 2
        ;;
      --device)
        device="$2"
        shift 2
        ;;
      --acl)
        acl="$2"
        shift 2
        ;;
      *)
        n_remote_log "[LIO] ERROR: Unknown parameter: $1"
        return 1
        ;;
    esac
  done
  
  # Validate required parameters
  if [[ -z "$iqn" ]] || [[ -z "$device" ]]; then
    n_remote_log "[LIO] ERROR: Missing required parameters"
    n_remote_log "[LIO] Usage: n_lio_create --iqn <iqn> --device <device> [--acl <initiator-iqn>]"
    return 1
  fi
  
  # Check if device exists
  if [[ ! -e "$device" ]]; then
    n_remote_log "[LIO] ERROR: Device does not exist: $device"
    return 1
  fi
  
  n_remote_log "[LIO] Creating iSCSI target: $iqn"
  n_remote_log "[LIO] Device: $device"
  
  # Extract backstore name from IQN (use last part after colon)
  local backstore_name="${iqn##*:}"
  n_remote_log "[LIO] Backstore name: $backstore_name"
  
  # Create backstore
  n_remote_log "[LIO] Creating block backstore..."
  local bs_output
  bs_output=$(targetcli /backstores/block create name="${backstore_name}" dev="${device}" 2>&1)
  local bs_rc=$?
  
  if [[ $bs_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create backstore"
    n_remote_log "[LIO] Output: $bs_output"
    return 2
  fi
  
  n_remote_log "[LIO] Backstore created successfully"
  
  # Create iSCSI target
  n_remote_log "[LIO] Creating iSCSI target..."
  local target_output
  target_output=$(targetcli /iscsi create "${iqn}" 2>&1)
  local target_rc=$?
  
  if [[ $target_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create iSCSI target"
    n_remote_log "[LIO] Output: $target_output"
    # Cleanup backstore
    targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
    return 2
  fi
  
  n_remote_log "[LIO] iSCSI target created successfully"
  
  # Create LUN (using default TPG1)
  n_remote_log "[LIO] Creating LUN mapping..."
  local lun_output
  lun_output=$(targetcli "/iscsi/${iqn}/tpg1/luns" create "/backstores/block/${backstore_name}" 2>&1)
  local lun_rc=$?
  
  if [[ $lun_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create LUN"
    n_remote_log "[LIO] Output: $lun_output"
    # Cleanup
    targetcli /iscsi delete "${iqn}" 2>/dev/null
    targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
    return 2
  fi
  
  n_remote_log "[LIO] LUN created successfully"
  
  # Configure ACL or demo mode
  if [[ -n "$acl" ]]; then
    n_remote_log "[LIO] Configuring ACL for initiator: $acl"
    local acl_output
    acl_output=$(targetcli "/iscsi/${iqn}/tpg1/acls" create "${acl}" 2>&1)
    local acl_rc=$?
    
    if [[ $acl_rc -ne 0 ]]; then
      n_remote_log "[LIO] ERROR: Failed to create ACL"
      n_remote_log "[LIO] Output: $acl_output"
      # Cleanup
      targetcli /iscsi delete "${iqn}" 2>/dev/null
      targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
      return 2
    fi
    
    n_remote_log "[LIO] ACL configured successfully"
  else
    # Disable authentication for demo mode
    n_remote_log "[LIO] Configuring demo mode (no authentication)"
    targetcli "/iscsi/${iqn}/tpg1" set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
  fi
  
  # Save configuration
  n_remote_log "[LIO] Saving configuration..."
  targetcli saveconfig 2>&1 | while IFS= read -r line; do
    n_remote_log "[LIO]   $line"
  done
  
  n_remote_log "[LIO] Successfully created iSCSI target: $iqn"
  return 0
}

#===============================================================================
# n_lio_delete
# ------------
# Delete iSCSI target and associated backstore.
#
# Behaviour:
#   - Validates required parameter (iqn)
#   - Checks if target exists before deletion
#   - Deletes iSCSI target
#   - Deletes associated backstore if it exists
#   - Saves configuration
#   - Uses n_remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>  iSCSI Qualified Name (required)
#
# Returns:
#   0 on success
#   1 on invalid parameters or target not found
#   2 on targetcli failure
#
# Example usage:
#   n_lio_delete --iqn iqn.2025-11.local.hps:vm-a-disk1
#
#===============================================================================
n_lio_delete() {
  local iqn=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iqn)
        iqn="$2"
        shift 2
        ;;
      *)
        n_remote_log "[LIO] ERROR: Unknown parameter: $1"
        return 1
        ;;
    esac
  done
  
  # Validate required parameters
  if [[ -z "$iqn" ]]; then
    n_remote_log "[LIO] ERROR: Missing required parameter"
    n_remote_log "[LIO] Usage: n_lio_delete --iqn <iqn>"
    return 1
  fi
  
  n_remote_log "[LIO] Deleting iSCSI target: $iqn"
  
  # Extract backstore name from IQN
  local backstore_name="${iqn##*:}"
  
  # Check if target exists
  if ! targetcli /iscsi ls 2>/dev/null | grep -q "${iqn}"; then
    n_remote_log "[LIO] WARNING: iSCSI target does not exist: $iqn"
    return 1
  fi
  
  # Delete iSCSI target
  n_remote_log "[LIO] Deleting iSCSI target..."
  local target_output
  target_output=$(targetcli /iscsi delete "${iqn}" 2>&1)
  local target_rc=$?
  
  if [[ $target_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to delete iSCSI target"
    n_remote_log "[LIO] Output: $target_output"
    return 2
  fi
  
  n_remote_log "[LIO] iSCSI target deleted successfully"
  
  # Check if backstore exists before trying to delete
  if targetcli /backstores/block ls 2>/dev/null | grep -q "${backstore_name}"; then
    n_remote_log "[LIO] Deleting backstore: $backstore_name"
    local bs_output
    bs_output=$(targetcli /backstores/block delete "${backstore_name}" 2>&1)
    local bs_rc=$?
    
    if [[ $bs_rc -ne 0 ]]; then
      n_remote_log "[LIO] WARNING: Failed to delete backstore"
      n_remote_log "[LIO] Output: $bs_output"
    else
      n_remote_log "[LIO] Backstore deleted successfully"
    fi
  else
    n_remote_log "[LIO] Backstore does not exist, skipping: $backstore_name"
  fi
  
  # Save configuration
  n_remote_log "[LIO] Saving configuration..."
  targetcli saveconfig 2>&1 | while IFS= read -r line; do
    n_remote_log "[LIO]   $line"
  done
  
  n_remote_log "[LIO] Successfully deleted iSCSI target: $iqn"
  return 0
}

#===============================================================================
# n_lio_list
# ----------
# List all configured iSCSI targets and backstores.
#
# Behaviour:
#   - Lists all iSCSI targets
#   - Lists all block backstores
#   - Outputs to stdout for display or parsing
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#
# Example usage:
#   n_lio_list
#
#===============================================================================
n_lio_list() {
  echo "=== iSCSI Targets ==="
  targetcli /iscsi ls 2>/dev/null || echo "No targets configured"
  
  echo ""
  echo "=== Block Backstores ==="
  targetcli /backstores/block ls 2>/dev/null || echo "No backstores configured"
  
  return 0
}

#===============================================================================
# n_lio_status
# ------------
# Show complete LIO configuration tree.
#
# Behaviour:
#   - Displays full targetcli configuration tree
#   - Shows all targets, backstores, LUNs, ACLs
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#
# Example usage:
#   n_lio_status
#
#===============================================================================
n_lio_status() {
  echo "=== LIO Configuration ==="
  targetcli ls 2>/dev/null || echo "LIO not configured"
  
  return 0
}
#!/bin/bash
#===============================================================================
# HPS iSCSI/LIO Functions for Alpine Linux
# iSCSI target management for SCH (Storage Cluster Host) nodes
#===============================================================================

#===============================================================================
# n_lio_initialize
# ----------------
# Initialize LIO kernel subsystem.
#
# Behaviour:
#   - Mounts configfs at /sys/kernel/config if not mounted
#   - Loads required kernel modules: target_core_mod, target_core_iblock, iscsi_target_mod
#   - Verifies LIO is accessible via targetcli
#   - Logs progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on initialization failure
#
# Example usage:
#   n_lio_initialize
#
#===============================================================================
n_lio_initialize() {
  n_remote_log "[LIO] Initializing LIO kernel subsystem"
  
  # Check and mount configfs
  if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    n_remote_log "[LIO] Mounting configfs at /sys/kernel/config"
    
    if ! mount -t configfs configfs /sys/kernel/config 2>/dev/null; then
      n_remote_log "[LIO] ERROR: Failed to mount configfs"
      return 1
    fi
    
    n_remote_log "[LIO] configfs mounted successfully"
  else
    n_remote_log "[LIO] configfs already mounted"
  fi
  
  # Load required kernel modules in correct order
  local modules=(
    "target_core_mod"
    "target_core_iblock"
    "target_core_file"
    "target_core_pscsi"
    "iscsi_target_mod"
  )
  
  n_remote_log "[LIO] Loading kernel modules..."
  local failed=0
  
  for mod in "${modules[@]}"; do
    # Check if already loaded
    if lsmod | grep -q "^${mod} "; then
      n_remote_log "[LIO] Module already loaded: $mod"
      continue
    fi
    
    n_remote_log "[LIO] Loading module: $mod"
    if ! modprobe "$mod" 2>/dev/null; then
      n_remote_log "[LIO] WARNING: Could not load module: $mod (may be optional)"
    else
      n_remote_log "[LIO] Module loaded: $mod"
    fi
  done
  
  # Give kernel time to initialize
  sleep 1
  
  # Verify target directory exists in configfs
  if [[ ! -d /sys/kernel/config/target ]]; then
    n_remote_log "[LIO] ERROR: /sys/kernel/config/target directory not found"
    n_remote_log "[LIO] Kernel target subsystem not initialized"
    
    # Try to debug
    n_remote_log "[LIO] Available in configfs:"
    ls -la /sys/kernel/config/ 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
    
    return 1
  fi
  
  n_remote_log "[LIO] Target directory exists in configfs"
  
  # Verify LIO is accessible via targetcli
  n_remote_log "[LIO] Verifying LIO accessibility..."
  local targetcli_output
  targetcli_output=$(targetcli ls 2>&1)
  local targetcli_rc=$?
  
  if [[ $targetcli_rc -eq 0 ]]; then
    n_remote_log "[LIO] LIO subsystem initialized and accessible"
    return 0
  else
    n_remote_log "[LIO] ERROR: LIO subsystem not accessible after initialization"
    n_remote_log "[LIO] targetcli output: $targetcli_output"
    
    # Additional debugging
    n_remote_log "[LIO] Loaded modules:"
    lsmod | grep target 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
    
    return 1
  fi
}

#===============================================================================
# n_install_iscsi_packages
# -------------------------
# Install iSCSI target packages for Alpine Linux.
#
# Behaviour:
#   - Installs targetcli package (Alpine's iSCSI target management tool)
#   - Initializes LIO kernel subsystem
#   - Does NOT start any services (LIO is kernel-based)
#   - Verifies targetcli command is available
#   - Logs progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on installation failure
#
# Example usage:
#   n_install_iscsi_packages
#
#===============================================================================
n_install_iscsi_packages() {
  n_remote_log "[iSCSI] Installing iSCSI target packages"
  
  local packages=("targetcli")
  
  n_remote_log "[iSCSI] Packages to install: ${packages[*]}"
  
  if ! n_install_packages "${packages[@]}"; then
    n_remote_log "[iSCSI] ERROR: Failed to install iSCSI packages"
    return 1
  fi
  
  # Verify installation
  if ! command -v targetcli >/dev/null 2>&1; then
    n_remote_log "[iSCSI] ERROR: targetcli command not found after installation"
    return 1
  fi
  
  n_remote_log "[iSCSI] Successfully installed iSCSI packages"
  n_remote_log "[iSCSI] targetcli command: $(command -v targetcli)"
  
  # Initialize LIO
  if ! n_lio_initialize; then
    n_remote_log "[iSCSI] ERROR: Failed to initialize LIO subsystem"
    return 1
  fi
  
  return 0
}

#===============================================================================
# n_lio_create
# ------------
# Create iSCSI target with backstore and optional ACL.
#
# Behaviour:
#   - Validates required parameters (iqn, device)
#   - Creates block backstore from device
#   - Creates iSCSI target with specified IQN
#   - Creates LUN mapping
#   - Optionally configures initiator ACL
#   - If no ACL specified, disables authentication (demo mode)
#   - Saves configuration
#   - Uses n_remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>              iSCSI Qualified Name (required)
#   --device <device>        Block device path (required)
#   --acl <initiator-iqn>    Optional: initiator IQN for ACL
#
# Returns:
#   0 on success
#   1 on invalid parameters or missing device
#   2 on targetcli failure
#
# Example usage:
#   # Simple target (no authentication)
#   n_lio_create --iqn iqn.2025-11.local.hps:vm-a-disk1 --device /dev/zvol/mypool/vol1
#
#   # Target with ACL
#   n_lio_create --iqn iqn.2025-11.local.hps:vm-a-disk1 \
#     --device /dev/zvol/mypool/vol1 \
#     --acl iqn.2025-11.local.hps:initiator-01
#
#===============================================================================
n_lio_create() {
  local iqn=""
  local device=""
  local acl=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iqn)
        iqn="$2"
        shift 2
        ;;
      --device)
        device="$2"
        shift 2
        ;;
      --acl)
        acl="$2"
        shift 2
        ;;
      *)
        n_remote_log "[LIO] ERROR: Unknown parameter: $1"
        return 1
        ;;
    esac
  done
  
  # Validate required parameters
  if [[ -z "$iqn" ]] || [[ -z "$device" ]]; then
    n_remote_log "[LIO] ERROR: Missing required parameters"
    n_remote_log "[LIO] Usage: n_lio_create --iqn <iqn> --device <device> [--acl <initiator-iqn>]"
    return 1
  fi
  
  # Check if device exists
  if [[ ! -e "$device" ]]; then
    n_remote_log "[LIO] ERROR: Device does not exist: $device"
    return 1
  fi
  
  n_remote_log "[LIO] Creating iSCSI target: $iqn"
  n_remote_log "[LIO] Device: $device"
  
  # Extract backstore name from IQN (use last part after colon)
  local backstore_name="${iqn##*:}"
  n_remote_log "[LIO] Backstore name: $backstore_name"
  
  # Create backstore
  n_remote_log "[LIO] Creating block backstore..."
  local bs_output
  bs_output=$(targetcli /backstores/block create name="${backstore_name}" dev="${device}" 2>&1)
  local bs_rc=$?
  
  if [[ $bs_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create backstore"
    n_remote_log "[LIO] Output: $bs_output"
    return 2
  fi
  
  n_remote_log "[LIO] Backstore created successfully"
  
  # Create iSCSI target
  n_remote_log "[LIO] Creating iSCSI target..."
  local target_output
  target_output=$(targetcli /iscsi create "${iqn}" 2>&1)
  local target_rc=$?
  
  if [[ $target_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create iSCSI target"
    n_remote_log "[LIO] Output: $target_output"
    # Cleanup backstore
    targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
    return 2
  fi
  
  n_remote_log "[LIO] iSCSI target created successfully"
  
  # Create LUN (using default TPG1)
  n_remote_log "[LIO] Creating LUN mapping..."
  local lun_output
  lun_output=$(targetcli "/iscsi/${iqn}/tpg1/luns" create "/backstores/block/${backstore_name}" 2>&1)
  local lun_rc=$?
  
  if [[ $lun_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to create LUN"
    n_remote_log "[LIO] Output: $lun_output"
    # Cleanup
    targetcli /iscsi delete "${iqn}" 2>/dev/null
    targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
    return 2
  fi
  
  n_remote_log "[LIO] LUN created successfully"
  
  # Configure ACL or demo mode
  if [[ -n "$acl" ]]; then
    n_remote_log "[LIO] Configuring ACL for initiator: $acl"
    local acl_output
    acl_output=$(targetcli "/iscsi/${iqn}/tpg1/acls" create "${acl}" 2>&1)
    local acl_rc=$?
    
    if [[ $acl_rc -ne 0 ]]; then
      n_remote_log "[LIO] ERROR: Failed to create ACL"
      n_remote_log "[LIO] Output: $acl_output"
      # Cleanup
      targetcli /iscsi delete "${iqn}" 2>/dev/null
      targetcli /backstores/block delete "${backstore_name}" 2>/dev/null
      return 2
    fi
    
    n_remote_log "[LIO] ACL configured successfully"
  else
    # Disable authentication for demo mode
    n_remote_log "[LIO] Configuring demo mode (no authentication)"
    targetcli "/iscsi/${iqn}/tpg1" set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 2>&1 | while IFS= read -r line; do
      n_remote_log "[LIO]   $line"
    done
  fi
  
  # Save configuration
  n_remote_log "[LIO] Saving configuration..."
  targetcli saveconfig 2>&1 | while IFS= read -r line; do
    n_remote_log "[LIO]   $line"
  done
  
  n_remote_log "[LIO] Successfully created iSCSI target: $iqn"
  return 0
}

#===============================================================================
# n_lio_delete
# ------------
# Delete iSCSI target and associated backstore.
#
# Behaviour:
#   - Validates required parameter (iqn)
#   - Checks if target exists before deletion
#   - Deletes iSCSI target
#   - Deletes associated backstore if it exists
#   - Saves configuration
#   - Uses n_remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>  iSCSI Qualified Name (required)
#
# Returns:
#   0 on success
#   1 on invalid parameters or target not found
#   2 on targetcli failure
#
# Example usage:
#   n_lio_delete --iqn iqn.2025-11.local.hps:vm-a-disk1
#
#===============================================================================
n_lio_delete() {
  local iqn=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iqn)
        iqn="$2"
        shift 2
        ;;
      *)
        n_remote_log "[LIO] ERROR: Unknown parameter: $1"
        return 1
        ;;
    esac
  done
  
  # Validate required parameters
  if [[ -z "$iqn" ]]; then
    n_remote_log "[LIO] ERROR: Missing required parameter"
    n_remote_log "[LIO] Usage: n_lio_delete --iqn <iqn>"
    return 1
  fi
  
  n_remote_log "[LIO] Deleting iSCSI target: $iqn"
  
  # Extract backstore name from IQN
  local backstore_name="${iqn##*:}"
  
  # Check if target exists
  if ! targetcli /iscsi ls 2>/dev/null | grep -q "${iqn}"; then
    n_remote_log "[LIO] WARNING: iSCSI target does not exist: $iqn"
    return 1
  fi
  
  # Delete iSCSI target
  n_remote_log "[LIO] Deleting iSCSI target..."
  local target_output
  target_output=$(targetcli /iscsi delete "${iqn}" 2>&1)
  local target_rc=$?
  
  if [[ $target_rc -ne 0 ]]; then
    n_remote_log "[LIO] ERROR: Failed to delete iSCSI target"
    n_remote_log "[LIO] Output: $target_output"
    return 2
  fi
  
  n_remote_log "[LIO] iSCSI target deleted successfully"
  
  # Check if backstore exists before trying to delete
  if targetcli /backstores/block ls 2>/dev/null | grep -q "${backstore_name}"; then
    n_remote_log "[LIO] Deleting backstore: $backstore_name"
    local bs_output
    bs_output=$(targetcli /backstores/block delete "${backstore_name}" 2>&1)
    local bs_rc=$?
    
    if [[ $bs_rc -ne 0 ]]; then
      n_remote_log "[LIO] WARNING: Failed to delete backstore"
      n_remote_log "[LIO] Output: $bs_output"
    else
      n_remote_log "[LIO] Backstore deleted successfully"
    fi
  else
    n_remote_log "[LIO] Backstore does not exist, skipping: $backstore_name"
  fi
  
  # Save configuration
  n_remote_log "[LIO] Saving configuration..."
  targetcli saveconfig 2>&1 | while IFS= read -r line; do
    n_remote_log "[LIO]   $line"
  done
  
  n_remote_log "[LIO] Successfully deleted iSCSI target: $iqn"
  return 0
}

#===============================================================================
# n_lio_list
# ----------
# List all configured iSCSI targets and backstores.
#
# Behaviour:
#   - Lists all iSCSI targets
#   - Lists all block backstores
#   - Outputs to stdout for display or parsing
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#
# Example usage:
#   n_lio_list
#
#===============================================================================
n_lio_list() {
  echo "=== iSCSI Targets ==="
  targetcli /iscsi ls 2>/dev/null || echo "No targets configured"
  
  echo ""
  echo "=== Block Backstores ==="
  targetcli /backstores/block ls 2>/dev/null || echo "No backstores configured"
  
  return 0
}

#===============================================================================
# n_lio_status
# ------------
# Show complete LIO configuration tree.
#
# Behaviour:
#   - Displays full targetcli configuration tree
#   - Shows all targets, backstores, LUNs, ACLs
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#
# Example usage:
#   n_lio_status
#
#===============================================================================
n_lio_status() {
  echo "=== LIO Configuration ==="
  targetcli ls 2>/dev/null || echo "LIO not configured"
  
  return 0
}
