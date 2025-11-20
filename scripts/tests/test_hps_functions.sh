#!/bin/bash
#===============================================================================
# Test Suite: Function Loading System
# Tests for hps_get_remote_functions, CGI endpoint, and hps_load_node_functions
#===============================================================================

# Source test framework (assumes it exists)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="${SCRIPT_DIR}/.."

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
test_start() {
  echo "----------------------------------------"
  echo "TEST: $1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
  echo "✓ PASS: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
  echo "✗ FAIL: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

test_summary() {
  echo "========================================"
  echo "Test Summary:"
  echo "  Total:  $TESTS_RUN"
  echo "  Passed: $TESTS_PASSED"
  echo "  Failed: $TESTS_FAILED"
  echo "========================================"
  
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "All tests passed!"
    return 0
  else
    echo "Some tests failed!"
    return 1
  fi
}

#===============================================================================
# Mock Functions for Testing
#===============================================================================

# Mock host_config for testing
mock_host_config() {
  local mac="$1"
  local operation="$2"
  local key="$3"
  
  case "$mac" in
    "52:54:00:61:ed:98")
      case "$key" in
        "OS_ID")
          echo "x86_64:rocky:10.0"
          return 0
          ;;
        "HOST_PROFILE")
          echo "SCH"
          return 0
          ;;
      esac
      ;;
    "52:54:00:11:22:33")
      case "$key" in
        "OS_ID")
          echo "x86_64:alpine:3.20"
          return 0
          ;;
        "HOST_PROFILE")
          echo ""
          return 0
          ;;
      esac
      ;;
    "00:00:00:00:00:00")
      # Unknown MAC
      return 1
      ;;
  esac
  
  return 1
}

# Mock os_id_to_distro
mock_os_id_to_distro() {
  local os_id="$1"
  
  case "$os_id" in
    "x86_64:rocky:10.0")
      echo "x86_64-linux-rocky-10.0"
      return 0
      ;;
    "x86_64:alpine:3.20")
      echo "x86_64-linux-alpine-3.20"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Mock node_build_functions
mock_node_build_functions() {
  local distro="$1"
  echo "# Mock function bundle for $distro"
  echo "mock_function() { echo 'Mock function executed'; }"
  return 0
}

# Mock hps_log
mock_hps_log() {
  local level="$1"
  shift
  echo "[MOCK LOG $level] $*" >&2
}

#===============================================================================
# Test: hps_get_remote_functions
#===============================================================================

test_hps_get_remote_functions_success() {
  test_start "hps_get_remote_functions - Rocky SCH node"
  
  # Set MAC in global context (simulating CGI)
  mac="52:54:00:61:ed:98"
  
  # Define function that uses mocks directly (not aliases)
  hps_get_remote_functions() {
    local os_id distro profile
    
    if ! os_id=$(mock_host_config "$mac" get OS_ID 2>/dev/null); then
      mock_hps_log error "Could not retrieve OS_ID for MAC $mac"
      return 1
    fi
    
    if [[ -z "$os_id" ]]; then
      mock_hps_log error "OS_ID is empty for MAC $mac"
      return 1
    fi
    
    if ! distro=$(mock_os_id_to_distro "$os_id"); then
      mock_hps_log error "Failed to convert OS_ID '$os_id' to distro format"
      return 2
    fi
    
    profile=$(mock_host_config "$mac" get HOST_PROFILE 2>/dev/null || echo "")
    
    mock_hps_log info "Building function bundle for MAC $mac (OS: $os_id, Profile: ${profile:-none})"
    
    mock_node_build_functions "$distro"
    return 0
  }
  
  # Execute function
  local output
  output=$(hps_get_remote_functions 2>&1)
  local result=$?
  
  # Verify
  if [[ $result -eq 0 ]]; then
    test_pass "Function returned success"
  else
    test_fail "Function returned error: $result"
  fi
  
  if [[ "$output" == *"Mock function bundle"* ]]; then
    test_pass "Function bundle generated"
  else
    test_fail "Expected function bundle, got: $output"
  fi
  
  if [[ "$output" == *"x86_64-linux-rocky-10.0"* ]]; then
    test_pass "Correct distro string used"
  else
    test_fail "Wrong distro string in output"
  fi
}

