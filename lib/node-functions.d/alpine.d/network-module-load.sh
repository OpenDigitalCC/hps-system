
#===============================================================================
# n_ensure_modules_available
# --------------------------
# Ensure kernel modules are available before loading network drivers.
#
# Usage:
#   n_ensure_modules_available
#
# Returns:
#   0 if modules are available
#   1 if not available after all attempts
#===============================================================================
n_ensure_modules_available() {
  local kernel_ver=$(uname -r)
  local modules_dir="/lib/modules/${kernel_ver}"
  
  n_remote_log "[NET] Checking kernel modules availability for ${kernel_ver}"
  
  # Check if modules directory exists
  if [[ -d "${modules_dir}" ]] && [[ -f "${modules_dir}/modules.dep" ]]; then
    n_remote_log "[NET] Kernel modules already available"
    return 0
  fi
  
  n_remote_log "[NET] Kernel modules not available, attempting to make them available"
  
  # For Alpine diskless, modules might be in /media/*/boot/modloop
  local modloop_found=false
  for modloop in /media/*/boot/modloop-lts /media/*/boot/modloop-${kernel_ver}; do
    if [[ -f "$modloop" ]]; then
      n_remote_log "[NET] Found modloop at $modloop"
      modloop_found=true
      
      # Check if already mounted
      if ! mount | grep -q "/lib/modules"; then
        n_remote_log "[NET] Mounting modloop"
        mkdir -p /lib/modules
        if mount -o loop,ro "$modloop" /lib/modules; then
          n_remote_log "[NET] Successfully mounted modloop"
        else
          n_remote_log "[NET] Failed to mount modloop"
        fi
      fi
      break
    fi
  done
  
  # If no modloop found, try running modprobe to trigger mount
  if [[ "$modloop_found" == "false" ]]; then
    n_remote_log "[NET] No modloop found, trying modprobe to trigger mount"
    modprobe -n loop 2>/dev/null || true
  fi
  
  # Generate modules.dep if missing
  if [[ -d "${modules_dir}" ]] && [[ ! -f "${modules_dir}/modules.dep" ]]; then
    n_remote_log "[NET] Running depmod to generate modules.dep"
    if depmod -a 2>/dev/null; then
      n_remote_log "[NET] depmod completed successfully"
    else
      n_remote_log "[NET] depmod failed"
    fi
  fi
  
  # Final check
  if [[ -d "${modules_dir}" ]] && [[ -f "${modules_dir}/modules.dep" ]]; then
    n_remote_log "[NET] Kernel modules now available"
    return 0
  else
    n_remote_log "[NET] ERROR: Kernel modules still not available"
    return 1
  fi
}

#===============================================================================
# n_auto_load_network_modules_safe
# ---------------------------------
# Safe version that ensures modules are available first.
#
# Usage:
#   n_auto_load_network_modules_safe
#===============================================================================
n_auto_load_network_modules_safe() {
  # Ensure modules are available first
  if ! n_ensure_modules_available; then
    n_remote_log "[NET] Cannot load network modules - kernel modules not available"
    return 1
  fi
  
  # Now run the original function
  n_auto_load_network_modules
}


