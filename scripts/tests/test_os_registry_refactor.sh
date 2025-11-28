#!/bin/bash
#===============================================================================
# OS Registry Refactor Test Suite
# --------------------------------
# Comprehensive tests for refactored os-functions.sh and os-function-helpers.sh
#
# Usage:
#   ./test_os_registry_refactor.sh
#
# Prerequisites:
#   - HPS system installed at /srv/hps-system
#   - Have at least one test OS configured (e.g., x86_64:alpine:3.20)
#===============================================================================

# Source HPS functions
if [[ -f /srv/hps-system/lib/functions.sh ]]; then
  source /srv/hps-system/lib/functions.sh
elif [[ -f ../lib/functions.sh ]]; then
  source ../lib/functions.sh
else
  echo "ERROR: Cannot find HPS functions library"
  echo "Expected: /srv/hps-system/lib/functions.sh"
  exit 1
fi

# Verify critical functions are loaded
if ! type os_config >/dev/null 2>&1; then
  echo "ERROR: os_config function not loaded"
  echo "Functions library may be incomplete"
  exit 1
fi

if ! type os_registry >/dev/null 2>&1; then
  echo "ERROR: os_registry function not loaded"
  echo "Registry functions may not be available"
  exit 1
fi

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test data
TEST_OS_ID="x86_64:test_os:1.0"
TEST_KEY="test_key"
TEST_VALUE="test_value"

#===============================================================================
# Test Helper Functions
#===============================================================================

test_pass() {
  echo "  ✓ PASS: $1"
  ((TESTS_PASSED++))
  ((TESTS_RUN++))
}

test_fail() {
  echo "  ✗ FAIL: $1"
  [[ -n "${2:-}" ]] && echo "    Detail: $2"
  ((TESTS_FAILED++))
  ((TESTS_RUN++))
}

test_section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "═══════════════════════════════════════════════════════════════"
}

#===============================================================================
# Cleanup Functions
#===============================================================================

cleanup_test_os() {
  if os_config "$TEST_OS_ID" exists 2>/dev/null; then
    os_config "$TEST_OS_ID" undefine >/dev/null 2>&1
  fi
}

#===============================================================================
# Core CRUD Function Tests
#===============================================================================

test_os_config_set() {
  test_section "TEST: os_config_set"
  
  cleanup_test_os
  
  # Test setting a value
  if os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE"; then
    test_pass "os_config_set creates new key"
  else
    test_fail "os_config_set failed to create key"
    return
  fi
  
  # Verify the value was set
  local retrieved
  retrieved=$(os_config "$TEST_OS_ID" get "$TEST_KEY")
  if [[ "$retrieved" == "$TEST_VALUE" ]]; then
    test_pass "os_config_set stores correct value"
  else
    test_fail "os_config_set stored incorrect value" "Expected: $TEST_VALUE, Got: $retrieved"
  fi
  
  # Test updating existing value
  local new_value="updated_value"
  if os_config "$TEST_OS_ID" set "$TEST_KEY" "$new_value"; then
    retrieved=$(os_config "$TEST_OS_ID" get "$TEST_KEY")
    if [[ "$retrieved" == "$new_value" ]]; then
      test_pass "os_config_set updates existing value"
    else
      test_fail "os_config_set failed to update" "Expected: $new_value, Got: $retrieved"
    fi
  else
    test_fail "os_config_set failed to update existing key"
  fi
}

test_os_config_get() {
  test_section "TEST: os_config_get"
  
  cleanup_test_os
  
  # Setup test data
  os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
  
  # Test getting existing value
  local result
  result=$(os_config "$TEST_OS_ID" get "$TEST_KEY")
  if [[ "$result" == "$TEST_VALUE" ]]; then
    test_pass "os_config_get retrieves correct value"
  else
    test_fail "os_config_get returned incorrect value" "Expected: $TEST_VALUE, Got: $result"
  fi
  
  # Test getting non-existent key
  if ! os_config "$TEST_OS_ID" get "nonexistent_key" >/dev/null 2>&1; then
    test_pass "os_config_get returns error for non-existent key"
  else
    test_fail "os_config_get should fail for non-existent key"
  fi
  
  # Test getting from non-existent OS
  if ! os_config "x86_64:nonexistent:1.0" get "$TEST_KEY" >/dev/null 2>&1; then
    test_pass "os_config_get returns error for non-existent OS"
  else
    test_fail "os_config_get should fail for non-existent OS"
  fi
}

test_os_config_exists() {
  test_section "TEST: os_config_exists"
  
  cleanup_test_os
  
  # Test non-existent OS
  if ! os_config "$TEST_OS_ID" exists 2>/dev/null; then
    test_pass "os_config_exists returns false for non-existent OS"
  else
    test_fail "os_config_exists should return false for non-existent OS"
  fi
  
  # Create OS
  os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
  
  # Test existing OS
  if os_config "$TEST_OS_ID" exists 2>/dev/null; then
    test_pass "os_config_exists returns true for existing OS"
  else
    test_fail "os_config_exists should return true for existing OS"
  fi
}

