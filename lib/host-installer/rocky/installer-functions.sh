
#===============================================================================
# Rocky Linux Installer Functions
# For use during kickstart installation
#===============================================================================

#===============================================================================
# n_installer_detect_os_disk
# ---------------------------
# Detect 1-2 suitable disks for OS installation and store to IPS host config.
#
# Logic:
#   - Scans /sys/block for non-removable block devices
#   - Filters for disks >= 20GB
#   - Selects first 2 suitable disks (if available)
#   - Stores comma-separated disk list to IPS: n_remote_host_variable os_disk
#
# Behaviour:
#   - If 1 disk found: Single disk install
#   - If 2+ disks found: RAID1 install (uses first 2)
#   - Logs all decisions verbosely with [DEBUG] tag
#   - Fails fast if no suitable disk found
#
# Returns:
#   0 on success (1-2 disks found and stored)
#   1 if no suitable disk found
#
# Example usage:
#   n_installer_detect_os_disk
#
# Stores to IPS:
#   os_disk="/dev/sda" or os_disk="/dev/sda,/dev/sdb"
#
#===============================================================================
n_installer_detect_os_disk() {
  n_remote_log "[DEBUG] Starting OS disk detection"
  
  local suitable_disks=()
  local min_size_bytes=$((20 * 1024 * 1024 * 1024))  # 20GB in bytes
  
  # Scan all block devices
  for disk in /sys/block/*; do
    local dev_name=$(basename "$disk")
    local dev_path="/dev/$dev_name"
    
    n_remote_log "[DEBUG] Examining device: $dev_path"
    
    # Skip if removable
    if [[ -f "$disk/removable" ]] && [[ $(cat "$disk/removable") == "1" ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: removable device"
      continue
    fi
    
    # Skip if not a disk (e.g., loop, ram)
    if [[ ! "$dev_name" =~ ^(sd|hd|vd|nvme|xvd) ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: not a disk device"
      continue
    fi
    
    # Check size
    if [[ -f "$disk/size" ]]; then
      local size_sectors=$(cat "$disk/size")
      local size_bytes=$((size_sectors * 512))
      local size_gb=$((size_bytes / 1024 / 1024 / 1024))
      
      n_remote_log "[DEBUG] $dev_path size: ${size_gb}GB"
      
      if [[ $size_bytes -lt $min_size_bytes ]]; then
        n_remote_log "[DEBUG] Skipping $dev_path: too small (< 20GB)"
        continue
      fi
      
      # Disk is suitable
      n_remote_log "[DEBUG] $dev_path is suitable for OS installation"
      suitable_disks+=("$dev_path")
      
      # Stop after finding 2 disks
      if [[ ${#suitable_disks[@]} -eq 2 ]]; then
        n_remote_log "[DEBUG] Found 2 suitable disks, stopping search"
        break
      fi
    else
      n_remote_log "[DEBUG] Skipping $dev_path: cannot determine size"
    fi
  done
  
  # Check results
  local disk_count=${#suitable_disks[@]}
  n_remote_log "[DEBUG] Found $disk_count suitable disk(s)"
  
  if [[ $disk_count -eq 0 ]]; then
    n_remote_log "[ERROR] No suitable disk found for OS installation"
    n_remote_log "[ERROR] Requirements: non-removable, >= 20GB"
    return 1
  fi
  
  # Build comma-separated list
  local os_disk_value
  if [[ $disk_count -eq 1 ]]; then
    os_disk_value="${suitable_disks[0]}"
    n_remote_log "[DEBUG] Single disk install: $os_disk_value"
  else
    os_disk_value="${suitable_disks[0]},${suitable_disks[1]}"
    n_remote_log "[DEBUG] RAID1 install: $os_disk_value"
  fi
  
  # Store to IPS
  n_remote_log "[DEBUG] Storing os_disk to IPS: $os_disk_value"
  if ! n_remote_host_variable os_disk "$os_disk_value"; then
    n_remote_log "[ERROR] Failed to store os_disk to IPS"
    return 1
  fi
  
  n_remote_log "[DEBUG] OS disk detection complete: $os_disk_value"
  return 0
}


#===============================================================================
# n_installer_generate_partitioning
# ----------------------------------
# Generate kickstart partitioning commands based on detected disk(s).
#
# Behaviour:
#   - Reads os_disk from IPS: n_remote_host_variable os_disk
#   - If 1 disk: Standard partitioning
#   - If 2 disks: RAID1 (software RAID)
#   - Generates /tmp/part-include.ks for kickstart to include
#
# Partition Layout (20GB total):
#   - biosboot: 1MB (BIOS boot partition)
#   - /boot: 1GB (XFS, not in RAID for simplicity)
#   - /: 15GB (XFS, RAID1 if 2 disks)
#   - swap: 4GB (RAID1 if 2 disks)
#
# Returns:
#   0 on success (partitioning file created)
#   1 if os_disk not found or invalid
#
# Example usage:
#   n_installer_generate_partitioning
#
# Creates:
#   /tmp/part-include.ks (included by kickstart)
#
#===============================================================================
n_installer_generate_partitioning() {
  n_remote_log "[DEBUG] Starting partition layout generation"
  
  # Read os_disk from IPS
  local os_disk_value
  if ! os_disk_value=$(n_remote_host_variable os_disk); then
    n_remote_log "[ERROR] Failed to read os_disk from IPS"
    return 1
  fi
  
  if [[ -z "$os_disk_value" ]]; then
    n_remote_log "[ERROR] os_disk is empty in IPS config"
    return 1
  fi
  
  n_remote_log "[DEBUG] Retrieved os_disk from IPS: $os_disk_value"
  
  # Parse disk list
  IFS=',' read -ra disks <<< "$os_disk_value"
  local disk_count=${#disks[@]}
  
  n_remote_log "[DEBUG] Disk count: $disk_count"
  
  # Validate disk count
  if [[ $disk_count -eq 0 || $disk_count -gt 2 ]]; then
    n_remote_log "[ERROR] Invalid disk count: $disk_count (expected 1 or 2)"
    return 1
  fi
  
  local disk1="${disks[0]}"
  local disk2="${disks[1]:-}"
  
  n_remote_log "[DEBUG] Primary disk: $disk1"
  [[ -n "$disk2" ]] && n_remote_log "[DEBUG] Secondary disk: $disk2"
  
  # Start generating kickstart fragment
  local ks_file="/tmp/part-include.ks"
  n_remote_log "[DEBUG] Writing partitioning to $ks_file"
  
  {
    echo "# Generated by n_installer_generate_partitioning"
    echo "# OS Disk(s): $os_disk_value"
    echo ""
    
    if [[ $disk_count -eq 1 ]]; then
      # Single disk installation
      n_remote_log "[DEBUG] Generating single disk layout"
      
      echo "# Single disk installation"
      echo "ignoredisk --only-use=$disk1"
      echo "clearpart --all --initlabel --drives=$disk1"
      echo "bootloader --location=mbr --boot-drive=$disk1"
      echo ""
      echo "# Partitions (20GB total)"
      echo "part biosboot --fstype=biosboot --size=1 --ondisk=$disk1"
      echo "part /boot --fstype=xfs --size=1024 --ondisk=$disk1"
      echo "part / --fstype=xfs --size=15360 --ondisk=$disk1"
      echo "part swap --size=4096 --ondisk=$disk1"
      
    else
      # RAID1 installation
      n_remote_log "[DEBUG] Generating RAID1 layout"
      
      echo "# RAID1 installation"
      echo "ignoredisk --only-use=$disk1,$disk2"
      echo "clearpart --all --initlabel --drives=$disk1,$disk2"
      echo "bootloader --location=mbr --boot-drive=$disk1"
      echo ""
      echo "# RAID partitions (20GB total per disk)"
      echo "# /boot on primary disk only (not RAID for simplicity)"
      echo "part biosboot --fstype=biosboot --size=1 --ondisk=$disk1"
      echo "part /boot --fstype=xfs --size=1024 --ondisk=$disk1"
      echo ""
      echo "# RAID1 members"
      echo "part raid.01 --size=15360 --ondisk=$disk1"
      echo "part raid.02 --size=15360 --ondisk=$disk2"
      echo "part raid.11 --size=4096 --ondisk=$disk1"
      echo "part raid.12 --size=4096 --ondisk=$disk2"
      echo ""
      echo "# RAID devices"
      echo "raid / --fstype=xfs --device=md0 --level=1 raid.01 raid.02"
      echo "raid swap --device=md1 --level=1 raid.11 raid.12"
    fi
    
  } > "$ks_file"
  
  if [[ ! -f "$ks_file" ]]; then
    n_remote_log "[ERROR] Failed to create $ks_file"
    return 1
  fi
  
  n_remote_log "[DEBUG] Partition layout generated successfully"
  n_remote_log "[DEBUG] Contents of $ks_file:"
  while IFS= read -r line; do
    n_remote_log "[DEBUG]   $line"
  done < "$ks_file"
  
  return 0
}


#===============================================================================
# n_installer_configure_syslog
# -----------------------------
# Configure remote syslog during installation (called from %post).
#
# Behaviour:
#   - Configures systemd-journald for minimal volatile storage
#   - Configures rsyslog to forward all logs to IPS syslog server
#   - Disables local file logging
#   - Creates marker file /etc/syslog.remote
#
# Requirements:
#   - Must be run in %post (chrooted into installed system)
#   - Requires rsyslog package installed
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_installer_configure_syslog
#
#===============================================================================
n_installer_configure_syslog() {
  n_remote_log "[DEBUG] Configuring remote syslog"
  
  # Get IPS hostname/IP
  local ips_host
  if ! ips_host=$(n_get_provisioning_node); then
    n_remote_log "[ERROR] Cannot determine IPS host for syslog"
    return 1
  fi
  
  n_remote_log "[DEBUG] IPS syslog server: $ips_host"
  
  # Configure systemd-journald
  n_remote_log "[DEBUG] Configuring systemd-journald for volatile storage"
  
  cat > /etc/systemd/journald.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
ForwardToSyslog=yes
MaxLevelStore=err
EOF
  
  if [[ $? -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to write /etc/systemd/journald.conf"
    return 1
  fi
  
  n_remote_log "[DEBUG] systemd-journald configured"
  
  # Configure rsyslog for remote forwarding
  n_remote_log "[DEBUG] Configuring rsyslog remote forwarding"
  
  cat > /etc/rsyslog.d/01-remote.conf << EOF
# Forward all logs to remote syslog server
# Buffer messages if syslog server is unavailable
\$ActionQueueType LinkedList
\$ActionQueueFileName srvrfwd
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on

# Send everything to syslog host via TCP
*.* @@${ips_host}:514
EOF
  
  if [[ $? -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to write /etc/rsyslog.d/01-remote.conf"
    return 1
  fi
  
  n_remote_log "[DEBUG] rsyslog remote forwarding configured"
  
  # Disable local file logging
  n_remote_log "[DEBUG] Disabling local rsyslog file outputs"
  
  if [[ -f /etc/rsyslog.conf ]]; then
    sed -i 's/^\(.*\/var\/log\/.*\)/#\1/' /etc/rsyslog.conf
    n_remote_log "[DEBUG] Local file logging disabled in rsyslog.conf"
  fi
  
  # Enable rsyslog service
  n_remote_log "[DEBUG] Enabling rsyslog service"
  if ! systemctl enable rsyslog; then
    n_remote_log "[ERROR] Failed to enable rsyslog service"
    return 1
  fi
  
  # Remove persistent journal storage
  n_remote_log "[DEBUG] Removing persistent journal storage"
  rm -rf /var/log/journal
  
  # Create marker file
  n_remote_log "[DEBUG] Creating syslog marker file"
  touch /etc/syslog.remote
  
  n_remote_log "[DEBUG] Remote syslog configuration complete"
  return 0
}


#===============================================================================
# n_installer_configure_repos
# ----------------------------
# Configure Rocky Linux repositories pointing to IPS (called from %post).
#
# Behaviour:
#   - Creates repo files pointing to http://ips/distros/rocky-10/
#   - Configures BaseOS, AppStream, and HPS custom package repos
#   - Disables GPG checking (airgapped environment)
#
# Requirements:
#   - Must be run in %post (chrooted into installed system)
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_installer_configure_repos
#
#===============================================================================
n_installer_configure_repos() {
  n_remote_log "[DEBUG] Configuring Rocky repositories from IPS"
  
  local ips_host
  if ! ips_host=$(n_get_provisioning_node); then
    n_remote_log "[ERROR] Cannot determine IPS host for repositories"
    return 1
  fi
  
  n_remote_log "[DEBUG] IPS host: $ips_host"
  
  # Create BaseOS repo
  n_remote_log "[DEBUG] Creating BaseOS repository"
  cat > /etc/yum.repos.d/rocky-baseos-ips.repo << EOF
[baseos-ips]
name=Rocky Linux 10 - BaseOS (from IPS)
baseurl=http://${ips_host}/distros/rocky-10/BaseOS/
enabled=1
gpgcheck=0
EOF
  
  # Create AppStream repo
  n_remote_log "[DEBUG] Creating AppStream repository"
  cat > /etc/yum.repos.d/rocky-appstream-ips.repo << EOF
[appstream-ips]
name=Rocky Linux 10 - AppStream (from IPS)
baseurl=http://${ips_host}/distros/rocky-10/AppStream/
enabled=1
gpgcheck=0
EOF
  
  # Create HPS packages repo
  n_remote_log "[DEBUG] Creating HPS packages repository"
  cat > /etc/yum.repos.d/hps-packages.repo << EOF
[hps-packages]
name=HPS Custom Packages
baseurl=http://${ips_host}/packages/rocky-10/Repo/
enabled=1
gpgcheck=0
EOF
  
  # Disable default Rocky repos if they exist
  if [[ -d /etc/yum.repos.d ]]; then
    n_remote_log "[DEBUG] Disabling default Rocky repositories"
    for repo in /etc/yum.repos.d/rocky*.repo; do
      if [[ -f "$repo" ]] && [[ "$repo" != *"-ips.repo" ]]; then
        n_remote_log "[DEBUG] Disabling $repo"
        sed -i 's/^enabled=1/enabled=0/' "$repo" 2>/dev/null || true
      fi
    done
  fi
  
  n_remote_log "[DEBUG] Repository configuration complete"
  return 0
}
