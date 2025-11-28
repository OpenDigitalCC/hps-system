#!/bin/bash
#===============================================================================
# HPS Registry Test Suite
#===============================================================================
# Comprehensive tests for the JSON registry system including edge cases,
# concurrent access, data integrity, and migration scenarios.
#===============================================================================

#===============================================================================
# Test Helper Functions
#===============================================================================
test_setup() {
  # Create test environment
  export TEST_DIR="/tmp/hps-registry-test-$$"
  export TEST_HOSTS_DIR="$TEST_DIR/hosts"
  export TEST_CLUSTER_DIR="$TEST_DIR/cluster"
  
  mkdir -p "$TEST_HOSTS_DIR" "$TEST_CLUSTER_DIR"
  
  # Test MAC addresses
  export TEST_MAC1="52:54:00:11:22:33"
  export TEST_MAC2="52:54:00:44:55:66"
  export TEST_MAC1_NORM="525400112233"
  export TEST_MAC2_NORM="525400445566"
  
  # Override directory functions for testing
  get_active_cluster_hosts_dir() {
    echo "$TEST_HOSTS_DIR"
  }
  
  # Test counters
  export TESTS_RUN=0
  export TESTS_PASSED=0
  export TESTS_FAILED=0
  
  echo "=== HPS Registry Test Suite ==="
  echo "Test directory: $TEST_DIR"
  echo ""
}

test_teardown() {
  echo ""
  echo "=== Test Summary ==="
  echo "Tests run: $TESTS_RUN"
  echo "Passed: $TESTS_PASSED"
  echo "Failed: $TESTS_FAILED"
  
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "All tests passed!"
    rm -rf "$TEST_DIR"
    return 0
  else
    echo "Some tests failed. Test directory preserved: $TEST_DIR"
    return 1
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-Assertion failed}"
  
  ((TESTS_RUN++))
  
  if [[ "$expected" == "$actual" ]]; then
    echo "✓ $message"
    ((TESTS_PASSED++))
    return 0
  else
    echo "✗ $message"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    ((TESTS_FAILED++))
    return 1
  fi
}

assert_json_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-JSON assertion failed}"
  
  ((TESTS_RUN++))
  
  # Normalize JSON for comparison
  local norm_expected norm_actual
  norm_expected=$(echo "$expected" | jq -S . 2>/dev/null) || norm_expected="$expected"
  norm_actual=$(echo "$actual" | jq -S . 2>/dev/null) || norm_actual="$actual"
  
  if [[ "$norm_expected" == "$norm_actual" ]]; then
    echo "✓ $message"
    ((TESTS_PASSED++))
    return 0
  else
    echo "✗ $message"
    echo "  Expected: $norm_expected"
    echo "  Actual:   $norm_actual"
    ((TESTS_FAILED++))
    return 1
  fi
}

assert_exists() {
  local path="$1"
  local message="${2:-File should exist}"
  
  ((TESTS_RUN++))
  
  if [[ -e "$path" ]]; then
    echo "✓ $message: $path"
    ((TESTS_PASSED++))
    return 0
  else
    echo "✗ $message: $path"
    ((TESTS_FAILED++))
    return 1
  fi
}

assert_return_code() {
  local expected_rc="$1"
  local actual_rc="$2"
  local message="${3:-Return code assertion failed}"
  
  ((TESTS_RUN++))
  
  if [[ $expected_rc -eq $actual_rc ]]; then
    echo "✓ $message"
    ((TESTS_PASSED++))
    return 0
  else
    echo "✗ $message"
    echo "  Expected: $expected_rc"
    echo "  Actual:   $actual_rc"
    ((TESTS_FAILED++))
    return 1
  fi
}

assert_empty() {
  local actual="$1"
  local message="${2:-Should be empty}"
  
  ((TESTS_RUN++))
  
  if [[ -z "$actual" ]]; then
    echo "✓ $message"
    ((TESTS_PASSED++))
    return 0
  else
    echo "✗ $message"
    echo "  Expected: <empty string>"
    echo "  Actual:   [$actual]"
    ((TESTS_FAILED++))
    return 1
  fi
}