test_os_config_undefine_key() {
  test_section "TEST: os_config_undefine_key"
  
  cleanup_test_os
  
  # Setup test data
  os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "another_key" "another_value" >/dev/null 2>&1
  
  # Remove one key
  if os_config "$TEST_OS_ID" undefine "$TEST_KEY" 2>/dev/null; then
    test_pass "os_config_undefine_key removes key"
  else
    test_fail "os_config_undefine_key failed to remove key"
    return
  fi
  
  # Verify key is gone
  if ! os_config "$TEST_OS_ID" get "$TEST_KEY" >/dev/null 2>&1; then
    test_pass "os_config_undefine_key removes key completely"
  else
    test_fail "os_config_undefine_key did not remove key"
  fi
  
  # Verify other key still exists
  if os_config "$TEST_OS_ID" get "another_key" >/dev/null 2>&1; then
    test_pass "os_config_undefine_key preserves other keys"
  else
    test_fail "os_config_undefine_key removed other keys"
  fi
  
  # Verify OS still exists
  if os_config "$TEST_OS_ID" exists 2>/dev/null; then
    test_pass "os_config_undefine_key preserves OS section"
  else
    test_fail "os_config_undefine_key removed OS section"
  fi
}

test_os_config_undefine_section() {
  test_section "TEST: os_config_undefine_section"
  
  cleanup_test_os
  
  # Setup test data
  os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "key2" "value2" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "key3" "value3" >/dev/null 2>&1
  
  # Remove entire section
  if os_config "$TEST_OS_ID" undefine 2>/dev/null; then
    test_pass "os_config_undefine_section removes section"
  else
    test_fail "os_config_undefine_section failed to remove section"
    return
  fi
  
  # Verify OS is gone
  if ! os_config "$TEST_OS_ID" exists 2>/dev/null; then
    test_pass "os_config_undefine_section removes OS completely"
  else
    test_fail "os_config_undefine_section did not remove OS"
  fi
  
  # Verify directory is gone
  local os_safe=$(echo "$TEST_OS_ID" | tr ':' '_')
  local db_path="/srv/hps-config/os.db/${os_safe}.os"
  if [[ ! -d "$db_path" ]]; then
    test_pass "os_config_undefine_section removes directory"
  else
    test_fail "os_config_undefine_section left directory behind"
  fi
  
  # Test removing non-existent section
  if ! os_config "$TEST_OS_ID" undefine >/dev/null 2>&1; then
    test_pass "os_config_undefine_section returns error for non-existent OS"
  else
    test_fail "os_config_undefine_section should fail for non-existent OS"
  fi
}

#===============================================================================
# Helper Function Tests
#===============================================================================

test_os_config_list() {
  test_section "TEST: os_config_list"
  
  cleanup_test_os
  
  # Get count before adding
  local count_before
  count_before=$(os_config_list 2>/dev/null | wc -l)
  
  # Add test OS
  os_config "$TEST_OS_ID" set "arch" "x86_64" >/dev/null 2>&1
  
  # Get count after adding
  local count_after
  count_after=$(os_config_list 2>/dev/null | wc -l)
  
  if [[ $count_after -eq $((count_before + 1)) ]]; then
    test_pass "os_config_list counts increase correctly"
  else
    test_fail "os_config_list count mismatch" "Before: $count_before, After: $count_after"
  fi
  
  # Verify test OS appears in list
  if os_config_list 2>/dev/null | grep -q "^${TEST_OS_ID}$"; then
    test_pass "os_config_list includes new OS"
  else
    test_fail "os_config_list does not include new OS"
  fi
  
  cleanup_test_os
}

test_os_get_latest() {
  test_section "TEST: os_get_latest"
  
  cleanup_test_os
  
  # Create multiple versions
  os_config "x86_64:test_os:1.0" set "arch" "x86_64" >/dev/null 2>&1
  os_config "x86_64:test_os:1.5" set "arch" "x86_64" >/dev/null 2>&1
  os_config "x86_64:test_os:2.0" set "arch" "x86_64" >/dev/null 2>&1
  
  # Get latest
  local latest
  latest=$(os_get_latest "test_os" 2>/dev/null)
  
  if [[ "$latest" == "x86_64:test_os:2.0" ]]; then
    test_pass "os_get_latest returns highest version"
  else
    test_fail "os_get_latest returned wrong version" "Expected: x86_64:test_os:2.0, Got: $latest"
  fi
  
  # Cleanup
  os_config "x86_64:test_os:1.0" undefine >/dev/null 2>&1
  os_config "x86_64:test_os:1.5" undefine >/dev/null 2>&1
  os_config "x86_64:test_os:2.0" undefine >/dev/null 2>&1
  
  # Test non-existent OS
  if ! os_get_latest "nonexistent_os" >/dev/null 2>&1; then
    test_pass "os_get_latest returns error for non-existent OS"
  else
    test_fail "os_get_latest should fail for non-existent OS"
  fi
}

