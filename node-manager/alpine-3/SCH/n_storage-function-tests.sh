#!/bin/bash
#===============================================================================
# HPS Storage Functions - Test Suite
# Tests for ZFS and iSCSI management functions
#===============================================================================

#===============================================================================
# n_test_sch_zfs_packages
# -----------------------
# Test ZFS package installation.
#
# Behaviour:
#   - Verifies all required ZFS packages are installed
#   - Checks for zfs and zpool commands
#   - Verifies critical ZFS binaries exist
#
# Returns:
#   0 on success (all tests pass)
#   1 on failure
#
# Example usage:
#   n_test_sch_zfs_packages
#
#===============================================================================
n_test_sch_zfs_packages() {
  echo "[TEST] Testing ZFS package installation"
  
  local required_packages=(
    "zfs"
    "zfs-lts"
    "zfs-udev"
    "zfs-libs"
  )
  
  local failed=0
  
  # Test 1: Verify packages installed
  echo "[TEST] Checking installed packages..."
  for pkg in "${required_packages[@]}"; do
    if apk info -e "$pkg" >/dev/null 2>&1; then
      echo "  ✓ Package installed: $pkg"
    else
      echo "  ✗ Package missing: $pkg"
      ((failed++))
    fi
  done
  
  # Test 2: Verify zfs command exists
  echo "[TEST] Checking zfs command..."
  if command -v zfs >/dev/null 2>&1; then
    echo "  ✓ zfs command found: $(command -v zfs)"
  else
    echo "  ✗ zfs command not found"
    ((failed++))
  fi
  
  # Test 3: Verify zpool command exists
  echo "[TEST] Checking zpool command..."
  if command -v zpool >/dev/null 2>&1; then
    echo "  ✓ zpool command found: $(command -v zpool)"
  else
    echo "  ✗ zpool command not found"
    ((failed++))
  fi
  
  # Test 4: Verify critical binaries
  echo "[TEST] Checking ZFS binaries..."
  local binaries=("/usr/sbin/zfs" "/usr/sbin/zpool" "/usr/sbin/zdb")
  for binary in "${binaries[@]}"; do
    if [[ -x "$binary" ]]; then
      echo "  ✓ Binary exists: $binary"
    else
      echo "  ✗ Binary missing: $binary"
      ((failed++))
    fi
  done
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All ZFS package tests passed"
    return 0
  else
    echo "[TEST] ✗ ZFS package tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_storage_all
# -----------------------
# Run complete storage test suite (ZFS + iSCSI).
#
# Behaviour:
#   - Runs all ZFS tests
#   - Runs all iSCSI tests
#   - Reports comprehensive results
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   n_test_sch_storage_all
#
#===============================================================================
n_test_sch_storage_all() {
  echo "============================================="
  echo "HPS Storage Functions - Complete Test Suite"
  echo "============================================="
  echo ""
  
  local failed=0
  
  # Run ZFS tests
  echo "[SUITE] Running ZFS test suite..."
  echo ""
  if ! n_test_sch_zpool_all; then
    ((failed++))
  fi
  
  echo ""
  echo "============================================="
  echo ""
  
  # Run iSCSI tests
  echo "[SUITE] Running iSCSI test suite..."
  echo ""
  if ! n_test_sch_iscsi_all; then
    ((failed++))
  fi
  
  # Overall summary
  echo ""
  echo "============================================="
  echo "Complete Test Suite Summary"
  echo "============================================="
  if [[ $failed -eq 0 ]]; then
    echo "✓ All storage tests passed (ZFS + iSCSI)"
    echo "============================================="
    return 0
  else
    echo "✗ Storage tests failed: $failed test suites"
    echo "============================================="
    return 1
  fi
}

#===============================================================================
# iSCSI Target Tests
#===============================================================================

#===============================================================================
# n_test_sch_iscsi_packages
# --------------------------
# Test iSCSI package installation and LIO initialization.
#
# Behaviour:
#   - Verifies targetcli and targetcli-openrc packages installed
#   - Checks for targetcli command
#   - Verifies LIO subsystem is initialized
#   - Checks configfs is mounted
#   - Verifies kernel modules loaded
#   - Checks targetcli service is running
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_test_sch_iscsi_packages
#
#===============================================================================
n_test_sch_iscsi_packages() {
  echo "[TEST] Testing iSCSI package installation"
  
  local failed=0
  
  # Test 1: Verify packages installed
  echo "[TEST] Checking installed packages..."
  if apk info -e targetcli >/dev/null 2>&1; then
    echo "  ✓ Package installed: targetcli"
  else
    echo "  ✗ Package missing: targetcli"
    ((failed++))
  fi
  
  if apk info -e targetcli-openrc >/dev/null 2>&1; then
    echo "  ✓ Package installed: targetcli-openrc"
  else
    echo "  ✗ Package missing: targetcli-openrc"
    ((failed++))
  fi
  
  # Test 2: Verify targetcli command exists
  echo "[TEST] Checking targetcli command..."
  if command -v targetcli >/dev/null 2>&1; then
    echo "  ✓ targetcli command found: $(command -v targetcli)"
  else
    echo "  ✗ targetcli command not found"
    ((failed++))
  fi
  
  # Test 3: Verify configfs is mounted
  echo "[TEST] Checking configfs..."
  if mountpoint -q /sys/kernel/config 2>/dev/null; then
    echo "  ✓ configfs mounted at /sys/kernel/config"
  else
    echo "  ✗ configfs not mounted"
    ((failed++))
  fi
  
  # Test 4: Verify kernel modules loaded
  echo "[TEST] Checking kernel modules..."
  local modules=("target_core_mod" "target_core_iblock" "iscsi_target_mod")
  for mod in "${modules[@]}"; do
    if lsmod | grep -q "^${mod} "; then
      echo "  ✓ Module loaded: $mod"
    else
      echo "  ✗ Module not loaded: $mod"
      ((failed++))
    fi
  done
  
  # Test 5: Verify targetcli service running
  echo "[TEST] Checking targetcli service..."
  if rc-service targetcli status >/dev/null 2>&1; then
    echo "  ✓ targetcli service is running"
  else
    echo "  ✗ targetcli service not running"
    ((failed++))
  fi
  
  # Test 6: Verify targetcli runs
  echo "[TEST] Testing targetcli execution..."
  if targetcli ls >/dev/null 2>&1; then
    echo "  ✓ targetcli executes successfully"
  else
    echo "  ✗ targetcli execution failed"
    ((failed++))
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All iSCSI package tests passed"
    return 0
  else
    echo "[TEST] ✗ iSCSI package tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_lio_create
# ----------------------
# Test iSCSI target creation validation.
#
# Behaviour:
#   - Tests argument validation
#   - Tests missing parameter detection
#   - Tests device validation
#   - Does NOT create actual targets (use live test for that)
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_test_sch_lio_create
#
#===============================================================================
n_test_sch_lio_create() {
  echo "[TEST] Testing LIO create function validation"
  
  local failed=0
  
  # Test 1: Missing --iqn
  echo "[TEST] Testing missing --iqn..."
  if n_lio_create --device /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect missing --iqn"
    ((failed++))
  else
    echo "  ✓ Correctly detected missing --iqn"
  fi
  
  # Test 2: Missing --device
  echo "[TEST] Testing missing --device..."
  if n_lio_create --iqn iqn.2025-11.test:test 2>/dev/null; then
    echo "  ✗ Failed to detect missing --device"
    ((failed++))
  else
    echo "  ✓ Correctly detected missing --device"
  fi
  
  # Test 3: Non-existent device
  echo "[TEST] Testing non-existent device..."
  if n_lio_create --iqn iqn.2025-11.test:test --device /dev/nonexistent 2>/dev/null; then
    echo "  ✗ Failed to detect non-existent device"
    ((failed++))
  else
    echo "  ✓ Correctly detected non-existent device"
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All LIO create validation tests passed"
    return 0
  else
    echo "[TEST] ✗ LIO create validation tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_lio_live
# -------------------
# Test actual iSCSI target creation with zvol or loop device.
#
# Behaviour:
#   - Creates a test zvol in existing pool OR loop device
#   - Creates iSCSI target
#   - Verifies target visible in targetcli
#   - Deletes target
#   - Cleans up zvol/loop device
#   - Only runs if root and ZFS pool available
#
# Returns:
#   0 on success
#   1 on failure
#   2 if skipped (not root or no pool)
#
# Example usage:
#   n_test_sch_lio_live
#
#===============================================================================
n_test_sch_lio_live() {
  echo "[TEST] Testing live iSCSI target creation"
  
  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    echo "  ⚠ Skipping live test (requires root)"
    return 2
  fi
  
  local failed=0
  local test_device=""
  local cleanup_type=""
  local test_iqn="iqn.2025-11.hps.test:test-$(date +%s)${RANDOM}"
  
  echo "[TEST] Creating test block device..."
  
  # Try to use existing ZFS pool for test zvol
  local pool_name
  pool_name=$(zpool list -H -o name 2>/dev/null | head -n1)
  
  if [[ -n "$pool_name" ]]; then
    local test_zvol="${pool_name}/test-lio-$(date +%s)"
    
    if zfs create -V 100M "$test_zvol" 2>/dev/null; then
      test_device="/dev/zvol/${test_zvol}"
      cleanup_type="zvol"
      echo "  ✓ Created test zvol: $test_zvol"
    else
      echo "  ⚠ Failed to create test zvol"
    fi
  fi
  
  # Fallback to loop device if zvol creation failed
  if [[ -z "$test_device" ]]; then
    if ! command -v losetup >/dev/null 2>&1; then
      echo "  ⚠ Skipping live test (no ZFS pool and losetup not available)"
      return 2
    fi
    
    local test_file="/tmp/lio-test-$(date +%s).img"
    truncate -s 100M "$test_file"
    test_device=$(losetup -f --show "$test_file")
    cleanup_type="loop"
    echo "  ✓ Created test loop device: $test_device"
  fi
  
  # Test target creation
  echo "[TEST] Creating iSCSI target: $test_iqn"
  if ! n_lio_create --iqn "$test_iqn" --device "$test_device"; then
    echo "  ✗ Failed to create iSCSI target"
    ((failed++))
  else
    echo "  ✓ Target creation succeeded"
    
    # Verify target exists
    if targetcli /iscsi ls 2>/dev/null | grep -q "$test_iqn"; then
      echo "  ✓ Target is visible in targetcli"
    else
      echo "  ✗ Target not found in targetcli"
      ((failed++))
    fi
    
    # Test target deletion
    echo "[TEST] Deleting iSCSI target..."
    if ! n_lio_delete --iqn "$test_iqn"; then
      echo "  ✗ Failed to delete target"
      ((failed++))
    else
      echo "  ✓ Target deletion succeeded"
      
      # Verify target gone
      if targetcli /iscsi ls 2>/dev/null | grep -q "$test_iqn"; then
        echo "  ✗ Target still exists after deletion"
        ((failed++))
      else
        echo "  ✓ Target successfully removed"
      fi
    fi
  fi
  
  # Cleanup
  echo "[TEST] Cleaning up..."
  
  if [[ "$cleanup_type" == "zvol" ]]; then
    local zvol_name="${test_device#/dev/zvol/}"
    if zfs destroy "$zvol_name" 2>/dev/null; then
      echo "  ✓ Test zvol destroyed"
    else
      echo "  ⚠ Failed to destroy test zvol"
    fi
  elif [[ "$cleanup_type" == "loop" ]]; then
    if losetup -d "$test_device" 2>/dev/null; then
      echo "  ✓ Loop device detached"
    fi
    local test_file="/tmp/lio-test-*.img"
    rm -f $test_file 2>/dev/null
    echo "  ✓ Test file removed"
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ Live iSCSI target test passed"
    return 0
  else
    echo "[TEST] ✗ Live iSCSI target test failed"
    return 1
  fi
}

#===============================================================================
# n_test_sch_iscsi_all
# ---------------------
# Run all iSCSI tests in sequence.
#
# Behaviour:
#   - Runs iSCSI package tests
#   - Runs LIO create validation tests
#   - Runs live target creation test (optional)
#   - Reports overall results
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   n_test_sch_iscsi_all
#
#===============================================================================
n_test_sch_iscsi_all() {
  echo "==========================================="
  echo "HPS Storage Functions - iSCSI Test Suite"
  echo "==========================================="
  echo ""
  
  local failed=0
  
  # Run package tests
  if ! n_test_sch_iscsi_packages; then
    ((failed++))
  fi
  
  echo ""
  
  # Run LIO create validation tests
  if ! n_test_sch_lio_create; then
    ((failed++))
  fi
  
  echo ""
  
  # Run live test (optional, requires root)
  echo "[TEST] Running optional live iSCSI target test..."
  local live_rc
  n_test_sch_lio_live
  live_rc=$?
  
  if [[ $live_rc -eq 0 ]]; then
    echo "  ✓ Live test passed"
  elif [[ $live_rc -eq 2 ]]; then
    echo "  ⚠ Live test skipped (not root or no pool/loop support)"
  else
    echo "  ✗ Live test failed"
    ((failed++))
  fi
  
  # Overall summary
  echo ""
  echo "==========================================="
  if [[ $failed -eq 0 ]]; then
    echo "✓ All iSCSI tests passed"
    echo "==========================================="
    return 0
  else
    echo "✗ iSCSI tests failed: $failed test suites"
    echo "==========================================="
    return 1
  fi
}

#===============================================================================
# n_test_sch_zpool_create_on_free_disk
# -------------------------------------
# Test high-level pool creation wrapper.
#
# Behaviour:
#   - Tests helper function availability
#   - Tests pool name generation
#   - Tests free disk detection
#   - Tests dry-run mode
#   - Does NOT create actual pools (use --dry-run)
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_test_sch_zpool_create_on_free_disk
#
#===============================================================================
n_test_sch_zpool_create_on_free_disk() {
  echo "[TEST] Testing zpool_create_on_free_disk wrapper"
  
  local failed=0
  
  # Test 1: Check helper functions exist
  echo "[TEST] Checking helper functions..."
  
  local helpers=("zpool_slug" "zpool_name_generate" "disks_free_list_simple" "zfs_get_defaults")
  for func in "${helpers[@]}"; do
    if command -v "$func" >/dev/null 2>&1; then
      echo "  ✓ Function available: $func"
    else
      echo "  ✗ Function missing: $func"
      ((failed++))
    fi
  done
  
  # Test 2: Test zpool_slug function
  echo "[TEST] Testing zpool_slug..."
  local slug_result
  slug_result=$(zpool_slug "Test-Cluster-123!" 12)
  
  if [[ "$slug_result" == "test-cluster" ]]; then
    echo "  ✓ zpool_slug works correctly"
  else
    echo "  ✗ zpool_slug returned unexpected: $slug_result"
    ((failed++))
  fi
  
  # Test 3: Test zpool_name_generate
  echo "[TEST] Testing zpool_name_generate..."
  local pool_name
  pool_name=$(zpool_name_generate ssd 2>/dev/null)
  
  if [[ -n "$pool_name" ]] && [[ "$pool_name" =~ ^z[a-z0-9-]+-pssd-u[0-9a-f]+$ ]]; then
    echo "  ✓ zpool_name_generate works: $pool_name"
  else
    echo "  ✗ zpool_name_generate returned invalid: $pool_name"
    ((failed++))
  fi
  
  # Test invalid class
  if zpool_name_generate invalid 2>/dev/null; then
    echo "  ✗ Failed to detect invalid pool class"
    ((failed++))
  else
    echo "  ✓ Correctly rejected invalid pool class"
  fi
  
  # Test 4: Test disks_free_list_simple
  echo "[TEST] Testing disks_free_list_simple..."
  local free_disks
  free_disks=$(disks_free_list_simple)
  
  if [[ -n "$free_disks" ]]; then
    echo "  ✓ Found free disks:"
    echo "$free_disks" | while IFS= read -r disk; do
      echo "      $disk"
    done
  else
    echo "  ⚠ No free disks found (may be expected if all disks in use)"
  fi
  
  # Test 5: Test zfs_get_defaults
  echo "[TEST] Testing zfs_get_defaults..."
  local -a test_pool_opts=()
  local -a test_zfs_props=()
  
  if zfs_get_defaults test_pool_opts test_zfs_props; then
    echo "  ✓ zfs_get_defaults succeeded"
    echo "      Pool opts: ${#test_pool_opts[@]} items"
    echo "      ZFS props: ${#test_zfs_props[@]} items"
  else
    echo "  ✗ zfs_get_defaults failed"
    ((failed++))
  fi
  
  # Test 6: Test dry-run mode
  echo "[TEST] Testing dry-run mode..."
  local dry_run_output
  dry_run_output=$(n_zpool_create_on_free_disk --dry-run 2>&1)
  local dry_run_rc=$?
  
  if [[ $dry_run_rc -eq 0 ]] || [[ $dry_run_rc -eq 2 ]] || [[ $dry_run_rc -eq 4 ]]; then
    echo "  ✓ Dry-run completed (exit code: $dry_run_rc)"
    if echo "$dry_run_output" | grep -q "DRY-RUN MODE"; then
      echo "      Dry-run mode detected in output"
    fi
  else
    echo "  ✗ Dry-run failed with exit code: $dry_run_rc"
    ((failed++))
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All zpool_create_on_free_disk tests passed"
    return 0
  else
    echo "[TEST] ✗ zpool_create_on_free_disk tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_zpool_all
# --------------------
# Run all zpool tests in sequence.
#
# Behaviour:
#   - Runs ZFS package tests
#   - Runs ZFS module tests
#   - Runs zpool create validation tests
#   - Runs high-level wrapper tests
#   - Reports overall results
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   n_test_sch_zpool_all
#
#===============================================================================
n_test_sch_zpool_all() {
  echo "=========================================="
  echo "HPS Storage Functions - ZPool Test Suite"
  echo "=========================================="
  echo ""
  
  local failed=0
  
  # Run package tests
  if ! n_test_sch_zfs_packages; then
    ((failed++))
  fi
  
  echo ""
  
  # Run module tests
  if ! n_test_sch_zfs_module; then
    ((failed++))
  fi
  
  echo ""
  
  # Run zpool create tests
  if ! n_test_sch_zpool_create; then
    ((failed++))
  fi
  
  echo ""
  
  # Run live pool creation test (optional, requires root)
  echo "[TEST] Running optional live pool creation test..."
  local live_rc
  n_test_sch_zpool_create_live
  live_rc=$?
  
  if [[ $live_rc -eq 0 ]]; then
    echo "  ✓ Live test passed"
  elif [[ $live_rc -eq 2 ]]; then
    echo "  ⚠ Live test skipped (not root or no loop support)"
  else
    echo "  ✗ Live test failed"
    ((failed++))
  fi
  
  echo ""
  
  # Run high-level wrapper tests
  if ! n_test_sch_zpool_create_on_free_disk; then
    ((failed++))
  fi
  
  # Overall summary
  echo ""
  echo "=========================================="
  if [[ $failed -eq 0 ]]; then
    echo "✓ All zpool tests passed"
    echo "=========================================="
    return 0
  else
    echo "✗ zpool tests failed: $failed test suites"
    echo "=========================================="
    return 1
  fi
}

#===============================================================================
# n_test_sch_zpool_create
# -----------------------
# Test zpool creation function validation.
#
# Behaviour:
#   - Tests argument validation
#   - Tests vdev type validation
#   - Tests device validation
#   - Does NOT create actual pools (requires test devices)
#
# Returns:
#   0 on success (all validation tests pass)
#   1 on failure
#
# Example usage:
#   n_test_sch_zpool_create
#
#===============================================================================
n_test_sch_zpool_create() {
  echo "[TEST] Testing zpool create function"
  
  local failed=0
  
  # Test 1: Missing required arguments
  echo "[TEST] Testing argument validation..."
  
  # Missing --name
  if n_zpool_create --vdev-type single --devices /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect missing --name"
    ((failed++))
  else
    echo "  ✓ Correctly detected missing --name"
  fi
  
  # Missing --vdev-type
  if n_zpool_create --name testpool --devices /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect missing --vdev-type"
    ((failed++))
  else
    echo "  ✓ Correctly detected missing --vdev-type"
  fi
  
  # Missing --devices
  if n_zpool_create --name testpool --vdev-type single 2>/dev/null; then
    echo "  ✗ Failed to detect missing --devices"
    ((failed++))
  else
    echo "  ✓ Correctly detected missing --devices"
  fi
  
  # Test 2: Invalid pool name
  echo "[TEST] Testing pool name validation..."
  if n_zpool_create --name "invalid pool name!" --vdev-type single --devices /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect invalid pool name"
    ((failed++))
  else
    echo "  ✓ Correctly detected invalid pool name"
  fi
  
  # Test 3: Invalid vdev type
  echo "[TEST] Testing vdev-type validation..."
  if n_zpool_create --name testpool --vdev-type invalid --devices /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect invalid vdev-type"
    ((failed++))
  else
    echo "  ✓ Correctly detected invalid vdev-type"
  fi
  
  # Test 4: Minimum device requirements
  echo "[TEST] Testing minimum device requirements..."
  
  # Mirror needs 2+ devices
  if n_zpool_create --name testpool --vdev-type mirror --devices /dev/null 2>/dev/null; then
    echo "  ✗ Failed to detect insufficient devices for mirror"
    ((failed++))
  else
    echo "  ✓ Correctly detected insufficient devices for mirror"
  fi
  
  # RAIDZ needs 3+ devices
  if n_zpool_create --name testpool --vdev-type raidz --devices /dev/null /dev/zero 2>/dev/null; then
    echo "  ✗ Failed to detect insufficient devices for raidz"
    ((failed++))
  else
    echo "  ✓ Correctly detected insufficient devices for raidz"
  fi
  
  # Test 5: Non-existent device detection
  echo "[TEST] Testing device existence validation..."
  if n_zpool_create --name testpool --vdev-type single --devices /dev/nonexistent 2>/dev/null; then
    echo "  ✗ Failed to detect non-existent device"
    ((failed++))
  else
    echo "  ✓ Correctly detected non-existent device"
  fi
  
  # Test 6: Flag parsing (ensure -f not absorbed into devices)
  echo "[TEST] Testing flag parsing with -f..."
  # This should fail on device validation, not argument parsing
  local flag_test_output
  flag_test_output=$(n_zpool_create --name testpool --vdev-type single --devices /dev/null -f 2>&1)
  
  if echo "$flag_test_output" | grep -q "Devices:.*-f"; then
    echo "  ✗ Flag -f was incorrectly absorbed into devices array"
    ((failed++))
  else
    echo "  ✓ Flag -f parsed correctly (not in devices array)"
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All zpool create validation tests passed"
    return 0
  else
    echo "[TEST] ✗ zpool create validation tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_zpool_create_live
# -----------------------------
# Test actual pool creation with loop device.
#
# Behaviour:
#   - Creates a loop device from a file
#   - Creates a test pool on the loop device
#   - Verifies pool exists
#   - Destroys test pool
#   - Cleans up loop device
#   - Only runs if root and loop devices available
#
# Returns:
#   0 on success
#   1 on failure
#   2 if skipped (not root or no loop support)
#
# Example usage:
#   n_test_sch_zpool_create_live
#
#===============================================================================
n_test_sch_zpool_create_live() {
  echo "[TEST] Testing live pool creation with loop device"
  
  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    echo "  ⚠ Skipping live test (requires root)"
    return 2
  fi
  
  # Check if losetup available
  if ! command -v losetup >/dev/null 2>&1; then
    echo "  ⚠ Skipping live test (losetup not available)"
    return 2
  fi
  
  local failed=0
  local test_file="/tmp/zpool-test-$-$(date +%s).img"
  local test_pool="testpool-$"
  local loop_dev=""
  
  echo "[TEST] Creating test environment..."
  
  # Create sparse file (100MB)
  if ! truncate -s 100M "$test_file"; then
    echo "  ✗ Failed to create test file"
    return 1
  fi
  echo "  ✓ Created test file: $test_file"
  
  # Set up loop device
  loop_dev=$(losetup -f --show "$test_file")
  if [[ -z "$loop_dev" ]]; then
    echo "  ✗ Failed to set up loop device"
    rm -f "$test_file"
    return 1
  fi
  echo "  ✓ Created loop device: $loop_dev"
  
  # Test pool creation
  echo "[TEST] Creating test pool: $test_pool"
  if ! n_zpool_create --name "$test_pool" --vdev-type single --devices "$loop_dev" -f; then
    echo "  ✗ Failed to create test pool"
    ((failed++))
  else
    echo "  ✓ Pool creation succeeded"
    
    # Verify pool exists
    if zpool list "$test_pool" >/dev/null 2>&1; then
      echo "  ✓ Pool is visible in zpool list"
      
      # Show pool info
      zpool list "$test_pool" | tail -n +2 | while IFS= read -r line; do
        echo "      $line"
      done
    else
      echo "  ✗ Pool not found in zpool list"
      ((failed++))
    fi
  fi
  
  # Cleanup
  echo "[TEST] Cleaning up..."
  
  if zpool list "$test_pool" >/dev/null 2>&1; then
    if zpool destroy "$test_pool"; then
      echo "  ✓ Test pool destroyed"
    else
      echo "  ⚠ Failed to destroy test pool"
    fi
  fi
  
  if [[ -n "$loop_dev" ]]; then
    if losetup -d "$loop_dev"; then
      echo "  ✓ Loop device detached"
    else
      echo "  ⚠ Failed to detach loop device"
    fi
  fi
  
  if [[ -f "$test_file" ]]; then
    rm -f "$test_file"
    echo "  ✓ Test file removed"
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ Live pool creation test passed"
    return 0
  else
    echo "[TEST] ✗ Live pool creation test failed"
    return 1
  fi
}

#===============================================================================
# n_test_sch_zpool_all
# --------------------
# Run all zpool tests in sequence.
#
# Behaviour:
#   - Runs ZFS package tests
#   - Runs ZFS module tests
#   - Runs zpool create validation tests
#   - Reports overall results
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   n_test_sch_zpool_all
#
#===============================================================================
n_test_sch_zpool_all() {
  echo "=========================================="
  echo "HPS Storage Functions - ZPool Test Suite"
  echo "=========================================="
  echo ""
  
  local failed=0
  
  # Run package tests
  if ! n_test_sch_zfs_packages; then
    ((failed++))
  fi
  
  echo ""
  
  # Run module tests
  if ! n_test_sch_zfs_module; then
    ((failed++))
  fi
  
  echo ""
  
  # Run zpool create tests
  if ! n_test_sch_zpool_create; then
    ((failed++))
  fi
  
  # Overall summary
  echo ""
  echo "=========================================="
  if [[ $failed -eq 0 ]]; then
    echo "✓ All zpool tests passed"
    echo "=========================================="
    return 0
  else
    echo "✗ zpool tests failed: $failed test suites"
    echo "=========================================="
    return 1
  fi
}

#===============================================================================
# n_test_sch_zfs_module
# ---------------------
# Test ZFS kernel module loading.
#
# Behaviour:
#   - Verifies ZFS module is loaded in kernel
#   - Checks for /dev/zfs device
#   - Tests zpool command functionality
#   - Verifies module dependencies loaded
#
# Returns:
#   0 on success (all tests pass)
#   1 on failure
#
# Example usage:
#   n_test_sch_zfs_module
#
#===============================================================================
n_test_sch_zfs_module() {
  echo "[TEST] Testing ZFS kernel module"
  
  local failed=0
  
  # Test 1: Verify module loaded
  echo "[TEST] Checking if ZFS module is loaded..."
  if lsmod | grep -q "^zfs "; then
    echo "  ✓ ZFS module loaded"
    
    # Show module info
    local zfs_line=$(lsmod | grep "^zfs ")
    echo "    $(echo "$zfs_line" | awk '{print "Size: " $2 ", Used by: " $4}')"
  else
    echo "  ✗ ZFS module not loaded"
    ((failed++))
  fi
  
  # Test 2: Verify /dev/zfs exists
  echo "[TEST] Checking /dev/zfs device..."
  if [[ -c /dev/zfs ]]; then
    echo "  ✓ /dev/zfs device exists"
    ls -l /dev/zfs | awk '{print "    " $1, $5 $6, $NF}'
  else
    echo "  ✗ /dev/zfs device not found"
    ((failed++))
  fi
  
  # Test 3: Test zpool command
  echo "[TEST] Testing zpool command..."
  local zpool_output
  zpool_output=$(zpool list 2>&1)
  local zpool_rc=$?
  
  # zpool list returns 0 if pools exist, 1 if no pools, 2+ for errors
  if [[ $zpool_rc -eq 0 ]]; then
    echo "  ✓ zpool command works (pools found)"
    echo "$zpool_output" | sed 's/^/    /'
  elif [[ $zpool_rc -eq 1 ]]; then
    echo "  ✓ zpool command works (no pools found - expected)"
  else
    echo "  ✗ zpool command failed with exit code: $zpool_rc"
    echo "$zpool_output" | sed 's/^/    /'
    ((failed++))
  fi
  
  # Test 4: Verify module dependencies
  echo "[TEST] Checking ZFS module dependencies..."
  local zfs_deps=$(lsmod | grep "^zfs " | awk '{print $4}')
  if [[ -n "$zfs_deps" ]]; then
    echo "  ✓ Module dependencies loaded: $zfs_deps"
  else
    echo "  ⚠ No dependencies shown (may be normal)"
  fi
  
  # Test 5: Check for SPL module (Solaris Porting Layer)
  if lsmod | grep -q "^spl "; then
    echo "  ✓ SPL module loaded"
  else
    echo "  ⚠ SPL module not loaded (may be integrated)"
  fi
  
  # Summary
  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "[TEST] ✓ All ZFS module tests passed"
    return 0
  else
    echo "[TEST] ✗ ZFS module tests failed: $failed errors"
    return 1
  fi
}

#===============================================================================
# n_test_sch_zfs_all
# ------------------
# Run all ZFS basic tests in sequence.
#
# Behaviour:
#   - Runs package tests
#   - Runs module tests
#   - Reports overall results
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   n_test_sch_zfs_all
#
#===============================================================================
n_test_sch_zfs_all() {
  echo "========================================"
  echo "HPS Storage Functions - ZFS Test Suite"
  echo "========================================"
  echo ""
  
  local failed=0
  
  # Run package tests
  if ! n_test_sch_zfs_packages; then
    ((failed++))
  fi
  
  echo ""
  
  # Run module tests
  if ! n_test_sch_zfs_module; then
    ((failed++))
  fi
  
  # Overall summary
  echo ""
  echo "========================================"
  if [[ $failed -eq 0 ]]; then
    echo "✓ All ZFS tests passed"
    echo "========================================"
    return 0
  else
    echo "✗ ZFS tests failed: $failed test suites"
    echo "========================================"
    return 1
  fi
}