#===============================================================================
# Test: Basic JSON Registry Operations
#===============================================================================
test_json_registry_basic() {
  echo "=== Test: Basic JSON Registry Operations ==="
  
  local db_path="$TEST_DIR/basic.db"
  local result
  
  # Test 1: Set simple string
  json_registry "$db_path" set "simple" '"hello world"'
  assert_equals $? 0 "Set simple string"
  assert_exists "$db_path/simple.json" "JSON file created"
  
  # Test 2: Get simple string (raw mode strips quotes)
  result=$(json_registry "$db_path" get "simple")
  assert_equals 'hello world' "$result" "Get simple string (raw mode)"
  
  # Test 3: Set complex JSON object
  local complex_json='{
    "name": "test-node",
    "type": "SCH",
    "network": {
      "interfaces": ["eth0", "eth1"],
      "vlans": [100, 200, 300]
    },
    "storage": {
      "disks": ["sda", "sdb", "sdc"],
      "raid": {
        "level": 5,
        "devices": ["/dev/sda1", "/dev/sdb1", "/dev/sdc1"]
      }
    },
    "metadata": {
      "created": "2024-01-01T00:00:00Z",
      "tags": ["production", "database", "critical"]
    }
  }'
  
  json_registry "$db_path" set "complex" "$complex_json"
  assert_equals $? 0 "Set complex JSON object"
  
  # Test 4: Get complex JSON object
  result=$(json_registry "$db_path" get "complex")
  assert_json_equals "$complex_json" "$result" "Get complex JSON object"
  
  # Test 5: List keys
  result=$(json_registry "$db_path" list | sort | tr '\n' ' ')
  assert_equals "complex simple " "$result" "List keys"
  
  # Test 6: View aggregated JSON
  result=$(json_registry "$db_path" view)
  echo "$result" | jq -e '.simple == "hello world"' >/dev/null
  assert_equals $? 0 "View contains simple key"
  echo "$result" | jq -e '.complex.type == "SCH"' >/dev/null
  assert_equals $? 0 "View contains complex key"
  
  # Test 7: Delete key
  json_registry "$db_path" delete "simple"
  assert_equals $? 0 "Delete key"
  json_registry "$db_path" exists "simple"
  assert_equals $? 1 "Key no longer exists"
  
  # Test 8: Invalid JSON
  json_registry "$db_path" set "invalid" "not valid json {" 2>/dev/null
  assert_equals $? 2 "Reject invalid JSON"
}

#===============================================================================
# Test: Edge Cases and Special Characters
#===============================================================================
test_json_registry_edge_cases() {
  echo -e "\n=== Test: Edge Cases and Special Characters ==="
  
  local db_path="$TEST_DIR/edge.db"
  local result
  
  # Test 1: Empty string value (raw mode returns truly empty)
  json_registry "$db_path" set "empty" '""'
  result=$(json_registry "$db_path" get "empty")
  assert_empty "$result" "Empty string value (raw mode)"
  
  # Test 2: Special characters in JSON
  local special_json='{
    "quotes": "She said \"Hello\"",
    "newlines": "Line 1\nLine 2\nLine 3",
    "tabs": "Col1\tCol2\tCol3",
    "backslashes": "C:\\Users\\Test",
    "unicode": "Hello 🌍 World 🚀",
    "control": "\u0001\u0002\u0003"
  }'
  
  json_registry "$db_path" set "special" "$special_json"
  result=$(json_registry "$db_path" get "special")
  assert_json_equals "$special_json" "$result" "Special characters preserved"
  
  # Test 3: Large JSON (test scalability)
  local large_array="["
  for i in {1..1000}; do
    large_array+="{\"id\":$i,\"data\":\"value$i\"},"
  done
  large_array="${large_array%,}]"
  
  json_registry "$db_path" set "large" "$large_array"
  assert_equals $? 0 "Set large JSON array (1000 items)"
  
  # Test 4: Very long key name
  local long_key="this_is_a_very_long_key_name_that_tests_filesystem_limits_123456789"
  json_registry "$db_path" set "$long_key" '"test"'
  assert_equals $? 0 "Set with long key name"
  
  # Test 5: Invalid key names
  json_registry "$db_path" set "invalid key with spaces" '"test"' 2>/dev/null
  assert_equals $? 2 "Reject key with spaces"
  
  json_registry "$db_path" set "invalid/key" '"test"' 2>/dev/null
  assert_equals $? 2 "Reject key with slash"
  
  # Test 6: Null values
  json_registry "$db_path" set "null_value" 'null'
  result=$(json_registry "$db_path" get "null_value")
  assert_equals "null" "$result" "Null value preserved"
  
  # Test 7: Boolean values
  json_registry "$db_path" set "bool_true" 'true'
  json_registry "$db_path" set "bool_false" 'false'
  result=$(json_registry "$db_path" get "bool_true")
  assert_equals "true" "$result" "Boolean true preserved"
}