test_os_config_get_all() {
  test_section "TEST: os_config_get_all"
  
  cleanup_test_os
  
  # Setup test data
  os_config "$TEST_OS_ID" set "key1" "value1" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "key2" "value2" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "key3" "value3" >/dev/null 2>&1
  
  # Get all keys
  local output
  output=$(os_config_get_all "$TEST_OS_ID" 2>/dev/null)
  
  # Check format (key=value)
  if echo "$output" | grep -q "^key1=value1$"; then
    test_pass "os_config_get_all includes key1"
  else
    test_fail "os_config_get_all missing or malformed key1"
  fi
  
  if echo "$output" | grep -q "^key2=value2$"; then
    test_pass "os_config_get_all includes key2"
  else
    test_fail "os_config_get_all missing or malformed key2"
  fi
  
  if echo "$output" | grep -q "^key3=value3$"; then
    test_pass "os_config_get_all includes key3"
  else
    test_fail "os_config_get_all missing or malformed key3"
  fi
  
  # Count keys
  local key_count
  key_count=$(echo "$output" | wc -l)
  if [[ $key_count -eq 3 ]]; then
    test_pass "os_config_get_all returns correct number of keys"
  else
    test_fail "os_config_get_all key count mismatch" "Expected: 3, Got: $key_count"
  fi
  
  cleanup_test_os
  
  # Test non-existent OS
  if ! os_config_get_all "$TEST_OS_ID" >/dev/null 2>&1; then
    test_pass "os_config_get_all returns error for non-existent OS"
  else
    test_fail "os_config_get_all should fail for non-existent OS"
  fi
}

#===============================================================================
# Integration Tests
#===============================================================================

test_complete_crud_cycle() {
  test_section "TEST: Complete CRUD Cycle"
  
  cleanup_test_os
  
  # Create
  os_config "$TEST_OS_ID" set "name" "test_os" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "version" "1.0" >/dev/null 2>&1
  os_config "$TEST_OS_ID" set "arch" "x86_64" >/dev/null 2>&1
  
  if os_config "$TEST_OS_ID" exists; then
    test_pass "CRUD: Create operation successful"
  else
    test_fail "CRUD: Create operation failed"
    return
  fi
  
  # Read
  local name version arch
  name=$(os_config "$TEST_OS_ID" get "name")
  version=$(os_config "$TEST_OS_ID" get "version")
  arch=$(os_config "$TEST_OS_ID" get "arch")
  
  if [[ "$name" == "test_os" && "$version" == "1.0" && "$arch" == "x86_64" ]]; then
    test_pass "CRUD: Read operation successful"
  else
    test_fail "CRUD: Read operation failed" "name=$name, version=$version, arch=$arch"
    return
  fi
  
  # Update
  os_config "$TEST_OS_ID" set "version" "1.1" >/dev/null 2>&1
  version=$(os_config "$TEST_OS_ID" get "version")
  
  if [[ "$version" == "1.1" ]]; then
    test_pass "CRUD: Update operation successful"
  else
    test_fail "CRUD: Update operation failed" "Expected: 1.1, Got: $version"
  fi
  
  # Delete
  os_config "$TEST_OS_ID" undefine >/dev/null 2>&1
  
  if ! os_config "$TEST_OS_ID" exists; then
    test_pass "CRUD: Delete operation successful"
  else
    test_fail "CRUD: Delete operation failed"
  fi
}

