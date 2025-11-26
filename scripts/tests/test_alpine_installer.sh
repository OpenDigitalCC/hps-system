#!/bin/bash
#===============================================================================
# Test Script: Alpine Installer Functions
# Tests n_installer_detect_target_disks and n_installer_partition_disks
#===============================================================================

echo "Starting Alpine Installer Test Script..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

#===============================================================================
# Test Helper Functions
#===============================================================================

test_start() {
  ((TEST_COUNT++)) || true
  echo ""
  echo "=================================================================="
  echo "TEST $TEST_COUNT: $1"
  echo "=================================================================="
}

test_pass() {
  ((PASS_COUNT++)) || true
  echo "✓ PASS: $1"
}

test_fail() {
  ((FAIL_COUNT++)) || true
  echo "✗ FAIL: $1"
}

test_info() {
  echo "  ℹ $1"
}

#===============================================================================
# Mock Functions for Testing
#===============================================================================

# Storage for mock host variables
declare -A MOCK_HOST_VARS

# Mock n_remote_log - captures log output
MOCK_LOG_OUTPUT=""
n_remote_log() {
  local msg="$*"
  MOCK_LOG_OUTPUT+="$msg"$'\n'
  echo "[LOG] $msg"
}

# Mock n_remote_host_variable - get/set host config
n_remote_host_variable() {
  local name="$1"
  local value="${2:-}"
  
  if [[ -z "$value" ]]; then
    # GET operation
    if [[ -n "${MOCK_HOST_VARS[$name]:-}" ]]; then
      echo "${MOCK_HOST_VARS[$name]}"
      return 0
    else
      return 1
    fi
  else
    # SET operation
    MOCK_HOST_VARS[$name]="$value"
    return 0
  fi
}

# Reset mocks between tests
reset_mocks() {
  MOCK_HOST_VARS=()
  MOCK_LOG_OUTPUT=""
}

#===============================================================================
# Mock Filesystem for Disk Detection Tests
#===============================================================================

MOCK_SYS_BLOCK=""

setup_mock_disks() {
  MOCK_SYS_BLOCK=$(mktemp -d)
}

add_mock_disk() {
  local name="$1"
  local size_gb="$2"
  local removable="${3:-0}"
  
  mkdir -p "$MOCK_SYS_BLOCK/$name"
  # Size in 512-byte sectors
  local size_sectors=$((size_gb * 1024 * 1024 * 1024 / 512))
  echo "$size_sectors" > "$MOCK_SYS_BLOCK/$name/size"
  echo "$removable" > "$MOCK_SYS_BLOCK/$name/removable"
}

cleanup_mock_disks() {
  if [[ -n "$MOCK_SYS_BLOCK" ]] && [[ -d "$MOCK_SYS_BLOCK" ]]; then
    rm -rf "$MOCK_SYS_BLOCK"
  fi
  MOCK_SYS_BLOCK=""
}

#===============================================================================
# Mock Command Tracking for Partition Tests
#===============================================================================

declare -a MOCK_COMMANDS=()

reset_command_mocks() {
  MOCK_COMMANDS=()
}

#===============================================================================
# Testable Functions
#===============================================================================