#===============================================================================
# Test: Concurrent Access and Locking
#===============================================================================
test_json_registry_concurrent() {
  echo -e "\n=== Test: Concurrent Access and Locking ==="
  
  local db_path="$TEST_DIR/concurrent.db"
  local pids=()
  
  # Test 1: Multiple readers (should work)
  json_registry "$db_path" set "shared" '"initial value"'
  
  for i in {1..5}; do
    (json_registry "$db_path" get "shared" >/dev/null) &
    pids+=($!)
  done
  
  # Wait for all readers
  local failed=0
  for pid in "${pids[@]}"; do
    wait $pid || ((failed++))
  done
  
  assert_equals 0 $failed "Multiple concurrent readers"
  
  # Test 2: Concurrent writes (should serialize)
  pids=()
  for i in {1..10}; do
    (json_registry "$db_path" set "counter_$i" "\"value_$i\"") &
    pids+=($!)
  done
  
  # Wait for all writers
  failed=0
  for pid in "${pids[@]}"; do
    wait $pid || ((failed++))
  done
  
  assert_equals 0 $failed "Concurrent writes completed"
  
  # Verify all writes succeeded
  local count=0
  for i in {1..10}; do
    if json_registry "$db_path" exists "counter_$i"; then
      ((count++))
    fi
  done
  assert_equals 10 $count "All concurrent writes persisted"
  
  # Test 3: Stale lock detection (simulate crashed process)
  local lock_file="$db_path/.lock/stale_test.lock"
  mkdir -p "$db_path/.lock"
  
  # Create stale lock with non-existent PID
  echo "ts:$(date +%s)" > "$lock_file"
  echo "pid:999999" >> "$lock_file"
  echo "op:write" >> "$lock_file"
  
  # Should detect stale lock and proceed
  json_registry "$db_path" set "stale_test" '"should work"'
  assert_equals $? 0 "Stale lock detected and removed"
}

