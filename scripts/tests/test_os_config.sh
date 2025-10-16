#!/bin/bash



# Resolve script directory and source functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/functions.sh"



#===============================================================================
# test_os_config_ini_format
# -------------------------
# Test that the INI format is properly maintained.
#
# Behaviour:
#   - Verifies the INI file structure
#   - Checks section headers and key=value format
#
# Returns:
#   0 if format is valid
#   1 if format issues found
#
# Example usage:
#   test_os_config_ini_format
#
#===============================================================================
test_os_config_ini_format() {
  local test_conf="/tmp/test_os_format.conf"
  
  # Use environment variable to override config path
  export OS_CONFIG_TEST_FILE="$test_conf"
  
  echo "Testing INI format preservation..."
  
  # Create empty test file
  > "$test_conf"
  
  # Create a complex structure
  os_config "rocky-10" "set" "hps_types" "SCH,DRH"
  os_config "rocky-10" "set" "arch" "x86_64" 
  os_config "rocky-10" "set" "status" "prod"
  os_config "alpine-3.20" "set" "hps_types" "TCH"
  os_config "alpine-3.20" "set" "arch" "x86_64"
  
  # Check the file content
  echo "Generated INI file:"
  if [[ -f "$test_conf" && -s "$test_conf" ]]; then
    cat "$test_conf"
  else
    echo "ERROR: Test file not found or empty at $test_conf"
    ls -la "$test_conf" 2>/dev/null || echo "File doesn't exist"
  fi
  echo "---"
  
  # Validate format - check actual content
  local valid=0
  local errors=""
  
  if ! grep -q '^\[rocky-10\]$' "$test_conf"; then
    errors="${errors}Missing [rocky-10] section header\n"
    valid=1
  fi
  
  if ! grep -q '^hps_types=SCH,DRH$' "$test_conf"; then
    errors="${errors}Missing or incorrect hps_types=SCH,DRH\n"
    valid=1
  fi
  
  if ! grep -q '^\[alpine-3.20\]$' "$test_conf"; then
    errors="${errors}Missing [alpine-3.20] section header\n"
    valid=1
  fi
  
  if [[ $valid -eq 0 ]]; then
    echo "Format validation: PASSED"
  else
    echo "Format validation: FAILED"
    echo -e "Errors:\n${errors}"
    echo "Actual file content (od -c):"
    od -c "$test_conf" | head -20
  fi
  
  # Cleanup
  rm -f "$test_conf"
  unset OS_CONFIG_TEST_FILE
  
  return $valid
}

#===============================================================================
# test_os_config
# --------------
# Test suite for os_config functions.
#
# Behaviour:
#   - Tests all os_config operations
#   - Creates temporary test file
#   - Verifies get, set, exists, and undefine operations
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   test_os_config
#
#===============================================================================
test_os_config() {
  local test_conf="/tmp/test_os.conf"
  local all_passed=0
  
  # Use environment variable to override config path
  export OS_CONFIG_TEST_FILE="$test_conf"
  
  echo "Testing os_config functions..."
  
  # Create empty test file
  > "$test_conf"
  
  # Test 1: Set and get
  echo -n "Test 1 - Set and get: "
  os_config "test-os" "set" "status" "prod"
  local result=$(os_config "test-os" "get" "status")
  if [[ "$result" == "prod" ]]; then
    echo "PASSED"
  else
    echo "FAILED (expected 'prod', got '$result')"
    all_passed=1
  fi
  
  # Continue with remaining tests...
  # [Rest of the test cases remain the same]
  
  # Test 2: Exists
  echo -n "Test 2 - Section exists: "
  if os_config "test-os" "exists"; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 3: Non-existent section
  echo -n "Test 3 - Non-existent section: "
  if ! os_config "fake-os" "exists"; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 4: Multiple keys
  echo -n "Test 4 - Multiple keys: "
  os_config "test-os" "set" "arch" "x86_64"
  os_config "test-os" "set" "version" "1.0"
  local arch=$(os_config "test-os" "get" "arch")
  local version=$(os_config "test-os" "get" "version")
  if [[ "$arch" == "x86_64" && "$version" == "1.0" ]]; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 5: Update existing key
  echo -n "Test 5 - Update existing key: "
  os_config "test-os" "set" "status" "test"
  local updated=$(os_config "test-os" "get" "status")
  if [[ "$updated" == "test" ]]; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 6: Undefine key
  echo -n "Test 6 - Undefine key: "
  os_config "test-os" "undefine" "version"
  if ! os_config "test-os" "get" "version" >/dev/null 2>&1; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 7: Undefine section
  echo -n "Test 7 - Undefine section: "
  os_config "test-os" "undefine"
  if ! os_config "test-os" "exists"; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 8: Values with spaces
  echo -n "Test 8 - Values with spaces: "
  os_config "space-test" "set" "notes" "This is a test note"
  local notes=$(os_config "space-test" "get" "notes")
  if [[ "$notes" == "This is a test note" ]]; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 9: Multiple sections
  echo -n "Test 9 - Multiple sections: "
  os_config "os-1" "set" "type" "TCH"
  os_config "os-2" "set" "type" "SCH"
  local type1=$(os_config "os-1" "get" "type")
  local type2=$(os_config "os-2" "get" "type")
  if [[ "$type1" == "TCH" && "$type2" == "SCH" ]]; then
    echo "PASSED"
  else
    echo "FAILED"
  all_passed=1
  fi
  
  # Cleanup
  rm -f "$test_conf"
  unset OS_CONFIG_TEST_FILE
  
  return $all_passed
}