test_multiple_os_entries() {
  test_section "TEST: Multiple OS Entries"
  
  # Cleanup
  os_config "x86_64:multi_test:1.0" undefine >/dev/null 2>&1
  os_config "x86_64:multi_test:2.0" undefine >/dev/null 2>&1
  os_config "aarch64:multi_test:1.0" undefine >/dev/null 2>&1
  
  # Create multiple entries
  os_config "x86_64:multi_test:1.0" set "arch" "x86_64" >/dev/null 2>&1
  os_config "x86_64:multi_test:2.0" set "arch" "x86_64" >/dev/null 2>&1
  os_config "aarch64:multi_test:1.0" set "arch" "aarch64" >/dev/null 2>&1
  
  # Verify all exist
  local count=0
  os_config "x86_64:multi_test:1.0" exists && ((count++))
  os_config "x86_64:multi_test:2.0" exists && ((count++))
  os_config "aarch64:multi_test:1.0" exists && ((count++))
  
  if [[ $count -eq 3 ]]; then
    test_pass "Multiple OS: All entries created"
  else
    test_fail "Multiple OS: Creation count mismatch" "Expected: 3, Got: $count"
  fi
  
  # Verify independence
  os_config "x86_64:multi_test:1.0" set "test_field" "value1" >/dev/null 2>&1
  os_config "x86_64:multi_test:2.0" set "test_field" "value2" >/dev/null 2>&1
  
  local v1 v2
  v1=$(os_config "x86_64:multi_test:1.0" get "test_field")
  v2=$(os_config "x86_64:multi_test:2.0" get "test_field")
  
  if [[ "$v1" == "value1" && "$v2" == "value2" ]]; then
    test_pass "Multiple OS: Entries are independent"
  else
    test_fail "Multiple OS: Entries are not independent" "v1=$v1, v2=$v2"
  fi
  
  # Cleanup
  os_config "x86_64:multi_test:1.0" undefine >/dev/null 2>&1
  os_config "x86_64:multi_test:2.0" undefine >/dev/null 2>&1
  os_config "aarch64:multi_test:1.0" undefine >/dev/null 2>&1
}

test_registry_compatibility() {
  test_section "TEST: Registry Compatibility"
  
  cleanup_test_os
  
  # Test that os_config and os_registry work together
  os_config "$TEST_OS_ID" set "$TEST_KEY" "$TEST_VALUE" >/dev/null 2>&1
  
  # Read using direct registry call
  local registry_value
  registry_value=$(os_registry "$TEST_OS_ID" get "$TEST_KEY" 2>/dev/null)
  
  if [[ "$registry_value" == "$TEST_VALUE" ]]; then
    test_pass "Registry compatibility: os_config -> os_registry"
  else
    test_fail "Registry compatibility failed" "Expected: $TEST_VALUE, Got: $registry_value"
  fi
  
  # Write using registry, read using os_config
  os_registry "$TEST_OS_ID" set "direct_key" "direct_value" >/dev/null 2>&1
  local config_value
  config_value=$(os_config "$TEST_OS_ID" get "direct_key" 2>/dev/null)
  
  if [[ "$config_value" == "direct_value" ]]; then
    test_pass "Registry compatibility: os_registry -> os_config"
  else
    test_fail "Registry compatibility failed" "Expected: direct_value, Got: $config_value"
  fi
  
  cleanup_test_os
}

#===============================================================================
# Real-World Scenario Tests
#===============================================================================

test_realistic_os_config() {
  test_section "TEST: Realistic OS Configuration"
  
  local realistic_os="x86_64:alpine:3.20"
  
  # Check if a real OS exists
  if ! os_config_list | grep -q ":alpine:"; then
    echo "  ⚠ SKIP: No Alpine OS configured for realistic test"
    return
  fi
  
  # Find first alpine OS
  realistic_os=$(os_config_list | grep ":alpine:" | head -1)
  
  # Test reading real OS data
  local name arch version
  name=$(os_config "$realistic_os" get "name" 2>/dev/null)
  arch=$(os_config "$realistic_os" get "arch" 2>/dev/null)
  version=$(os_config "$realistic_os" get "version" 2>/dev/null)
  
  if [[ -n "$name" && -n "$arch" && -n "$version" ]]; then
    test_pass "Realistic OS: Can read real OS configuration"
    echo "    OS: $realistic_os ($name $version on $arch)"
  else
    test_fail "Realistic OS: Cannot read real OS configuration"
  fi
  
  # Test listing all keys
  local all_data
  all_data=$(os_config_get_all "$realistic_os" 2>/dev/null)
  if [[ -n "$all_data" ]]; then
    local key_count
    key_count=$(echo "$all_data" | wc -l)
    test_pass "Realistic OS: Can list all keys ($key_count keys)"
  else
    test_fail "Realistic OS: Cannot list all keys"
  fi
}

#===============================================================================
# Main Test Runner
#===============================================================================

main() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  OS Registry Refactor Test Suite"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  
  # Core CRUD tests
  test_os_config_set
  test_os_config_get
  test_os_config_exists
  test_os_config_undefine_key
  test_os_config_undefine_section
  
  # Helper function tests
  test_os_config_list
  test_os_get_latest
  test_os_config_get_all
  
  # Integration tests
  test_complete_crud_cycle
  test_multiple_os_entries
  test_registry_compatibility
  
  # Real-world tests
  test_realistic_os_config
  
  # Final cleanup
  cleanup_test_os
  
  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Test Summary"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  Total Tests Run: $TESTS_RUN"
  echo "  Passed:          $TESTS_PASSED"
  echo "  Failed:          $TESTS_FAILED"
  echo ""
  
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✓ ALL TESTS PASSED"
    echo ""
    return 0
  else
    echo "  ✗ SOME TESTS FAILED"
    echo ""
    return 1
  fi
}

# Run tests
main "$@"