#===============================================================================
# n_auto_load_network_modules
# ---------------------------
# Automatically detect and load kernel modules for network interfaces.
#
# Usage:
#   n_auto_load_network_modules
#
# Behaviour:
#   - Scans for network devices that need modules
#   - Loads appropriate kernel modules
#   - Adds them to /etc/modules for persistence
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_auto_load_network_modules() {
  local module_loaded=0
  
  n_remote_log "[NET] Detecting network interfaces requiring modules..."
  
  # Method 1: Check PCI devices for network controllers
  if command -v lspci >/dev/null 2>&1; then
    n_remote_log "[NET] Scanning PCI devices..."
    
    # Find network devices and their kernel modules
    while IFS= read -r line; do
      local pci_id module
      pci_id=$(echo "$line" | awk '{print $1}')
      
      # Get kernel module for this device
      module=$(lspci -k -s "$pci_id" 2>/dev/null | grep "Kernel modules:" | cut -d: -f2 | xargs)
      
      if [[ -n "$module" ]]; then
        for mod in $module; do
          if ! lsmod | grep -q "^$mod "; then
            n_remote_log "[NET] Loading module: $mod for device $pci_id"
            if modprobe "$mod" 2>/dev/null; then
              ((module_loaded++))
              # Add to /etc/modules for persistence
              if ! grep -q "^$mod$" /etc/modules 2>/dev/null; then
                echo "$mod" >> /etc/modules
              fi
            else
              n_remote_log "[NET] Failed to load module: $mod"
            fi
          else
            n_remote_log "[NET] Module already loaded: $mod"
          fi
        done
      fi
    done < <(lspci -nn | grep -E "(Network|Ethernet)" || true)
  else
    n_remote_log "[NET] lspci not found - install pciutils package"
  fi
  
  # Method 2: Check for common network modules based on hardware
  local common_modules=(
    "e1000"      # Intel PRO/1000
    "e1000e"     # Intel PRO/1000 PCIe
    "igb"        # Intel Gigabit
    "ixgbe"      # Intel 10G
    "r8169"      # Realtek
    "virtio_net" # Virtual machines
    "vmxnet3"    # VMware
  )
  
  n_remote_log "[NET] Checking common network modules..."
  for mod in "${common_modules[@]}"; do
    # Check if hardware exists that might need this module
    if modinfo "$mod" >/dev/null 2>&1; then
      if ! lsmod | grep -q "^$mod "; then
        n_remote_log "[NET] Attempting to load: $mod"
        if modprobe "$mod" 2>/dev/null; then
          ((module_loaded++))
          # Check if it actually created an interface
          sleep 1
          local iface_count_after=$(ip link show 2>/dev/null | grep -c "^[0-9]:" || echo 0)
          if [[ $iface_count_after -gt 0 ]]; then
            n_remote_log "[NET] Module $mod loaded successfully"
            if ! grep -q "^$mod$" /etc/modules 2>/dev/null; then
              echo "$mod" >> /etc/modules
            fi
          else
            # Unload if it didn't create an interface
            modprobe -r "$mod" 2>/dev/null
          fi
        fi
      fi
    fi
  done
  
  # Method 3: Check dmesg for network devices needing firmware
  n_remote_log "[NET] Checking for devices needing firmware..."
  if dmesg | grep -i "firmware" | grep -iE "(eth|network|wifi)" > /tmp/firmware-msgs; then
    cat /tmp/firmware-msgs | sed 's/^/  /'
    rm -f /tmp/firmware-msgs
  else
    n_remote_log "  No firmware messages found"
  fi
  
  # List all network interfaces after loading (BusyBox compatible)
  n_remote_log "[NET] Current network interfaces:"
  ip link show 2>/dev/null | grep "^[0-9]:" | awk '{print "  " $2}' | sed 's/:$//'
  
  if [[ $module_loaded -gt 0 ]]; then
    n_remote_log "[NET] Loaded $module_loaded new network modules"
    return 0
  else
    n_remote_log "[NET] No new network modules needed"
    return 0
  fi
}



#===============================================================================
# n_detect_missing_network_drivers
# ---------------------------------
# Detect network hardware that's missing drivers.
#
# Usage:
#   n_detect_missing_network_drivers
#
# Output:
#   List of network devices without drivers
#===============================================================================
n_detect_missing_network_drivers() {
  echo "[NET] Checking for network devices without drivers..."
  
  # Check for unclaimed network devices using lshw if available
  if command -v lshw >/dev/null 2>&1; then
    lshw -C network -quiet 2>/dev/null | grep -B3 "UNCLAIMED" | grep -E "(product:|vendor:)" || echo "  No unclaimed devices found"
  fi
  
  # Check PCI devices without drivers
  if command -v lspci >/dev/null 2>&1; then
    echo "[NET] PCI network devices without drivers:"
    lspci -nn | grep -E "(Network|Ethernet)" | while IFS= read -r line; do
      local pci_id
      pci_id=$(echo "$line" | awk '{print $1}')
      if ! lspci -k -s "$pci_id" 2>/dev/null | grep -q "Kernel driver in use"; then
        echo "  $line"
        # Try to identify needed module
        local device_id
        device_id=$(echo "$line" | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tr -d '[]')
        if [[ -n "$device_id" ]]; then
          echo "    Device ID: $device_id"
        fi
      fi
    done
  else
    echo "  lspci not available - cannot check PCI devices"
  fi
}