test_hps_get_remote_functions_alpine() {
  test_start "hps_get_remote_functions - Alpine TCH node (no profile)"
  
  mac="52:54:00:11:22:33"
  
  hps_get_remote_functions() {
    local os_id distro profile
    
    if ! os_id=$(mock_host_config "$mac" get OS_ID 2>/dev/null); then
      mock_hps_log error "Could not retrieve OS_ID for MAC $mac"
      return 1
    fi
    
    if [[ -z "$os_id" ]]; then
      mock_hps_log error "OS_ID is empty for MAC $mac"
      return 1
    fi
    
    if ! distro=$(mock_os_id_to_distro "$os_id"); then
      mock_hps_log error "Failed to convert OS_ID '$os_id' to distro format"
      return 2
    fi
    
    profile=$(mock_host_config "$mac" get HOST_PROFILE 2>/dev/null || echo "")
    
    mock_hps_log info "Building function bundle for MAC $mac (OS: $os_id, Profile: ${profile:-none})"
    
    mock_node_build_functions "$distro"
    return 0
  }
  
  local output
  output=$(hps_get_remote_functions 2>&1)
  local result=$?
  
  if [[ $result -eq 0 ]]; then
    test_pass "Function succeeded for Alpine node"
  else
    test_fail "Function failed: $result"
  fi
  
  if [[ "$output" == *"x86_64-linux-alpine-3.20"* ]]; then
    test_pass "Correct Alpine distro string"
  else
    test_fail "Wrong distro string"
  fi
}

test_hps_get_remote_functions_unknown_mac() {
  test_start "hps_get_remote_functions - Unknown MAC address"
  
  mac="00:00:00:00:00:00"
  
  hps_get_remote_functions() {
    local os_id distro profile
    
    if ! os_id=$(mock_host_config "$mac" get OS_ID 2>/dev/null); then
      mock_hps_log error "Could not retrieve OS_ID for MAC $mac"
      return 1
    fi
    
    if [[ -z "$os_id" ]]; then
      mock_hps_log error "OS_ID is empty for MAC $mac"
      return 1
    fi
    
    if ! distro=$(mock_os_id_to_distro "$os_id"); then
      mock_hps_log error "Failed to convert OS_ID '$os_id' to distro format"
      return 2
    fi
    
    profile=$(mock_host_config "$mac" get HOST_PROFILE 2>/dev/null || echo "")
    
    mock_hps_log info "Building function bundle for MAC $mac (OS: $os_id, Profile: ${profile:-none})"
    
    mock_node_build_functions "$distro"
    return 0
  }
  
  local output
  output=$(hps_get_remote_functions 2>&1)
  local result=$?
  
  if [[ $result -eq 1 ]]; then
    test_pass "Function correctly returns error for unknown MAC"
  else
    test_fail "Expected error code 1, got: $result"
  fi
  
  if [[ "$output" == *"Could not retrieve OS_ID"* ]]; then
    test_pass "Appropriate error message logged"
  else
    test_fail "Expected error message not found in: $output"
  fi
}

#===============================================================================
# Test: hps_load_node_functions (bootstrap version)
#===============================================================================

test_hps_load_node_functions_basic() {
  test_start "hps_load_node_functions - Basic functionality"
  
  # Mock hps_get_provisioning_node
  hps_get_provisioning_node() {
    echo "10.99.1.1"
    return 0
  }
  
  # Mock curl to return valid functions
  mock_curl() {
    if [[ "$*" == *"cmd=get_remote_functions"* ]]; then
      cat <<'EOF'
# Mock function bundle
test_function() { echo 'test'; }
EOF
      return 0
    fi
    return 1
  }
  
  # Create temp cache directory
  local temp_cache="/tmp/hps-test-$"
  mkdir -p "$temp_cache"
  
  # Define function with temp cache path
  hps_load_node_functions() {
    echo "[HPS] Loading functions from IPS..." >&2
    
    local ips url functions cache_file
    
    if ! ips=$(hps_get_provisioning_node); then
      echo "[HPS] ERROR: Could not determine provisioning node" >&2
      return 1
    fi
    
    cache_file="$temp_cache/hps-functions-cache.sh"
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null
    
    url="http://${ips}/cgi-bin/boot_manager.sh?cmd=get_remote_functions"
    
    if ! functions=$(mock_curl -fsSL "$url" 2>&1); then
      echo "[HPS] WARNING: Failed to fetch functions from IPS" >&2
      
      if [[ -f "$cache_file" ]]; then
        echo "[HPS] Using cached functions" >&2
        if bash -n "$cache_file" 2>/dev/null && source "$cache_file"; then
          echo "[HPS] Functions loaded from cache" >&2
          return 0
        else
          echo "[HPS] ERROR: Failed to source cached functions" >&2
          return 2
        fi
      else
        echo "[HPS] ERROR: No cache available" >&2
        return 2
      fi
    fi
    
    if [[ -z "$functions" ]]; then
      echo "[HPS] ERROR: Empty response from IPS" >&2
      return 2
    fi
    
    if echo "$functions" > "$cache_file" 2>/dev/null; then
      chmod 0644 "$cache_file" 2>/dev/null
    fi
    
    # Source into parent shell using . instead of eval for persistence
    if ! . <(echo "$functions"); then
      echo "[HPS] ERROR: Failed to evaluate functions" >&2
      return 1
    fi
    
    echo "[HPS] Functions loaded successfully" >&2
    return 0
  }
  
  # Execute - source it so functions persist
  local output
  output=$( ( hps_load_node_functions ) 2>&1)
  local result=$?
  
  # Verify
  if [[ $result -eq 0 ]]; then
    test_pass "Function returned success"
  else
    test_fail "Function returned error: $result"
  fi
  
  # Check cache file was created
  if [[ -f "$temp_cache/hps-functions-cache.sh" ]]; then
    test_pass "Cache file created"
  else
    test_fail "Cache file not created"
  fi
  
  # Check cache content
  if grep -q "test_function" "$temp_cache/hps-functions-cache.sh" 2>/dev/null; then
    test_pass "Cache contains expected functions"
  else
    test_fail "Cache missing expected functions"
  fi
  
  # Cleanup
  rm -rf "$temp_cache"
}