#===============================================================================
# Test: Host Registry Functions
#===============================================================================
test_host_registry() {
  echo -e "\n=== Test: Host Registry Functions ==="
  
  # Test 1: Basic host registry operations
  host_registry "$TEST_MAC1" set "hostname" '"node-001"'
  assert_equals $? 0 "Set hostname"
  
  local result
  result=$(host_registry "$TEST_MAC1" get "hostname")
  assert_equals 'node-001' "$result" "Get hostname returns raw value"
  
  # Test 2: Complex storage configuration
  local storage_config='{
    "disks": [
      {"device": "sda", "size": "1TB", "type": "SSD"},
      {"device": "sdb", "size": "2TB", "type": "HDD"},
      {"device": "sdc", "size": "2TB", "type": "HDD"}
    ],
    "volumes": [
      {
        "name": "system",
        "raid": "mirror",
        "devices": ["sda1", "sdb1"]
      },
      {
        "name": "data", 
        "raid": "raid5",
        "devices": ["sda2", "sdb2", "sdc1"]
      }
    ]
  }'
  
  host_registry "$TEST_MAC1" set "storage_config" "$storage_config"
  assert_equals $? 0 "Set complex storage config"
  
  # Test 3: String values (backward compatibility)
  host_registry "$TEST_MAC1" set "type" "SCH"
  result=$(host_registry "$TEST_MAC1" get "type")
  assert_equals 'SCH' "$result" "String value auto-wrapped, returns raw"
  
  # Test 4: List host keys
  result=$(host_registry "$TEST_MAC1" list | sort | tr '\n' ' ')
  assert_equals "UPDATED hostname storage_config type " "$result" "List host keys"
  
  # Test 5: View entire host configuration
  result=$(host_registry "$TEST_MAC1" view)
  echo "$result" | jq -e '.hostname == "node-001"' >/dev/null
  assert_equals $? 0 "View contains all host data"
  
  # Test 6: Multiple hosts
  host_registry "$TEST_MAC2" set "hostname" '"node-002"'
  host_registry "$TEST_MAC2" set "type" '"TCH"'
  
  assert_exists "$TEST_HOSTS_DIR/${TEST_MAC1_NORM}.db" "First host DB exists"
  assert_exists "$TEST_HOSTS_DIR/${TEST_MAC2_NORM}.db" "Second host DB exists"
}

#===============================================================================
# Test: Registry Search Functions
#===============================================================================
test_registry_search() {
  echo -e "\n=== Test: Registry Search Functions ==="
  
  # Setup test data with lowercase keys for consistency
  host_registry "$TEST_MAC1" set "type" '"SCH"'
  host_registry "$TEST_MAC1" set "status" '"active"'
  host_registry "$TEST_MAC1" set "datacenter" '"dc1"'
  
  host_registry "$TEST_MAC2" set "type" '"TCH"'
  host_registry "$TEST_MAC2" set "status" '"active"'
  host_registry "$TEST_MAC2" set "datacenter" '"dc1"'
  
  # Create third host
  local test_mac3="52:54:00:77:88:99"
  host_registry "$test_mac3" set "type" '"SCH"'
  host_registry "$test_mac3" set "status" '"maintenance"'
  host_registry "$test_mac3" set "datacenter" '"dc2"'
  
  # Test search functionality
  local results
  
  # Search by type
  results=$(registry_search "host" "type" "SCH" | sort | tr '\n' ' ')
  assert_equals "525400112233 525400778899 " "$results" "Search hosts by type=SCH"
  
  # Search by status
  results=$(registry_search "host" "status" "active" | sort | tr '\n' ' ')
  assert_equals "525400112233 525400445566 " "$results" "Search hosts by status=active"
  
  # Search by datacenter
  results=$(registry_search "host" "datacenter" "dc1" | sort | tr '\n' ' ')
  assert_equals "525400112233 525400445566 " "$results" "Search hosts by datacenter=dc1"
}

#===============================================================================
# Test: Migration from KV to JSON
#===============================================================================
test_migration() {
  echo -e "\n=== Test: Migration from KV to JSON ==="
  
  # Create legacy KV config file
  local kv_file="$TEST_HOSTS_DIR/${TEST_MAC1_NORM}.conf"
  cat > "$kv_file" <<EOF
# Auto-generated host config
# MAC: $TEST_MAC1
HOSTNAME="legacy-node"
TYPE="SCH"
STATUS="active"
NETWORK_INTERFACES="eth0,eth1,eth2"
STORAGE_DISKS="sda,sdb,sdc"
CPU_CORES="16"
MEMORY_GB="64"
BOOLEAN_TEST="true"
UPDATED="2024-01-01T00:00:00Z"
EOF
  
  assert_exists "$kv_file" "Legacy KV file created"
  
  # Test migration
  migrate_host_to_registry "$TEST_MAC1"
  assert_equals $? 0 "Migration completed"
  
  # Verify migrated data (returns raw values)
  local result
  result=$(host_registry "$TEST_MAC1" get "HOSTNAME")
  assert_equals 'legacy-node' "$result" "String migrated correctly"
  
  result=$(host_registry "$TEST_MAC1" get "CPU_CORES")
  assert_equals '16' "$result" "Number migrated correctly"
  
  result=$(host_registry "$TEST_MAC1" get "BOOLEAN_TEST")
  assert_equals 'true' "$result" "Boolean migrated correctly"
  
  # Verify old file was archived with new extension
  assert_exists "${kv_file}.pre-registry" "KV file archived"
}