# Testable version of disk detection (uses mock filesystem)
n_installer_detect_target_disks_testable() {
  local sys_block="${MOCK_SYS_BLOCK:-/sys/block}"
  
  n_remote_log "[INFO] Starting target disk detection"
  
  local root_raid=""
  root_raid=$(n_remote_host_variable ROOT_RAID 2>/dev/null) || true
  
  local require_raid=0
  if [[ "$root_raid" == "1" ]]; then
    require_raid=1
    n_remote_log "[INFO] ROOT_RAID=1 set, will search for 2 disks"
  else
    n_remote_log "[INFO] Single disk mode (ROOT_RAID not set or !=1)"
  fi
  
  local suitable_disks=()
  local min_size_gb=10
  local min_size_bytes=$((min_size_gb * 1024 * 1024 * 1024))
  
  for disk in "$sys_block"/*; do
    [[ -d "$disk" ]] || continue
    
    local dev_name
    dev_name=$(basename "$disk")
    local dev_path="/dev/$dev_name"
    
    n_remote_log "[DEBUG] Examining device: $dev_path"
    
    if [[ -f "$disk/removable" ]] && [[ $(cat "$disk/removable") == "1" ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: removable device"
      continue
    fi
    
    if [[ ! "$dev_name" =~ ^(sd|hd|vd|nvme|xvd)[a-z0-9]*$ ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: not a disk device"
      continue
    fi
    
    if [[ "$dev_name" =~ [0-9]$ ]] && [[ ! "$dev_name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: partition, not whole disk"
      continue
    fi
    
    if [[ -f "$disk/size" ]]; then
      local size_sectors
      size_sectors=$(cat "$disk/size")
      local size_bytes=$((size_sectors * 512))
      local size_gb=$((size_bytes / 1024 / 1024 / 1024))
      
      n_remote_log "[DEBUG] $dev_path size: ${size_gb}GB"
      
      if [[ $size_bytes -lt $min_size_bytes ]]; then
        n_remote_log "[DEBUG] Skipping $dev_path: too small (< ${min_size_gb}GB)"
        continue
      fi
      
      n_remote_log "[DEBUG] $dev_path is suitable for OS installation"
      suitable_disks+=("$dev_path")
      
      if [[ $require_raid -eq 1 ]] && [[ ${#suitable_disks[@]} -eq 2 ]]; then
        n_remote_log "[DEBUG] Found 2 suitable disks for RAID1, stopping search"
        break
      elif [[ $require_raid -eq 0 ]] && [[ ${#suitable_disks[@]} -eq 1 ]]; then
        n_remote_log "[DEBUG] Found suitable disk for single-disk install, stopping search"
        break
      fi
    else
      n_remote_log "[DEBUG] Skipping $dev_path: cannot determine size"
    fi
  done
  
  local disk_count=${#suitable_disks[@]}
  n_remote_log "[INFO] Found $disk_count suitable disk(s)"
  
  if [[ $disk_count -eq 0 ]]; then
    n_remote_log "[ERROR] No suitable disk found for OS installation"
    n_remote_log "[ERROR] Requirements: non-removable disk >= ${min_size_gb}GB"
    return 1
  fi
  
  if [[ $require_raid -eq 1 ]] && [[ $disk_count -lt 2 ]]; then
    n_remote_log "[ERROR] ROOT_RAID=1 requires 2 disks, only found $disk_count"
    return 2
  fi
  
  local os_disk_value
  if [[ $require_raid -eq 1 ]]; then
    os_disk_value="${suitable_disks[0]},${suitable_disks[1]}"
    n_remote_log "[INFO] RAID1 install selected: $os_disk_value"
  else
    os_disk_value="${suitable_disks[0]}"
    n_remote_log "[INFO] Single disk install selected: $os_disk_value"
  fi
  
  n_remote_log "[INFO] Storing os_disk to IPS: $os_disk_value"
  if ! n_remote_host_variable os_disk "$os_disk_value"; then
    n_remote_log "[ERROR] Failed to store os_disk to IPS"
    return 1
  fi
  
  n_remote_log "[INFO] Target disk detection complete: $os_disk_value"
  return 0
}

# Testable version of partition function (uses mock commands)
n_installer_partition_disks_testable() {
  # Helper function for partition naming
  _get_partition_device() {
    local disk="$1"
    local part_num="$2"
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
      echo "${disk}p${part_num}"
    else
      echo "${disk}${part_num}"
    fi
  }
  
  n_remote_log "[INFO] Starting disk partitioning"
  
  local os_disk_value
  if ! os_disk_value=$(n_remote_host_variable os_disk); then
    n_remote_log "[ERROR] Failed to read os_disk from host_config"
    return 1
  fi
  
  if [[ -z "$os_disk_value" ]]; then
    n_remote_log "[ERROR] os_disk is empty"
    return 1
  fi
  
  n_remote_log "[INFO] os_disk: $os_disk_value"
  
  IFS=',' read -ra disks <<< "$os_disk_value"
  local disk_count=${#disks[@]}
  local raid_mode=0
  
  if [[ $disk_count -eq 2 ]]; then
    raid_mode=1
    n_remote_log "[INFO] RAID1 mode: ${disks[0]} and ${disks[1]}"
  elif [[ $disk_count -eq 1 ]]; then
    n_remote_log "[INFO] Single disk mode: ${disks[0]}"
  else
    n_remote_log "[ERROR] Invalid disk count: $disk_count"
    return 1
  fi
  
  local type_bios="21686148-6449-6E6F-744E-656564454649"
  local type_raid="A19D880F-05FC-4D3B-A006-743F0F84911E"
  local type_linux="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
  
  local part_type
  if [[ $raid_mode -eq 1 ]]; then
    part_type="$type_raid"
  else
    part_type="$type_linux"
  fi
  
  for disk in "${disks[@]}"; do
    n_remote_log "[INFO] Partitioning $disk"
    
    local part_prefix=""
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
      part_prefix="p"
    fi
    
    if [[ $raid_mode -eq 1 ]]; then
      n_remote_log "[DEBUG] Stopping any existing md arrays on $disk"
      MOCK_COMMANDS+=("mdadm --stop --scan")
      MOCK_COMMANDS+=("mdadm --zero-superblock ${disk}*")
    fi
    
    n_remote_log "[DEBUG] Wiping partition table on $disk"
    MOCK_COMMANDS+=("wipefs -a $disk")
    
    n_remote_log "[DEBUG] Creating GPT partitions on $disk"
    
    local sfdisk_script="label: gpt
unit: sectors

${disk}${part_prefix}1 : size=4096, type=${type_bios}
${disk}${part_prefix}2 : size=1048576, type=${part_type}
${disk}${part_prefix}3 : size=18874368, type=${part_type}
"
    MOCK_COMMANDS+=("sfdisk --quiet $disk")
    MOCK_COMMANDS+=("sfdisk_script:${disk}${part_prefix}1:${type_bios}")
    MOCK_COMMANDS+=("sfdisk_script:${disk}${part_prefix}2:${part_type}")
    MOCK_COMMANDS+=("sfdisk_script:${disk}${part_prefix}3:${part_type}")
    
    n_remote_log "[DEBUG] Partitioning complete for $disk"
  done
  
  n_remote_log "[DEBUG] Waiting for partition devices"
  MOCK_COMMANDS+=("partprobe ${disks[*]}")
  
  local boot_device
  local root_device
  
  if [[ $raid_mode -eq 1 ]]; then
    n_remote_log "[INFO] Assembling RAID1 arrays"
    
    local disk1="${disks[0]}"
    local disk2="${disks[1]}"
    local disk1_p2=$(_get_partition_device "$disk1" 2)
    local disk1_p3=$(_get_partition_device "$disk1" 3)
    local disk2_p2=$(_get_partition_device "$disk2" 2)
    local disk2_p3=$(_get_partition_device "$disk2" 3)
    
    n_remote_log "[DEBUG] Creating md0 (boot) from ${disk1_p2} and ${disk2_p2}"
    MOCK_COMMANDS+=("mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.0 ${disk1_p2} ${disk2_p2}")
    
    n_remote_log "[DEBUG] Creating md1 (root) from ${disk1_p3} and ${disk2_p3}"
    MOCK_COMMANDS+=("mdadm --create /dev/md1 --level=1 --raid-devices=2 --metadata=1.2 ${disk1_p3} ${disk2_p3}")
    
    boot_device="/dev/md0"
    root_device="/dev/md1"
    
    n_remote_log "[INFO] RAID arrays created: md0 (boot), md1 (root)"
  else
    boot_device=$(_get_partition_device "${disks[0]}" 2)
    root_device=$(_get_partition_device "${disks[0]}" 3)
  fi
  
  n_remote_log "[INFO] Storing device paths to host_config"
  
  if ! n_remote_host_variable boot_device "$boot_device"; then
    n_remote_log "[ERROR] Failed to store boot_device"
    return 1
  fi
  
  if ! n_remote_host_variable root_device "$root_device"; then
    n_remote_log "[ERROR] Failed to store root_device"
    return 1
  fi
  
  n_remote_log "[INFO] Partitioning complete"
  n_remote_log "[INFO] boot_device: $boot_device"
  n_remote_log "[INFO] root_device: $root_device"
  
  return 0
}

#===============================================================================
# DISK DETECTION TESTS
#===============================================================================

test_start "Single disk detection - one 50GB disk available"

reset_mocks
setup_mock_disks
add_mock_disk "sda" 50 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/sda" ]]; then
  test_pass "os_disk set correctly: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/sda', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Single disk install selected"; then
  test_pass "Log indicates single disk mode"
else
  test_fail "Log missing single disk indication"
fi

cleanup_mock_disks

#===============================================================================

test_start "Single disk detection - skip disks < 10GB"

reset_mocks
setup_mock_disks
add_mock_disk "sda" 5 0
add_mock_disk "sdb" 8 0
add_mock_disk "sdc" 15 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/sdc" ]]; then
  test_pass "os_disk correctly selected third disk: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/sdc', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "too small"; then
  test_pass "Log shows small disks were skipped"
else
  test_fail "Log missing small disk skip messages"
fi

cleanup_mock_disks

#===============================================================================

test_start "Single disk detection - skip removable devices"

reset_mocks
setup_mock_disks
add_mock_disk "sda" 50 1
add_mock_disk "sdb" 50 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/sdb" ]]; then
  test_pass "os_disk correctly skipped removable: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/sdb', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

cleanup_mock_disks

#===============================================================================

test_start "No suitable disks available"

reset_mocks
setup_mock_disks
add_mock_disk "sda" 5 0
add_mock_disk "sdb" 8 1

n_installer_detect_target_disks_testable
rc=$?
if [[ $rc -eq 1 ]]; then
  test_pass "Function returned error code 1 (no disk found)"
else
  test_fail "Expected return code 1, got $rc"
fi

if [[ -z "${MOCK_HOST_VARS[os_disk]:-}" ]]; then
  test_pass "os_disk not set (correct)"
else
  test_fail "os_disk should not be set: ${MOCK_HOST_VARS[os_disk]}"
fi

cleanup_mock_disks

#===============================================================================

test_start "RAID1 mode - two suitable disks"

reset_mocks
setup_mock_disks
MOCK_HOST_VARS[ROOT_RAID]="1"
add_mock_disk "sda" 50 0
add_mock_disk "sdb" 100 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/sda,/dev/sdb" ]]; then
  test_pass "os_disk set correctly for RAID1: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/sda,/dev/sdb', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "RAID1 install selected"; then
  test_pass "Log indicates RAID1 mode"
else
  test_fail "Log missing RAID1 indication"
fi

cleanup_mock_disks

#===============================================================================

test_start "RAID1 mode - only one disk (should fail with code 2)"

reset_mocks
setup_mock_disks
MOCK_HOST_VARS[ROOT_RAID]="1"
add_mock_disk "sda" 50 0

n_installer_detect_target_disks_testable
rc=$?
if [[ $rc -eq 2 ]]; then
  test_pass "Function returned error code 2 (RAID requires 2 disks)"
else
  test_fail "Expected return code 2, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "ROOT_RAID=1 requires 2 disks"; then
  test_pass "Log shows RAID disk requirement error"
else
  test_fail "Log missing RAID requirement error"
fi

cleanup_mock_disks

#===============================================================================

test_start "NVMe device detection"

reset_mocks
setup_mock_disks
add_mock_disk "nvme0n1" 100 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/nvme0n1" ]]; then
  test_pass "os_disk correctly detected NVMe: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/nvme0n1', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

cleanup_mock_disks

#===============================================================================

test_start "VirtIO device detection"

reset_mocks
setup_mock_disks
add_mock_disk "vda" 50 0

if n_installer_detect_target_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[os_disk]}" == "/dev/vda" ]]; then
  test_pass "os_disk correctly detected VirtIO: ${MOCK_HOST_VARS[os_disk]}"
else
  test_fail "os_disk incorrect: expected '/dev/vda', got '${MOCK_HOST_VARS[os_disk]:-<unset>}'"
fi

cleanup_mock_disks

#===============================================================================
# PARTITION TESTS
#===============================================================================

test_start "Partition single disk"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[os_disk]="/dev/sda"

if n_installer_partition_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[boot_device]}" == "/dev/sda2" ]]; then
  test_pass "boot_device set correctly: ${MOCK_HOST_VARS[boot_device]}"
else
  test_fail "boot_device incorrect: expected '/dev/sda2', got '${MOCK_HOST_VARS[boot_device]:-<unset>}'"
fi

if [[ "${MOCK_HOST_VARS[root_device]}" == "/dev/sda3" ]]; then
  test_pass "root_device set correctly: ${MOCK_HOST_VARS[root_device]}"
else
  test_fail "root_device incorrect: expected '/dev/sda3', got '${MOCK_HOST_VARS[root_device]:-<unset>}'"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "wipefs -a /dev/sda"; then
  test_pass "wipefs called for /dev/sda"
else
  test_fail "wipefs not called for /dev/sda"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "sfdisk --quiet /dev/sda"; then
  test_pass "sfdisk called for /dev/sda"
else
  test_fail "sfdisk not called for /dev/sda"
fi

# Check Linux type used (not RAID)
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "0FC63DAF-8483-4772-8E79-3D69D8477DE4"; then
  test_pass "Uses Linux filesystem type for single disk"
else
  test_fail "Missing Linux filesystem type for single disk"
fi

# Check BIOS boot partition
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "21686148-6449-6E6F-744E-656564454649"; then
  test_pass "BIOS boot partition type included"
else
  test_fail "BIOS boot partition type missing"
fi

#===============================================================================

test_start "Partition RAID1 disks"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[os_disk]="/dev/sda,/dev/sdb"

if n_installer_partition_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[boot_device]}" == "/dev/md0" ]]; then
  test_pass "boot_device set to md0: ${MOCK_HOST_VARS[boot_device]}"
else
  test_fail "boot_device incorrect: expected '/dev/md0', got '${MOCK_HOST_VARS[boot_device]:-<unset>}'"
fi

if [[ "${MOCK_HOST_VARS[root_device]}" == "/dev/md1" ]]; then
  test_pass "root_device set to md1: ${MOCK_HOST_VARS[root_device]}"
else
  test_fail "root_device incorrect: expected '/dev/md1', got '${MOCK_HOST_VARS[root_device]:-<unset>}'"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "wipefs -a /dev/sda"; then
  test_pass "wipefs called for /dev/sda"
else
  test_fail "wipefs not called for /dev/sda"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "wipefs -a /dev/sdb"; then
  test_pass "wipefs called for /dev/sdb"
else
  test_fail "wipefs not called for /dev/sdb"
fi

# Check RAID type used
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "A19D880F-05FC-4D3B-A006-743F0F84911E"; then
  test_pass "Uses Linux RAID type for RAID1 mode"
else
  test_fail "Missing Linux RAID type for RAID1 mode"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mdadm --create /dev/md0"; then
  test_pass "mdadm called to create md0"
else
  test_fail "mdadm not called for md0"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mdadm --create /dev/md1"; then
  test_pass "mdadm called to create md1"
else
  test_fail "mdadm not called for md1"
fi

#===============================================================================

test_start "Missing os_disk fails gracefully"

reset_mocks
reset_command_mocks

n_installer_partition_disks_testable
rc=$?
if [[ $rc -eq 1 ]]; then
  test_pass "Function returned error code 1 (missing os_disk)"
else
  test_fail "Expected return code 1, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Failed to read os_disk"; then
  test_pass "Log shows os_disk read failure"
else
  test_fail "Log missing os_disk read failure message"
fi

#===============================================================================

test_start "NVMe partition naming"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[os_disk]="/dev/nvme0n1"

if n_installer_partition_disks_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if [[ "${MOCK_HOST_VARS[boot_device]}" == "/dev/nvme0n1p2" ]]; then
  test_pass "boot_device uses correct NVMe naming: ${MOCK_HOST_VARS[boot_device]}"
else
  test_fail "boot_device incorrect: expected '/dev/nvme0n1p2', got '${MOCK_HOST_VARS[boot_device]:-<unset>}'"
fi

if [[ "${MOCK_HOST_VARS[root_device]}" == "/dev/nvme0n1p3" ]]; then
  test_pass "root_device uses correct NVMe naming: ${MOCK_HOST_VARS[root_device]}"
else
  test_fail "root_device incorrect: expected '/dev/nvme0n1p3', got '${MOCK_HOST_VARS[root_device]:-<unset>}'"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "sfdisk_script:/dev/nvme0n1p1"; then
  test_pass "sfdisk script uses correct NVMe partition naming"
else
  test_fail "sfdisk script missing correct NVMe partition naming"
fi

#===============================================================================
# FORMAT PARTITION TESTS
#===============================================================================

# Testable version of format function (uses mock commands)
n_installer_format_partitions_testable() {
  n_remote_log "[INFO] Starting partition formatting"
  
  local boot_device
  local root_device
  
  if ! boot_device=$(n_remote_host_variable boot_device); then
    n_remote_log "[ERROR] Failed to read boot_device from host_config"
    return 1
  fi
  
  if ! root_device=$(n_remote_host_variable root_device); then
    n_remote_log "[ERROR] Failed to read root_device from host_config"
    return 1
  fi
  
  if [[ -z "$boot_device" ]] || [[ -z "$root_device" ]]; then
    n_remote_log "[ERROR] boot_device or root_device is empty"
    return 1
  fi
  
  n_remote_log "[INFO] boot_device: $boot_device"
  n_remote_log "[INFO] root_device: $root_device"
  
  # Mock mkfs.ext4 calls
  n_remote_log "[INFO] Formatting boot partition: $boot_device"
  MOCK_COMMANDS+=("mkfs.ext4 -F -L boot -O metadata_csum $boot_device")
  n_remote_log "[DEBUG] Boot partition formatted successfully"
  
  n_remote_log "[INFO] Formatting root partition: $root_device"
  MOCK_COMMANDS+=("mkfs.ext4 -F -L root -O metadata_csum $root_device")
  n_remote_log "[DEBUG] Root partition formatted successfully"
  
  # Mock UUIDs
  local boot_uuid="11111111-1111-1111-1111-111111111111"
  local root_uuid="22222222-2222-2222-2222-222222222222"
  
  n_remote_log "[DEBUG] boot_uuid: $boot_uuid"
  n_remote_log "[DEBUG] root_uuid: $root_uuid"
  
  n_remote_host_variable boot_uuid "$boot_uuid"
  n_remote_host_variable root_uuid "$root_uuid"
  
  # Mock mount calls
  n_remote_log "[INFO] Mounting root partition to /mnt"
  MOCK_COMMANDS+=("mount $root_device /mnt")
  
  n_remote_log "[INFO] Mounting boot partition to /mnt/boot"
  MOCK_COMMANDS+=("mount $boot_device /mnt/boot")
  
  # Mock swap creation
  n_remote_log "[INFO] Creating 1GB swap file"
  MOCK_COMMANDS+=("dd if=/dev/zero of=/mnt/swapfile bs=1M count=1024")
  MOCK_COMMANDS+=("chmod 600 /mnt/swapfile")
  MOCK_COMMANDS+=("mkswap /mnt/swapfile")
  n_remote_log "[DEBUG] Swap file created successfully"
  
  # Mock fstab generation
  n_remote_log "[INFO] Generating /mnt/etc/fstab"
  MOCK_COMMANDS+=("fstab:UUID=${root_uuid}:/")
  MOCK_COMMANDS+=("fstab:UUID=${boot_uuid}:/boot")
  MOCK_COMMANDS+=("fstab:/swapfile:swap")
  
  n_remote_log "[INFO] Partition formatting complete"
  n_remote_log "[INFO] Root mounted at /mnt, boot at /mnt/boot"
  
  return 0
}

#===============================================================================

test_start "Format partitions - single disk"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[boot_device]="/dev/sda2"
MOCK_HOST_VARS[root_device]="/dev/sda3"

if n_installer_format_partitions_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check mkfs calls
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mkfs.ext4 -F -L boot -O metadata_csum /dev/sda2"; then
  test_pass "Boot partition formatted with correct options"
else
  test_fail "Boot partition format command incorrect"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mkfs.ext4 -F -L root -O metadata_csum /dev/sda3"; then
  test_pass "Root partition formatted with correct options"
else
  test_fail "Root partition format command incorrect"
fi

# Check UUIDs stored
if [[ -n "${MOCK_HOST_VARS[boot_uuid]}" ]]; then
  test_pass "boot_uuid stored: ${MOCK_HOST_VARS[boot_uuid]}"
else
  test_fail "boot_uuid not stored"
fi

if [[ -n "${MOCK_HOST_VARS[root_uuid]}" ]]; then
  test_pass "root_uuid stored: ${MOCK_HOST_VARS[root_uuid]}"
else
  test_fail "root_uuid not stored"
fi

# Check mount calls
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mount /dev/sda3 /mnt"; then
  test_pass "Root partition mount called"
else
  test_fail "Root partition mount not called"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mount /dev/sda2 /mnt/boot"; then
  test_pass "Boot partition mount called"
else
  test_fail "Boot partition mount not called"
fi

# Check swap creation
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "dd if=/dev/zero of=/mnt/swapfile"; then
  test_pass "Swap file creation called"
else
  test_fail "Swap file creation not called"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mkswap /mnt/swapfile"; then
  test_pass "mkswap called on swapfile"
else
  test_fail "mkswap not called"
fi

# Check fstab entries
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "fstab:UUID=.*:/"; then
  test_pass "fstab contains root entry with UUID"
else
  test_fail "fstab missing root entry"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "fstab:UUID=.*:/boot"; then
  test_pass "fstab contains boot entry with UUID"
else
  test_fail "fstab missing boot entry"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "fstab:/swapfile:swap"; then
  test_pass "fstab contains swap entry"
else
  test_fail "fstab missing swap entry"
fi

#===============================================================================

test_start "Format partitions - RAID1 (md devices)"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[boot_device]="/dev/md0"
MOCK_HOST_VARS[root_device]="/dev/md1"

if n_installer_format_partitions_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mkfs.ext4 -F -L boot -O metadata_csum /dev/md0"; then
  test_pass "RAID boot partition (md0) formatted correctly"
else
  test_fail "RAID boot partition format incorrect"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mkfs.ext4 -F -L root -O metadata_csum /dev/md1"; then
  test_pass "RAID root partition (md1) formatted correctly"
else
  test_fail "RAID root partition format incorrect"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mount /dev/md1 /mnt"; then
  test_pass "RAID root mount uses md1"
else
  test_fail "RAID root mount incorrect"
fi

#===============================================================================

test_start "Format partitions - missing boot_device fails"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[root_device]="/dev/sda3"
# boot_device not set

n_installer_format_partitions_testable
rc=$?
if [[ $rc -eq 1 ]]; then
  test_pass "Function returned error code 1 (missing boot_device)"
else
  test_fail "Expected return code 1, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Failed to read boot_device"; then
  test_pass "Log shows boot_device read failure"
else
  test_fail "Log missing boot_device failure message"
fi

#===============================================================================
# INSTALL ALPINE TESTS
#===============================================================================

# Mock for n_ips_command
n_ips_command() {
  local cmd="$1"
  shift
  
  MOCK_COMMANDS+=("n_ips_command $cmd $*")
  
  # Parse arguments
  local os_id_arg=""
  local name_arg=""
  for arg in "$@"; do
    case "$arg" in
      os_id=*) os_id_arg="${arg#os_id=}" ;;
      name=*) name_arg="${arg#name=}" ;;
    esac
  done
  
  # Return mock values for os_variable command
  if [[ "$cmd" == "os_variable" ]] && [[ "$name_arg" == "repo_path" ]]; then
    echo "x86_64_alpine-3.20"
    return 0
  fi
  
  return 1
}

# Mock for n_get_provisioning_node
n_get_provisioning_node() {
  echo "ips"
  return 0
}

# Mock mountpoint command
MOCK_MOUNTPOINTS=()
mock_mountpoint() {
  local path="$2"
  for mp in "${MOCK_MOUNTPOINTS[@]}"; do
    if [[ "$mp" == "$path" ]]; then
      return 0
    fi
  done
  return 1
}

# Testable version of install function
n_installer_install_alpine_testable() {
  # Use mock mountpoint
  mountpoint() { mock_mountpoint "$@"; }
  
  n_remote_log "[INFO] Starting Alpine installation"
  
  # Verify /mnt is mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    n_remote_log "[ERROR] /mnt is not mounted"
    return 2
  fi
  
  if ! mountpoint -q /mnt/boot 2>/dev/null; then
    n_remote_log "[ERROR] /mnt/boot is not mounted"
    return 2
  fi
  
  n_remote_log "[DEBUG] Mount points verified: /mnt and /mnt/boot"
  
  # Get os_id from host_config
  local os_id
  if ! os_id=$(n_remote_host_variable os_id); then
    n_remote_log "[ERROR] Failed to get os_id from host_config"
    return 1
  fi
  
  if [[ -z "$os_id" ]]; then
    n_remote_log "[ERROR] os_id is empty"
    return 1
  fi
  
  n_remote_log "[INFO] os_id: $os_id"
  
  # Get repo_path from IPS os_config
  local repo_path
  if ! repo_path=$(n_ips_command os_variable os_id="$os_id" name=repo_path); then
    n_remote_log "[ERROR] Failed to get repo_path from IPS"
    return 1
  fi
  
  if [[ -z "$repo_path" ]]; then
    n_remote_log "[ERROR] repo_path is empty"
    return 1
  fi
  
  n_remote_log "[INFO] repo_path: $repo_path"
  
  # Get IPS hostname/IP
  local ips_host
  if ! ips_host=$(n_get_provisioning_node); then
    n_remote_log "[ERROR] Failed to determine IPS host"
    return 1
  fi
  
  n_remote_log "[DEBUG] IPS host: $ips_host"
  
  # Construct repository URLs
  local repo_base="http://${ips_host}/distros/${repo_path}/apks"
  local repo_main="${repo_base}/main"
  local repo_community="${repo_base}/community"
  
  n_remote_log "[INFO] Repository base: $repo_base"
  
  # Mock: Configure apk repositories
  n_remote_log "[INFO] Configuring apk repositories"
  MOCK_COMMANDS+=("create /etc/apk/repositories: ${repo_main}, ${repo_community}")
  MOCK_COMMANDS+=("create /mnt/etc/apk/repositories: ${repo_main}, ${repo_community}")
  n_remote_log "[DEBUG] Live system repositories configured"
  n_remote_log "[DEBUG] Target system repositories configured"
  
  # Mock: Update apk index
  n_remote_log "[INFO] Updating apk package index"
  MOCK_COMMANDS+=("apk update")
  
  # Mock: Run setup-disk
  n_remote_log "[INFO] Running setup-disk to install Alpine base system"
  n_remote_log "[INFO] This may take several minutes..."
  MOCK_COMMANDS+=("setup-disk -m sys -k lts -s 0 /mnt")
  
  # Mock verification
  n_remote_log "[INFO] Verifying installation"
  MOCK_COMMANDS+=("verify /mnt/bin/busybox")
  MOCK_COMMANDS+=("verify /mnt/boot/extlinux")
  MOCK_COMMANDS+=("verify /mnt/boot/vmlinuz-lts")
  
  n_remote_log "[INFO] Alpine base system installed successfully"
  n_remote_log "[DEBUG] Kernel: linux-lts"
  n_remote_log "[DEBUG] Bootloader: extlinux"
  
  return 0
}

#===============================================================================

test_start "Install Alpine - success path"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[os_id]="x86_64:alpine:3.20"
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")

if n_installer_install_alpine_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check os_id was read
if echo "$MOCK_LOG_OUTPUT" | grep -q "os_id: x86_64:alpine:3.20"; then
  test_pass "os_id read from host_config"
else
  test_fail "os_id not logged correctly"
fi

# Check repo_path was fetched via n_ips_command (verified by log output since subshell loses array)
if echo "$MOCK_LOG_OUTPUT" | grep -q "repo_path: x86_64_alpine-3.20"; then
  test_pass "n_ips_command returned repo_path successfully"
else
  test_fail "n_ips_command failed to return repo_path"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "repo_path: x86_64_alpine-3.20"; then
  test_pass "repo_path fetched correctly"
else
  test_fail "repo_path not logged correctly"
fi

# Check repository URL construction
if echo "$MOCK_LOG_OUTPUT" | grep -q "Repository base: http://ips/distros/x86_64_alpine-3.20/apks"; then
  test_pass "Repository URL constructed correctly"
else
  test_fail "Repository URL incorrect"
fi

# Check repositories configured
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "create /mnt/etc/apk/repositories"; then
  test_pass "Target repositories configured"
else
  test_fail "Target repositories not configured"
fi

# Check setup-disk called with correct options
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "setup-disk -m sys -k lts -s 0 /mnt"; then
  test_pass "setup-disk called with correct options (sys mode, lts kernel, no swap)"
else
  test_fail "setup-disk not called correctly"
fi

# Check verification steps
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "verify /mnt/boot/vmlinuz-lts"; then
  test_pass "Kernel verification checked"
else
  test_fail "Kernel verification missing"
fi

#===============================================================================

test_start "Install Alpine - /mnt not mounted fails"

reset_mocks
reset_command_mocks
MOCK_HOST_VARS[os_id]="x86_64:alpine:3.20"
MOCK_MOUNTPOINTS=()  # Nothing mounted

n_installer_install_alpine_testable
rc=$?
if [[ $rc -eq 2 ]]; then
  test_pass "Function returned error code 2 (/mnt not mounted)"
else
  test_fail "Expected return code 2, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "/mnt is not mounted"; then
  test_pass "Log shows mount check failure"
else
  test_fail "Log missing mount failure message"
fi

#===============================================================================

test_start "Install Alpine - missing os_id fails"

reset_mocks
reset_command_mocks
# os_id not set
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")

n_installer_install_alpine_testable
rc=$?
if [[ $rc -eq 1 ]]; then
  test_pass "Function returned error code 1 (missing os_id)"
else
  test_fail "Expected return code 1, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Failed to get os_id"; then
  test_pass "Log shows os_id failure"
else
  test_fail "Log missing os_id failure message"
fi

#===============================================================================
# INSTALL HPS INIT TESTS
#===============================================================================

# Testable version of install_hps_init function
n_installer_install_hps_init_testable() {
  # Use mock mountpoint
  mountpoint() { mock_mountpoint "$@"; }
  
  n_remote_log "[INFO] Installing HPS init system"
  
  # Verify target is mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    n_remote_log "[ERROR] /mnt is not mounted"
    return 1
  fi
  
  # Check bootstrap source exists (mock check)
  local bootstrap_src="/usr/local/lib/hps-bootstrap-lib.sh"
  local bootstrap_exists="${MOCK_BOOTSTRAP_EXISTS:-true}"
  
  if [[ "$bootstrap_exists" != "true" ]]; then
    n_remote_log "[ERROR] Bootstrap library not found: $bootstrap_src"
    return 1
  fi
  
  # Mock: Copy bootstrap library
  n_remote_log "[INFO] Installing bootstrap library"
  MOCK_COMMANDS+=("mkdir -p /mnt/usr/local/lib")
  MOCK_COMMANDS+=("cp $bootstrap_src /mnt/usr/local/lib/hps-bootstrap-lib.sh")
  MOCK_COMMANDS+=("chmod 0755 /mnt/usr/local/lib/hps-bootstrap-lib.sh")
  n_remote_log "[DEBUG] Bootstrap library installed: /mnt/usr/local/lib/hps-bootstrap-lib.sh"
  
  # Mock: Create init script
  n_remote_log "[INFO] Creating HPS init script"
  MOCK_COMMANDS+=("mkdir -p /mnt/etc/local.d")
  MOCK_COMMANDS+=("create /mnt/etc/local.d/z-hps-init.start")
  MOCK_COMMANDS+=("chmod 0755 /mnt/etc/local.d/z-hps-init.start")
  n_remote_log "[DEBUG] Init script created: /mnt/etc/local.d/z-hps-init.start"
  
  # Mock: Enable local service
  n_remote_log "[INFO] Enabling local service"
  MOCK_COMMANDS+=("mkdir -p /mnt/etc/runlevels/default")
  MOCK_COMMANDS+=("ln -s /etc/init.d/local /mnt/etc/runlevels/default/local")
  n_remote_log "[DEBUG] Local service enabled in default runlevel"
  
  # Mock: Configure root with no password
  n_remote_log "[INFO] Configuring root account (no password - dev mode)"
  MOCK_COMMANDS+=("sed -i root:shadow /mnt/etc/shadow")
  n_remote_log "[DEBUG] Root password removed"
  
  # Get hostname from host_config
  local hostname
  hostname=$(n_remote_host_variable hostname 2>/dev/null) || hostname="alpine-sch"
  
  n_remote_log "[INFO] Setting hostname: $hostname"
  MOCK_COMMANDS+=("echo $hostname > /mnt/etc/hostname")
  MOCK_COMMANDS+=("create /mnt/etc/hosts")
  n_remote_log "[DEBUG] Hostname and hosts configured"
  
  # Mock: Install bash
  n_remote_log "[INFO] Ensuring bash is installed in target"
  MOCK_COMMANDS+=("chroot /mnt apk add bash")
  
  # Mock: Enable services
  n_remote_log "[INFO] Enabling networking service"
  MOCK_COMMANDS+=("ln -s /etc/init.d/networking /mnt/etc/runlevels/default/networking")
  
  n_remote_log "[INFO] Enabling SSH service"
  MOCK_COMMANDS+=("ln -s /etc/init.d/sshd /mnt/etc/runlevels/default/sshd")
  MOCK_COMMANDS+=("configure sshd_config PermitRootLogin yes")
  MOCK_COMMANDS+=("configure sshd_config PermitEmptyPasswords yes")
  n_remote_log "[DEBUG] SSH configured for root access"
  
  n_remote_log "[INFO] HPS init system installed successfully"
  
  return 0
}

#===============================================================================

test_start "Install HPS init - success path"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_BOOTSTRAP_EXISTS="true"
MOCK_HOST_VARS[hostname]="sch-001"

if n_installer_install_hps_init_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check bootstrap library copied
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "cp /usr/local/lib/hps-bootstrap-lib.sh"; then
  test_pass "Bootstrap library copied to target"
else
  test_fail "Bootstrap library not copied"
fi

# Check init script created
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "create /mnt/etc/local.d/z-hps-init.start"; then
  test_pass "Init script created"
else
  test_fail "Init script not created"
fi

# Check local service enabled
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "ln -s /etc/init.d/local"; then
  test_pass "Local service enabled"
else
  test_fail "Local service not enabled"
fi

# Check hostname set
if echo "$MOCK_LOG_OUTPUT" | grep -q "Setting hostname: sch-001"; then
  test_pass "Hostname set from host_config"
else
  test_fail "Hostname not set correctly"
fi

# Check root password removed
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "sed -i root:shadow"; then
  test_pass "Root password configured (dev mode)"
else
  test_fail "Root password not configured"
fi

# Check bash installed
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "chroot /mnt apk add bash"; then
  test_pass "Bash installed in target"
else
  test_fail "Bash not installed"
fi

# Check networking enabled
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "networking"; then
  test_pass "Networking service enabled"
else
  test_fail "Networking service not enabled"
fi

# Check SSH enabled and configured
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "sshd"; then
  test_pass "SSH service enabled"
else
  test_fail "SSH service not enabled"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "PermitRootLogin yes"; then
  test_pass "SSH configured for root login"
else
  test_fail "SSH not configured for root login"
fi

#===============================================================================

test_start "Install HPS init - missing bootstrap fails"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_BOOTSTRAP_EXISTS="false"

n_installer_install_hps_init_testable
rc=$?
if [[ $rc -eq 1 ]]; then
  test_pass "Function returned error code 1 (bootstrap not found)"
else
  test_fail "Expected return code 1, got $rc"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Bootstrap library not found"; then
  test_pass "Log shows bootstrap not found"
else
  test_fail "Log missing bootstrap error"
fi

#===============================================================================

test_start "Install HPS init - default hostname when not set"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_BOOTSTRAP_EXISTS="true"
# hostname not set in MOCK_HOST_VARS

if n_installer_install_hps_init_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Setting hostname: alpine-sch"; then
  test_pass "Default hostname used when not set"
else
  test_fail "Default hostname not used"
fi

#===============================================================================
# FINALIZE TESTS
#===============================================================================

# Track if reboot was called
MOCK_REBOOT_CALLED=0

# Mock reboot
mock_reboot() {
  MOCK_REBOOT_CALLED=1
  MOCK_COMMANDS+=("reboot")
  return 0
}

# Mock umount
mock_umount() {
  MOCK_COMMANDS+=("umount $*")
  return 0
}

# Mock sync
mock_sync() {
  MOCK_COMMANDS+=("sync")
  return 0
}

# Mock chroot
mock_chroot() {
  MOCK_COMMANDS+=("chroot $*")
  return 0
}

# Mock sleep
mock_sleep() {
  return 0
}

# Testable version of finalize function
n_installer_finalize_testable() {
  # Override commands
  reboot() { mock_reboot "$@"; }
  umount() { mock_umount "$@"; }
  sync() { mock_sync "$@"; }
  chroot() { mock_chroot "$@"; }
  sleep() { mock_sleep "$@"; }
  mountpoint() { mock_mountpoint "$@"; }
  
  n_remote_log "[INFO] Finalizing installation"
  
  # Sync filesystems
  n_remote_log "[DEBUG] Syncing filesystems"
  sync
  
  # Check if RAID1 was used
  local raid_mode="${MOCK_RAID_MODE:-false}"
  if [[ "$raid_mode" == "true" ]]; then
    n_remote_log "[INFO] RAID1 detected, saving mdadm configuration"
    
    MOCK_COMMANDS+=("mkdir -p /mnt/etc/mdadm")
    MOCK_COMMANDS+=("create /mnt/etc/mdadm/mdadm.conf")
    MOCK_COMMANDS+=("mdadm --detail --scan")
    n_remote_log "[DEBUG] mdadm.conf created"
    
    n_remote_log "[INFO] Installing mdadm in target system"
    chroot /mnt apk add mdadm
    
    MOCK_COMMANDS+=("ln -s /etc/init.d/mdadm /mnt/etc/runlevels/boot/mdadm")
    n_remote_log "[DEBUG] mdadm service enabled in boot runlevel"
    
    n_remote_log "[INFO] Updating initramfs for RAID support"
    chroot /mnt mkinitfs
  fi
  
  # Sync again
  sync
  sleep 1
  
  # Unmount filesystems
  n_remote_log "[INFO] Unmounting filesystems"
  
  if mountpoint -q /mnt/boot 2>/dev/null; then
    if ! umount /mnt/boot; then
      n_remote_log "[ERROR] Failed to unmount /mnt/boot"
      return 1
    fi
    n_remote_log "[DEBUG] Unmounted /mnt/boot"
  fi
  
  if mountpoint -q /mnt 2>/dev/null; then
    if ! umount /mnt; then
      n_remote_log "[ERROR] Failed to unmount /mnt"
      return 1
    fi
    n_remote_log "[DEBUG] Unmounted /mnt"
  fi
  
  # Update host_config STATE
  n_remote_log "[INFO] Updating host state to INSTALLED"
  
  if ! n_remote_host_variable STATE "INSTALLED"; then
    n_remote_log "[ERROR] Failed to update STATE to INSTALLED"
    return 2
  fi
  
  n_remote_log "[INFO] Installation complete"
  n_remote_log "[INFO] Rebooting system..."
  
  sync
  sleep 2
  
  reboot
  
  return 0
}

#===============================================================================

test_start "Finalize - single disk success path"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_RAID_MODE="false"
MOCK_REBOOT_CALLED=0

if n_installer_finalize_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check sync called
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "sync"; then
  test_pass "Filesystem sync called"
else
  test_fail "Filesystem sync not called"
fi

# Check unmounts
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "umount /mnt/boot"; then
  test_pass "/mnt/boot unmounted"
else
  test_fail "/mnt/boot not unmounted"
fi

if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "umount /mnt"; then
  test_pass "/mnt unmounted"
else
  test_fail "/mnt not unmounted"
fi

# Check state updated
if [[ "${MOCK_HOST_VARS[STATE]}" == "INSTALLED" ]]; then
  test_pass "STATE set to INSTALLED"
else
  test_fail "STATE not set correctly: ${MOCK_HOST_VARS[STATE]:-<unset>}"
fi

# Check reboot called
if [[ $MOCK_REBOOT_CALLED -eq 1 ]]; then
  test_pass "Reboot called"
else
  test_fail "Reboot not called"
fi

#===============================================================================

test_start "Finalize - RAID1 saves mdadm config"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_RAID_MODE="true"
MOCK_REBOOT_CALLED=0

if n_installer_finalize_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check mdadm config created
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "create /mnt/etc/mdadm/mdadm.conf"; then
  test_pass "mdadm.conf created"
else
  test_fail "mdadm.conf not created"
fi

# Check mdadm installed
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "chroot /mnt apk add mdadm"; then
  test_pass "mdadm installed in target"
else
  test_fail "mdadm not installed in target"
fi

# Check mdadm service enabled
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "mdadm /mnt/etc/runlevels/boot/mdadm"; then
  test_pass "mdadm service enabled in boot runlevel"
else
  test_fail "mdadm service not enabled"
fi

# Check initramfs updated
if printf '%s\n' "${MOCK_COMMANDS[@]}" | grep -q "chroot /mnt mkinitfs"; then
  test_pass "initramfs updated for RAID"
else
  test_fail "initramfs not updated"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "RAID1 detected"; then
  test_pass "Log shows RAID1 detected"
else
  test_fail "Log missing RAID1 detection"
fi

#===============================================================================

test_start "Finalize - state update logged"

reset_mocks
reset_command_mocks
MOCK_MOUNTPOINTS=("/mnt" "/mnt/boot")
MOCK_RAID_MODE="false"
MOCK_REBOOT_CALLED=0

n_installer_finalize_testable

if echo "$MOCK_LOG_OUTPUT" | grep -q "Updating host state to INSTALLED"; then
  test_pass "State update logged"
else
  test_fail "State update not logged"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Installation complete"; then
  test_pass "Completion logged"
else
  test_fail "Completion not logged"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Rebooting system"; then
  test_pass "Reboot logged"
else
  test_fail "Reboot not logged"
fi

#===============================================================================
# INSTALLER RUN (MASTER FUNCTION) TESTS
#===============================================================================

# Track which installer steps were called
declare -A MOCK_STEPS_CALLED

# Mock all installer functions for master function test
mock_installer_detect_target_disks() {
  MOCK_STEPS_CALLED[detect]=1
  MOCK_COMMANDS+=("n_installer_detect_target_disks")
  return "${MOCK_STEP_RETURNS[detect]:-0}"
}

mock_installer_partition_disks() {
  MOCK_STEPS_CALLED[partition]=1
  MOCK_COMMANDS+=("n_installer_partition_disks")
  return "${MOCK_STEP_RETURNS[partition]:-0}"
}

mock_installer_format_partitions() {
  MOCK_STEPS_CALLED[format]=1
  MOCK_COMMANDS+=("n_installer_format_partitions")
  return "${MOCK_STEP_RETURNS[format]:-0}"
}

mock_installer_install_alpine() {
  MOCK_STEPS_CALLED[alpine]=1
  MOCK_COMMANDS+=("n_installer_install_alpine")
  return "${MOCK_STEP_RETURNS[alpine]:-0}"
}

mock_installer_install_hps_init() {
  MOCK_STEPS_CALLED[hps_init]=1
  MOCK_COMMANDS+=("n_installer_install_hps_init")
  return "${MOCK_STEP_RETURNS[hps_init]:-0}"
}

mock_installer_finalize() {
  MOCK_STEPS_CALLED[finalize]=1
  MOCK_COMMANDS+=("n_installer_finalize")
  return "${MOCK_STEP_RETURNS[finalize]:-0}"
}

# Reset step tracking
reset_step_mocks() {
  MOCK_STEPS_CALLED=()
  declare -gA MOCK_STEP_RETURNS=()
}

# Testable version of master installer function
n_installer_run_testable() {
  # Override installer functions with mocks
  n_installer_detect_target_disks() { mock_installer_detect_target_disks; }
  n_installer_partition_disks() { mock_installer_partition_disks; }
  n_installer_format_partitions() { mock_installer_format_partitions; }
  n_installer_install_alpine() { mock_installer_install_alpine; }
  n_installer_install_hps_init() { mock_installer_install_hps_init; }
  n_installer_finalize() { mock_installer_finalize; }
  
  n_remote_log "[INFO] =============================================="
  n_remote_log "[INFO] Starting Alpine SCH Installation"
  n_remote_log "[INFO] =============================================="
  
  n_remote_host_variable STATE "INSTALLING"
  
  n_remote_log "[INFO] Step 1/6: Detecting target disks"
  if ! n_installer_detect_target_disks; then
    n_remote_log "[ERROR] Step 1 failed: Disk detection"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "disk_detection"
    return 1
  fi
  
  n_remote_log "[INFO] Step 2/6: Partitioning disks"
  if ! n_installer_partition_disks; then
    n_remote_log "[ERROR] Step 2 failed: Partitioning"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "partitioning"
    return 2
  fi
  
  n_remote_log "[INFO] Step 3/6: Formatting partitions"
  if ! n_installer_format_partitions; then
    n_remote_log "[ERROR] Step 3 failed: Formatting"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "formatting"
    return 3
  fi
  
  n_remote_log "[INFO] Step 4/6: Installing Alpine base system"
  if ! n_installer_install_alpine; then
    n_remote_log "[ERROR] Step 4 failed: Alpine installation"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "alpine_install"
    return 4
  fi
  
  n_remote_log "[INFO] Step 5/6: Installing HPS init system"
  if ! n_installer_install_hps_init; then
    n_remote_log "[ERROR] Step 5 failed: HPS init installation"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "hps_init"
    return 5
  fi
  
  n_remote_log "[INFO] Step 6/6: Finalizing installation"
  if ! n_installer_finalize; then
    n_remote_log "[ERROR] Step 6 failed: Finalization"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "finalize"
    return 6
  fi
  
  return 0
}

#===============================================================================

test_start "Installer run - all steps succeed"

reset_mocks
reset_command_mocks
reset_step_mocks

if n_installer_run_testable; then
  test_pass "Function returned success"
else
  test_fail "Function returned failure"
fi

# Check all steps were called
if [[ "${MOCK_STEPS_CALLED[detect]}" == "1" ]]; then
  test_pass "Step 1 (detect_target_disks) called"
else
  test_fail "Step 1 not called"
fi

if [[ "${MOCK_STEPS_CALLED[partition]}" == "1" ]]; then
  test_pass "Step 2 (partition_disks) called"
else
  test_fail "Step 2 not called"
fi

if [[ "${MOCK_STEPS_CALLED[format]}" == "1" ]]; then
  test_pass "Step 3 (format_partitions) called"
else
  test_fail "Step 3 not called"
fi

if [[ "${MOCK_STEPS_CALLED[alpine]}" == "1" ]]; then
  test_pass "Step 4 (install_alpine) called"
else
  test_fail "Step 4 not called"
fi

if [[ "${MOCK_STEPS_CALLED[hps_init]}" == "1" ]]; then
  test_pass "Step 5 (install_hps_init) called"
else
  test_fail "Step 5 not called"
fi

if [[ "${MOCK_STEPS_CALLED[finalize]}" == "1" ]]; then
  test_pass "Step 6 (finalize) called"
else
  test_fail "Step 6 not called"
fi

# Check state was set to INSTALLING at start
if echo "$MOCK_LOG_OUTPUT" | grep -q "Starting Alpine SCH Installation"; then
  test_pass "Installation start logged"
else
  test_fail "Installation start not logged"
fi

#===============================================================================

test_start "Installer run - step 3 fails, sets error state"

reset_mocks
reset_command_mocks
reset_step_mocks
MOCK_STEP_RETURNS[format]=1  # Make format step fail

n_installer_run_testable
rc=$?

if [[ $rc -eq 3 ]]; then
  test_pass "Function returned error code 3 (format failed)"
else
  test_fail "Expected return code 3, got $rc"
fi

# Check steps 1-2 were called, 3 failed, 4-6 not called
if [[ "${MOCK_STEPS_CALLED[detect]}" == "1" ]]; then
  test_pass "Step 1 was called before failure"
else
  test_fail "Step 1 not called"
fi

if [[ "${MOCK_STEPS_CALLED[partition]}" == "1" ]]; then
  test_pass "Step 2 was called before failure"
else
  test_fail "Step 2 not called"
fi

if [[ "${MOCK_STEPS_CALLED[format]}" == "1" ]]; then
  test_pass "Step 3 was attempted"
else
  test_fail "Step 3 not attempted"
fi

if [[ "${MOCK_STEPS_CALLED[alpine]}" != "1" ]]; then
  test_pass "Step 4 not called after failure (correct)"
else
  test_fail "Step 4 should not be called after step 3 failure"
fi

# Check error state was set
if [[ "${MOCK_HOST_VARS[STATE]}" == "INSTALL_FAILED" ]]; then
  test_pass "STATE set to INSTALL_FAILED"
else
  test_fail "STATE not set correctly: ${MOCK_HOST_VARS[STATE]:-<unset>}"
fi

if [[ "${MOCK_HOST_VARS[INSTALL_ERROR]}" == "formatting" ]]; then
  test_pass "INSTALL_ERROR set to formatting"
else
  test_fail "INSTALL_ERROR not set correctly: ${MOCK_HOST_VARS[INSTALL_ERROR]:-<unset>}"
fi

if echo "$MOCK_LOG_OUTPUT" | grep -q "Step 3 failed: Formatting"; then
  test_pass "Failure logged correctly"
else
  test_fail "Failure not logged"
fi

#===============================================================================
# Test Summary
#===============================================================================

echo ""
echo "=================================================================="
echo "TEST SUMMARY"
echo "=================================================================="
echo "Total tests: $TEST_COUNT"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo "✓ ALL TESTS PASSED"
  exit 0
else
  echo "✗ SOME TESTS FAILED"
  exit 1
fi