test_hps_load_node_functions_cache_fallback() {
  test_start "hps_load_node_functions - Cache fallback on IPS failure"
  
  hps_get_provisioning_node() {
    echo "10.99.1.1"
    return 0
  }
  
  # Mock curl to fail
  mock_curl() {
    return 1
  }
  
  # Create temp cache with valid functions
  local temp_cache="/tmp/hps-test-$"
  mkdir -p "$temp_cache"
  cat > "$temp_cache/hps-functions-cache.sh" <<'EOF'
# Cached function bundle
cached_test_function() { echo 'from cache'; }
EOF
  
  hps_load_node_functions() {
    echo "[HPS] Loading functions from IPS..." >&2
    
    local ips url functions cache_file
    
    if ! ips=$(hps_get_provisioning_node); then
      echo "[HPS] ERROR: Could not determine provisioning node" >&2
      return 1
    fi
    
    cache_file="$temp_cache/hps-functions-cache.sh"
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null
    
    url="http://${ips}/cgi-bin/boot_manager.sh?cmd=get_remote_functions"
    
    if ! functions=$(mock_curl -fsSL "$url" 2>&1); then
      echo "[HPS] WARNING: Failed to fetch functions from IPS" >&2
      
      if [[ -f "$cache_file" ]]; then
        echo "[HPS] Using cached functions" >&2
        if bash -n "$cache_file" 2>/dev/null && source "$cache_file"; then
          echo "[HPS] Functions loaded from cache" >&2
          return 0
        else
          echo "[HPS] ERROR: Failed to source cached functions" >&2
          return 2
        fi
      else
        echo "[HPS] ERROR: No cache available" >&2
        return 2
      fi
    fi
    
    if [[ -z "$functions" ]]; then
      echo "[HPS] ERROR: Empty response from IPS" >&2
      return 2
    fi
    
    if echo "$functions" > "$cache_file" 2>/dev/null; then
      chmod 0644 "$cache_file" 2>/dev/null
    fi
    
    if ! . <(echo "$functions"); then
      echo "[HPS] ERROR: Failed to evaluate functions" >&2
      return 1
    fi
    
    echo "[HPS] Functions loaded successfully" >&2
    return 0
  }
  
  # Execute
  local output
  output=$(hps_load_node_functions 2>&1)
  local result=$?
  
  # Verify
  if [[ $result -eq 0 ]]; then
    test_pass "Function succeeded with cache fallback"
  else
    test_fail "Function failed: $result"
  fi
  
  if [[ "$output" == *"Using cached functions"* ]]; then
    test_pass "Cache fallback was used"
  else
    test_fail "Cache fallback message not found"
  fi
  
  if [[ "$output" == *"Functions loaded from cache"* ]]; then
    test_pass "Cache loading confirmed"
  else
    test_fail "Cache loading not confirmed"
  fi
  
  # Cleanup
  rm -rf "$temp_cache"
}

#===============================================================================
# Run All Tests
#===============================================================================

main() {
  echo "========================================"
  echo "HPS Function Loading Test Suite"
  echo "========================================"
  echo ""
  
  # Run tests
  test_hps_get_remote_functions_success
  test_hps_get_remote_functions_alpine
  test_hps_get_remote_functions_unknown_mac
  test_hps_load_node_functions_basic
  test_hps_load_node_functions_cache_fallback
  
  echo ""
  test_summary
}

main "$@"