#===============================================================================
# test_os_config_helpers
# ----------------------
# Test suite for os_config helper functions.
#
# Behaviour:
#   - Tests list, by_type, get_all, and validate functions
#
# Returns:
#   0 if all tests pass
#   1 if any test fails
#
# Example usage:
#   test_os_config_helpers
#
#===============================================================================
test_os_config_helpers() {
  local test_conf="/tmp/test_os_helpers.conf"
  local all_passed=0
  
  export OS_CONFIG_TEST_FILE="$test_conf"
  
  echo "Testing os_config helper functions..."
  
  # Setup test data
  > "$test_conf"
  os_config "rocky-10" "set" "hps_types" "SCH,DRH"
  os_config "rocky-10" "set" "arch" "x86_64"
  os_config "rocky-10" "set" "name" "rockylinux"
  os_config "rocky-10" "set" "version" "10"
  os_config "rocky-10" "set" "status" "prod"
  
  os_config "alpine-3.20" "set" "hps_types" "TCH"
  os_config "alpine-3.20" "set" "arch" "x86_64"
  os_config "alpine-3.20" "set" "name" "alpine"
  os_config "alpine-3.20" "set" "version" "3.20"
  os_config "alpine-3.20" "set" "status" "prod"
  
  os_config "test-multi" "set" "hps_types" "TCH,SCH,DRH"
  os_config "test-multi" "set" "arch" "x86_64"
  os_config "test-multi" "set" "name" "testlinux"
  os_config "test-multi" "set" "version" "1.0"
  os_config "test-multi" "set" "status" "test"
  
  # Test 1: List
  echo -n "Test 1 - List OS entries: "
  local os_list=$(os_config_list | sort | tr '\n' ' ')
  if [[ "$os_list" == "alpine-3.20 rocky-10 test-multi " ]]; then
    echo "PASSED"
  else
    echo "FAILED (got: '$os_list')"
    all_passed=1
  fi
  
  # Test 2: By type TCH
  echo -n "Test 2 - Find TCH OS: "
  local tch_os=$(os_config_by_type "TCH" | sort | tr '\n' ' ')
  if [[ "$tch_os" == "alpine-3.20 test-multi " ]]; then
    echo "PASSED"
  else
    echo "FAILED (got: '$tch_os')"
    all_passed=1
  fi
  
  # Test 3: By type SCH
  echo -n "Test 3 - Find SCH OS: "
  local sch_os=$(os_config_by_type "SCH" | sort | tr '\n' ' ')
  if [[ "$sch_os" == "rocky-10 test-multi " ]]; then
    echo "PASSED"
  else
    echo "FAILED (got: '$sch_os')"
    all_passed=1
  fi
  
  # Test 4: Get all
  echo -n "Test 4 - Get all keys: "
  local key_count=$(os_config_get_all "rocky-10" | wc -l)
  if [[ $key_count -eq 5 ]]; then
    echo "PASSED"
  else
    echo "FAILED (expected 5 keys, got $key_count)"
    all_passed=1
  fi
  
  # Test 5: Validate valid OS
  echo -n "Test 5 - Validate complete OS: "
  if os_config_validate "rocky-10" 2>/dev/null; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 6: Validate incomplete OS
  echo -n "Test 6 - Validate incomplete OS: "
  os_config "incomplete" "set" "arch" "x86_64"
  if ! os_config_validate "incomplete" 2>/dev/null; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Test 7: Summary output
  echo -n "Test 7 - Summary format: "
  if os_config_summary >/dev/null 2>&1; then
    echo "PASSED"
  else
    echo "FAILED"
    all_passed=1
  fi
  
  # Cleanup
  rm -f "$test_conf"
  unset OS_CONFIG_TEST_FILE
  
  return $all_passed
}




test_os_config
test_os_config_ini_format
test_os_config_helpers