#===============================================================================
# Test: Error Handling and Recovery
#===============================================================================
test_error_handling() {
  echo -e "\n=== Test: Error Handling and Recovery ==="
  
  local db_path="$TEST_DIR/errors.db"
  
  # Test 1: Corrupted JSON file
  mkdir -p "$db_path"
  echo "not valid json{" > "$db_path/corrupted.json"
  
  # Should fail to read with error code 2 (corrupted)
  json_registry "$db_path" get "corrupted" 2>/dev/null
  local rc=$?
  assert_return_code 2 $rc "Corrupted file returns error code 2"
  
  # Test 2: Permission denied (if not root)
  if [[ $EUID -ne 0 ]]; then
    local readonly_db="$TEST_DIR/readonly.db"
    mkdir -p "$readonly_db"
    json_registry "$readonly_db" set "test" '"value"'
    chmod 444 "$readonly_db/test.json"
    chmod 555 "$readonly_db"
    
    # Should fail to write
    json_registry "$readonly_db" set "test" '"new value"' 2>/dev/null
    assert_equals $? 2 "Permission denied on write"
    
    # Cleanup
    chmod 755 "$readonly_db"
    chmod 644 "$readonly_db/test.json"
  fi
  
  # Test 3: Recovery from interrupted write
  local tmp_file="$db_path/interrupted.json.12345.tmp"
  echo '{"test": "incomplete"' > "$tmp_file"
  
  # Should ignore incomplete temp file
  json_registry "$db_path" exists "interrupted"
  assert_equals $? 1 "Incomplete temp file ignored"
  
  # Should successfully write new value
  json_registry "$db_path" set "interrupted" '"complete"'
  result=$(json_registry "$db_path" get "interrupted")
  assert_equals 'complete' "$result" "Recovery from interrupted write (raw mode)"
}

#===============================================================================
# Test: Host Configuration Compatibility
#===============================================================================
test_host_config_compatibility() {
  echo -e "\n=== Test: Host Config Compatibility ==="
  
  # Test that host_config alias works exactly like host_registry
  
  # Test 1: Set operation
  host_config "$TEST_MAC1" set "compat_test" '"working"'
  assert_equals $? 0 "host_config set works"
  
  # Test 2: Get operation (returns raw value)
  result=$(host_config "$TEST_MAC1" get "compat_test")
  assert_equals 'working' "$result" "host_config get works"
  
  # Test 3: Exists operation
  host_config "$TEST_MAC1" exists "compat_test"
  assert_equals $? 0 "host_config exists works"
  
  # Test 4: Equals operation (compares raw values)
  host_config "$TEST_MAC1" equals "compat_test" 'working'
  assert_equals 0 $? "host_config equals works"
  
  host_config "$TEST_MAC1" equals "compat_test" 'different'
  assert_equals 1 $? "host_config equals fails correctly"
}

#===============================================================================
# Main Test Runner
#===============================================================================
run_all_tests() {
  test_setup
  
  # Run all test suites
  test_json_registry_basic
  test_json_registry_edge_cases
  test_json_registry_concurrent
  test_host_registry
  test_registry_search
  test_migration
  test_error_handling
  test_host_config_compatibility
  
  test_teardown
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Source the registry functions first
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../../lib/functions.d/hps-registry.sh" || {
    echo "ERROR: Cannot source hps-registry.sh" >&2
    exit 1
  }
  
  # Mock required functions for testing
  normalise_mac() {
    echo "$1" | tr -d ':'
  }
  
  make_timestamp() {
    date -Iseconds
  }
  
  hps_log() {
    local level="$1"
    shift
    echo "[TEST LOG] $level: $*" >&2
  }
  
  # Run the tests
  run_all_tests
fi
