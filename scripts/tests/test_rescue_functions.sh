#!/bin/bash
#===============================================================================
# Test Suite for Rescue Functions
# 
# Tests rescue-functions.sh in a safe manner without requiring actual
# disk operations or IPS connectivity.
#===============================================================================

set -u

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#===============================================================================
# Test Helpers
#===============================================================================

test_start() {
  local test_name="$1"
  ((TESTS_RUN++))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "TEST $TESTS_RUN: $test_name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

test_pass() {
  ((TESTS_PASSED++))
  echo -e "${GREEN}✓ PASS${NC}"
}

test_fail() {
  local message="$1"
  ((TESTS_FAILED++))
  echo -e "${RED}✗ FAIL: $message${NC}"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $message"
    return 0
  else
    echo "  ✗ $message"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
}

assert_function_exists() {
  local func_name="$1"
  
  if declare -f "$func_name" >/dev/null 2>&1; then
    echo "  ✓ Function exists: $func_name"
    return 0
  else
    echo "  ✗ Function missing: $func_name"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  
  if [[ "$haystack" =~ $needle ]]; then
    echo "  ✓ $message"
    return 0
  else
    echo "  ✗ $message (not found: '$needle')"
    return 1
  fi
}

#===============================================================================
# Mock Functions for Testing
#===============================================================================

# Mock n_remote_log to capture log messages
declare -a MOCK_LOG_MESSAGES=()
n_remote_log() {
  MOCK_LOG_MESSAGES+=("$1")
  return 0
}

# Mock n_remote_host_variable to return test data
declare -A MOCK_HOST_CONFIG=(
  [os_disk]="/dev/vdb"
  [boot_device]="/dev/vdb2"
  [root_device]="/dev/vdb3"
  [boot_uuid]="1234-5678"
  [root_uuid]="abcd-efgh-1234-5678"
)

n_remote_host_variable() {
  local key="$1"
  local value="${2:-}"
  
  # If setting a value
  if [[ -n "$value" ]]; then
    MOCK_HOST_CONFIG[$key]="$value"
    return 0
  fi
  
  # If getting a value
  if [[ -n "${MOCK_HOST_CONFIG[$key]:-}" ]]; then
    echo "${MOCK_HOST_CONFIG[$key]}"
    return 0
  else
    return 1
  fi
}

# Mock n_installer_load_ext4_modules (used by rescue)
n_installer_load_ext4_modules() {
  n_remote_log "[INFO] ext4 modules loaded (mocked)"
  return 0
}

#===============================================================================
# Test Functions
#===============================================================================

test_function_definitions() {
  test_start "Function Definitions"
  
  local all_pass=1
  
  assert_function_exists "n_rescue_load_modules" || all_pass=0
  assert_function_exists "n_rescue_display_config" || all_pass=0
  assert_function_exists "n_rescue_show_help" || all_pass=0
  assert_function_exists "n_rescue_mount" || all_pass=0
  assert_function_exists "n_rescue_chroot" || all_pass=0
  assert_function_exists "n_rescue_reinstall_grub" || all_pass=0
  assert_function_exists "n_rescue_fsck" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Some functions are missing"
  fi
}

test_rescue_show_help() {
  test_start "n_rescue_show_help Output"
  
  local output
  output=$(n_rescue_show_help 2>&1)
  local rc=$?
  
  local all_pass=1
  
  assert_equals 0 $rc "Function returns 0" || all_pass=0
  assert_contains "$output" "HPS NETWORK RESCUE BOOT" "Contains banner" || all_pass=0
  assert_contains "$output" "n_rescue_mount" "Lists mount command" || all_pass=0
  assert_contains "$output" "n_rescue_chroot" "Lists chroot command" || all_pass=0
  assert_contains "$output" "n_rescue_reinstall_grub" "Lists grub command" || all_pass=0
  assert_contains "$output" "EXITING RESCUE MODE" "Contains exit instructions" || all_pass=0
  assert_contains "$output" "n_remote_host_variable STATE INSTALLED" "Shows state change" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Help output missing expected content"
  fi
}

test_rescue_display_config_with_data() {
  test_start "n_rescue_display_config With Configuration"
  
  # Set up mock config
  MOCK_HOST_CONFIG[os_disk]="/dev/vdb"
  MOCK_HOST_CONFIG[boot_device]="/dev/vdb2"
  MOCK_HOST_CONFIG[root_device]="/dev/vdb3"
  
  local output
  output=$(n_rescue_display_config 2>&1)
  local rc=$?
  
  local all_pass=1
  
  assert_equals 0 $rc "Function returns 0 when config exists" || all_pass=0
  assert_contains "$output" "Disk Configuration from IPS" "Contains header" || all_pass=0
  assert_contains "$output" "/dev/vdb" "Shows os_disk" || all_pass=0
  assert_contains "$output" "/dev/vdb2" "Shows boot_device" || all_pass=0
  assert_contains "$output" "/dev/vdb3" "Shows root_device" || all_pass=0
  assert_contains "$output" "n_rescue_mount" "Shows suggested command" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Config display missing expected content"
  fi
}

test_rescue_display_config_no_data() {
  test_start "n_rescue_display_config Without Configuration"
  
  # Clear mock config
  unset MOCK_HOST_CONFIG[os_disk]
  unset MOCK_HOST_CONFIG[boot_device]
  unset MOCK_HOST_CONFIG[root_device]
  
  local output
  output=$(n_rescue_display_config 2>&1)
  local rc=$?
  
  local all_pass=1
  
  assert_equals 1 $rc "Function returns 1 when no config" || all_pass=0
  assert_contains "$output" "No disk configuration found" "Shows no config message" || all_pass=0
  assert_contains "$output" "lsblk" "Suggests exploration command" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "No-config case incorrect"
  fi
  
  # Restore config for other tests
  MOCK_HOST_CONFIG[os_disk]="/dev/vdb"
  MOCK_HOST_CONFIG[boot_device]="/dev/vdb2"
  MOCK_HOST_CONFIG[root_device]="/dev/vdb3"
}

test_rescue_mount_no_args() {
  test_start "n_rescue_mount Configuration Reading"
  
  # This test verifies the function reads from config correctly
  # We can't actually mount without root, but we can test the logic
  
  # Set up mock config
  MOCK_HOST_CONFIG[root_device]="/dev/vdb3"
  MOCK_HOST_CONFIG[boot_device]="/dev/vdb2"
  
  # Clear log messages
  MOCK_LOG_MESSAGES=()
  
  # We expect this to fail at the actual mount stage (no root, no real device)
  # But it should successfully read the config first
  local output
  output=$(n_rescue_mount 2>&1 || true)
  
  local all_pass=1
  
  assert_contains "$output" "Reading device configuration" "Reads from config" || all_pass=0
  assert_contains "$output" "/dev/vdb3" "Uses root_device from config" || all_pass=0
  
  # Check that it logged the attempt
  local found_log=0
  for msg in "${MOCK_LOG_MESSAGES[@]}"; do
    if [[ "$msg" =~ "Starting rescue mount" ]]; then
      found_log=1
      break
    fi
  done
  
  if [[ $found_log -eq 1 ]]; then
    echo "  ✓ Logged mount attempt"
  else
    echo "  ✗ Did not log mount attempt"
    all_pass=0
  fi
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Mount config reading failed"
  fi
}

test_rescue_mount_with_args() {
  test_start "n_rescue_mount Argument Handling"
  
  # Test that function accepts and validates arguments
  
  # Clear log messages
  MOCK_LOG_MESSAGES=()
  
  # This will fail at mount stage but should accept the args
  local output
  output=$(n_rescue_mount "/dev/test1" "/dev/test2" 2>&1 || true)
  
  local all_pass=1
  
  # Should NOT read from config when args provided
  if [[ "$output" =~ "Reading device configuration" ]]; then
    echo "  ✗ Should not read config when args provided"
    all_pass=0
  else
    echo "  ✓ Does not read config with explicit args"
  fi
  
  # Should validate device existence
  assert_contains "$output" "not found or not a block device" "Validates device exists" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Argument handling incorrect"
  fi
}

test_rescue_fsck_no_device() {
  test_start "n_rescue_fsck Usage Message"
  
  local output
  output=$(n_rescue_fsck 2>&1 || true)
  local rc=$?
  
  local all_pass=1
  
  assert_equals 1 $rc "Returns 1 with no device" || all_pass=0
  assert_contains "$output" "Usage:" "Shows usage" || all_pass=0
  assert_contains "$output" "Available devices from config" "Shows config devices" || all_pass=0
  assert_contains "$output" "/dev/vdb2" "Lists boot device" || all_pass=0
  assert_contains "$output" "/dev/vdb3" "Lists root device" || all_pass=0
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Usage message incorrect"
  fi
}

test_documentation_headers() {
  test_start "Function Documentation Headers"
  
  local script_file="${1:-rescue-functions.sh}"
  
  if [[ ! -f "$script_file" ]]; then
    test_fail "Script file not found: $script_file"
    return
  fi
  
  local required_functions=(
    "n_rescue_load_modules"
    "n_rescue_display_config"
    "n_rescue_show_help"
    "n_rescue_mount"
    "n_rescue_chroot"
    "n_rescue_reinstall_grub"
    "n_rescue_fsck"
  )
  
  local all_pass=1
  
  for func in "${required_functions[@]}"; do
    # Check for documentation header (starts with #===)
    if grep -A5 "^${func}()" "$script_file" | grep -q "^#==="; then
      echo "  ✓ $func has documentation header"
    else
      echo "  ✗ $func missing documentation header"
      all_pass=0
    fi
    
    # Check for required sections
    local func_doc
    func_doc=$(awk "/^${func}\(\)/,/^}/" "$script_file")
    
    if echo "$func_doc" | grep -q "# Behaviour:"; then
      : # pass
    else
      echo "  ✗ $func missing 'Behaviour:' section"
      all_pass=0
    fi
    
    if echo "$func_doc" | grep -q "# Returns:"; then
      : # pass
    else
      echo "  ✗ $func missing 'Returns:' section"
      all_pass=0
    fi
    
    if echo "$func_doc" | grep -q "# Example usage:"; then
      : # pass
    else
      echo "  ✗ $func missing 'Example usage:' section"
      all_pass=0
    fi
  done
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Some functions missing proper documentation"
  fi
}

test_code_style() {
  test_start "Code Style Compliance"
  
  local script_file="${1:-rescue-functions.sh}"
  
  if [[ ! -f "$script_file" ]]; then
    test_fail "Script file not found: $script_file"
    return
  fi
  
  local all_pass=1
  
  # Check for 2-space indentation (no tabs)
  if grep -q $'\t' "$script_file"; then
    echo "  ✗ File contains tabs (should use 2 spaces)"
    all_pass=0
  else
    echo "  ✓ No tabs found (uses spaces)"
  fi
  
  # Check for consistent return statements
  local inconsistent_returns
  inconsistent_returns=$(grep -n "return [0-9]" "$script_file" | grep -v "^[[:space:]]*return [0-9]" || true)
  if [[ -n "$inconsistent_returns" ]]; then
    echo "  ✗ Some return statements not properly indented"
    all_pass=0
  else
    echo "  ✓ Return statements properly formatted"
  fi
  
  # Check for n_remote_log usage
  if grep -q "n_remote_log" "$script_file"; then
    echo "  ✓ Uses n_remote_log for logging"
  else
    echo "  ✗ Missing n_remote_log usage"
    all_pass=0
  fi
  
  # Check for error handling patterns
  if grep -q "if \[\[.*\]\]; then" "$script_file"; then
    echo "  ✓ Uses proper bash conditional syntax"
  else
    echo "  ✗ Missing proper bash conditionals"
    all_pass=0
  fi
  
  if [[ $all_pass -eq 1 ]]; then
    test_pass
  else
    test_fail "Code style issues found"
  fi
}

#===============================================================================
# Test Runner
#===============================================================================

run_all_tests() {
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "  HPS Rescue Functions Test Suite"
  echo "═══════════════════════════════════════════════════════════════════════"
  
  # Source the rescue functions if file exists
  if [[ -f "rescue-functions.sh" ]]; then
    echo "Loading rescue-functions.sh..."
    # shellcheck disable=SC1091
    source rescue-functions.sh
    echo "✓ Functions loaded"
  else
    echo -e "${YELLOW}⚠ rescue-functions.sh not found, testing in mock mode${NC}"
  fi
  
  # Run tests
  test_function_definitions
  test_rescue_show_help
  test_rescue_display_config_with_data
  test_rescue_display_config_no_data
  test_rescue_mount_no_args
  test_rescue_mount_with_args
  test_rescue_fsck_no_device
  
  # Only run file-based tests if file exists
  if [[ -f "rescue-functions.sh" ]]; then
    test_documentation_headers "rescue-functions.sh"
    test_code_style "rescue-functions.sh"
  fi
  
  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "  Test Summary"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Tests Run:    $TESTS_RUN"
  echo -e "  Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "  Tests Failed: ${RED}$TESTS_FAILED${NC}"
  else
    echo -e "  Tests Failed: $TESTS_FAILED"
  fi
  echo ""
  
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    return 0
  else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    return 1
  fi
}

# Run tests
run_all_tests
exit $?
