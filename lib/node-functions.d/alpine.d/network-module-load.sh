


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
  
  echo "[NET] Detecting network interfaces requiring modules..."
  
  # Method 1: Check PCI devices for network controllers
  if command -v lspci >/dev/null 2>&1; then
    echo "[NET] Scanning PCI devices..."
    
    # Find network devices and their kernel modules
    lspci -nn | grep -E "(Network|Ethernet)" > /tmp/net-devices.$$ 2>/dev/null || true
    
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local pci_id module
      pci_id=$(echo "$line" | awk '{print $1}')
      
      # Get kernel module for this device
      module=$(lspci -k -s "$pci_id" 2>/dev/null | grep "Kernel modules:" | cut -d: -f2 | xargs)
      
      if [[ -n "$module" ]]; then
        for mod in $module; do
          if ! lsmod | grep -q "^$mod "; then
            echo "[NET] Loading module: $mod for device $pci_id"
            if modprobe "$mod" 2>/dev/null; then
              ((module_loaded++))
              # Add to /etc/modules for persistence
              if ! grep -q "^$mod$" /etc/modules 2>/dev/null; then
                echo "$mod" >> /etc/modules
              fi
            else
              echo "[NET] Failed to load module: $mod"
            fi
          else
            echo "[NET] Module already loaded: $mod"
          fi
        done
      fi
    done < /tmp/net-devices.$$
    
    rm -f /tmp/net-devices.$$
  else
    echo "[NET] lspci not found - install pciutils package"
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
  
  echo "[NET] Checking common network modules..."
  for mod in "${common_modules[@]}"; do
    # Check if hardware exists that might need this module
    if modinfo "$mod" >/dev/null 2>&1; then
      if ! lsmod | grep -q "^$mod "; then
        echo "[NET] Attempting to load: $mod"
        if modprobe "$mod" 2>/dev/null; then
          ((module_loaded++))
          # Check if it actually created an interface
          sleep 1
          # Use ip addr instead of ip link for BusyBox
          local iface_check=$(ip addr 2>/dev/null | grep -c "^[0-9]:" || echo 0)
          if [[ $iface_check -gt 0 ]]; then
            echo "[NET] Module $mod loaded successfully"
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
  echo "[NET] Checking for devices needing firmware..."
  dmesg | grep -i "firmware" | grep -iE "(eth|network|wifi)" > /tmp/firmware-msgs.$$ 2>/dev/null || true
  if [[ -s /tmp/firmware-msgs.$$ ]]; then
    sed 's/^/  /' /tmp/firmware-msgs.$$
  else
    echo "  No firmware messages found"
  fi
  rm -f /tmp/firmware-msgs.$$
  
  # List all network interfaces after loading (BusyBox compatible)
  echo "[NET] Current network interfaces:"
  # Use ip addr which works with BusyBox
  ip addr 2>/dev/null | grep "^[0-9]:" | awk -F': ' '{print "  " $2}' || echo "  Error listing interfaces"
  
  if [[ $module_loaded -gt 0 ]]; then
    echo "[NET] Loaded $module_loaded new network modules"
    return 0
  else
    echo "[NET] No new network modules needed"
    return 0
  fi
}

#===============================================================================
# n_list_network_interfaces
# --------------------------
# List network interfaces (BusyBox compatible).
#
# Usage:
#   n_list_network_interfaces
#===============================================================================
n_list_network_interfaces() {
  echo "[NET] Network interfaces:"
  # This works with BusyBox ip
  ip addr show 2>/dev/null | awk '
    /^[0-9]:/ { 
      iface = $2; 
      sub(/:$/, "", iface); 
      getline; 
      state = "DOWN";
      if ($0 ~ /state UP/) state = "UP";
      if ($0 ~ /state UNKNOWN/) state = "UNKNOWN";
      printf "  %-15s %s\n", iface, state
    }'
}

#===============================================================================
# n_check_network_hardware
# ------------------------
# Simple check for network hardware without process substitution.
#
# Usage:
#   n_check_network_hardware
#===============================================================================
n_check_network_hardware() {
  echo "[NET] Checking network hardware..."
  
  if command -v lspci >/dev/null 2>&1; then
    echo "[NET] PCI network devices:"
    lspci | grep -iE "(network|ethernet)" | sed 's/^/  /' || echo "  No PCI network devices found"
    
    echo "[NET] Loaded network modules:"
    lsmod | grep -E "(e1000|igb|virtio|r8169|vmxnet)" | sed 's/^/  /' || echo "  No common network modules loaded"
  else
    echo "[NET] Install pciutils package for hardware detection"
  fi
  
  # Check /sys for network devices
  echo "[NET] Network devices in /sys:"
  if [[ -d /sys/class/net ]]; then
    ls -1 /sys/class/net | sed 's/^/  /'
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

#===============================================================================
# n_setup_network_modules_alpine
# -------------------------------
# Complete network module setup for Alpine Linux.
#
# Usage:
#   n_setup_network_modules_alpine
#===============================================================================
n_setup_network_modules_alpine() {
  echo "[NET] Setting up network modules for Alpine..."
  
  # Ensure we have the tools we need
  local packages_needed=()
  command -v lspci >/dev/null 2>&1 || packages_needed+=("pciutils")
  command -v lsusb >/dev/null 2>&1 || packages_needed+=("usbutils")
  
  if [[ ${#packages_needed[@]} -gt 0 ]]; then
    echo "[NET] Installing required packages: ${packages_needed[*]}"
    if apk add --no-cache "${packages_needed[@]}"; then
      echo "[NET] Packages installed successfully"
    else
      echo "[NET] Failed to install packages"
    fi
  fi
  
  # Load modules
  n_auto_load_network_modules
  
  # Detect any missing drivers
  n_detect_missing_network_drivers
  
  # Ensure modules load at boot
  if [[ -f /etc/modules ]]; then
    echo "[NET] Modules configured for boot:"
    grep -E "(e1000|igb|ixgbe|r8169|virtio|vmxnet)" /etc/modules 2>/dev/null | sed 's/^/  /' || echo "  None found"
  fi
  
  # Ensure modules service is enabled
  if ! rc-status boot | grep -q modules; then
    echo "[NET] Enabling modules service at boot..."
    rc-update add modules boot
  fi
  
  echo "[NET] Network module setup complete"
}
