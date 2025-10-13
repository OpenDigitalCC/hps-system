#!/bin/bash
#
# test_keysafe.sh - Test suite for keysafe functions
#
# Usage: ./test_keysafe.sh
#

# Resolve script directory and source functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/functions.sh"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test setup - create temporary test environment
setup_test_env() {
    export TEST_BASE_DIR="/tmp/hps-test-$$"
    export HPS_CLUSTER_CONFIG_BASE_DIR="${TEST_BASE_DIR}/hps-config/clusters"
    
    # Create test cluster structure
    mkdir -p "${HPS_CLUSTER_CONFIG_BASE_DIR}/test-cluster/keysafe/tokens"
    
    # Create active-cluster symlink
    ln -sf "${HPS_CLUSTER_CONFIG_BASE_DIR}/test-cluster" \
           "${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
    
    # Create cluster config with open mode
    cat > "${HPS_CLUSTER_CONFIG_BASE_DIR}/test-cluster/cluster.conf" <<EOF
HPS_KEYSAFE_MODE="open"
EOF
}

# Test teardown - remove temporary test environment
teardown_test_env() {
    rm -rf "$TEST_BASE_DIR"
}

# Test helper functions
pass() {
    echo "  ✓ PASS: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo "  ✗ FAIL: $1"
    ((TESTS_FAILED++))
}

run_test() {
    ((TESTS_RUN++))
    echo ""
    echo "Test $TESTS_RUN: $1"
}

# Test summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "=========================================="
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✓ All tests passed"
        return 0
    else
        echo "✗ Some tests failed"
        return 1
    fi
}

#===============================================================================
# Test Functions
#===============================================================================

test_get_keysafe_dir() {
    run_test "get_keysafe_dir - should return keysafe directory path"
    
    local result
    result=$(get_keysafe_dir)
    local retval=$?
    
    if [[ $retval -eq 0 ]]; then
        pass "Function returned success (0)"
    else
        fail "Function returned error code: $retval"
    fi
    
    if [[ "$result" == "${HPS_CLUSTER_CONFIG_BASE_DIR}/test-cluster/keysafe" ]]; then
        pass "Correct keysafe directory path returned"
    else
        fail "Incorrect path returned: $result"
    fi
    
    if [[ -d "$result/tokens" ]]; then
        pass "Tokens directory exists"
    else
        fail "Tokens directory not created"
    fi
}

test_get_keysafe_dir_no_cluster() {
    run_test "get_keysafe_dir - should fail when no active cluster"
    
    # Remove active cluster symlink
    rm -f "${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
    
    local result
    result=$(get_keysafe_dir 2>/dev/null)
    local retval=$?
    
    if [[ $retval -eq 1 ]]; then
        pass "Function correctly returned error code 1"
    else
        fail "Expected error code 1, got: $retval"
    fi
    
    # Restore symlink for other tests
    ln -sf "${HPS_CLUSTER_CONFIG_BASE_DIR}/test-cluster" \
           "${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
}

test_keysafe_issue_token() {
    run_test "keysafe_issue_token - should issue valid token"
    
    local token
    token=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    local retval=$?
    
    if [[ $retval -eq 0 ]]; then
        pass "Function returned success (0)"
    else
        fail "Function returned error code: $retval"
    fi
    
    if [[ -n "$token" ]]; then
        pass "Token generated: ${token:0:8}..."
    else
        fail "No token returned"
    fi
    
    # Verify token file exists
    local keysafe_dir
    keysafe_dir=$(get_keysafe_dir)
    if [[ -f "$keysafe_dir/tokens/$token" ]]; then
        pass "Token file created"
    else
        fail "Token file not found"
    fi
    
    # Verify token metadata
    source "$keysafe_dir/tokens/$token"
    
    if [[ "$NODE_MAC" == "00:11:22:33:44:55" ]]; then
        pass "NODE_MAC correct in token file"
    else
        fail "NODE_MAC incorrect: $NODE_MAC"
    fi
    
    if [[ "$NODE_ID" == "test-node-001" ]]; then
        pass "NODE_ID correct in token file"
    else
        fail "NODE_ID incorrect: $NODE_ID"
    fi
    
    if [[ "$PURPOSE" == "backup" ]]; then
        pass "PURPOSE correct in token file"
    else
        fail "PURPOSE incorrect: $PURPOSE"
    fi
    
    if [[ "$MODE" == "open" ]]; then
        pass "MODE correct in token file"
    else
        fail "MODE incorrect: $MODE"
    fi
}

test_keysafe_issue_token_missing_args() {
    run_test "keysafe_issue_token - should fail with missing arguments"
    
    local result
    result=$(keysafe_issue_token "" "" 2>/dev/null)
    local retval=$?
    
    if [[ $retval -eq 3 ]]; then
        pass "Function correctly returned error code 3"
    else
        fail "Expected error code 3, got: $retval"
    fi
}

test_keysafe_validate_token() {
    run_test "keysafe_validate_token - should validate and consume token"
    
    # Issue a token first
    local token
    token=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    
    # Validate the token
    keysafe_validate_token "$token" "backup" 2>/dev/null
    local retval=$?
    
    if [[ $retval -eq 0 ]]; then
        pass "Token validated successfully"
    else
        fail "Token validation failed with code: $retval"
    fi
    
    # Verify token file was deleted (consumed)
    local keysafe_dir
    keysafe_dir=$(get_keysafe_dir)
    if [[ ! -f "$keysafe_dir/tokens/$token" ]]; then
        pass "Token file deleted after consumption"
    else
        fail "Token file still exists after validation"
    fi
}

test_keysafe_validate_token_already_consumed() {
    run_test "keysafe_validate_token - should fail on already consumed token"
    
    # Issue and consume a token
    local token
    token=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    keysafe_validate_token "$token" 2>/dev/null
    
    # Try to validate again
    keysafe_validate_token "$token" 2>/dev/null
    local retval=$?
    
    if [[ $retval -eq 2 ]]; then
        pass "Function correctly returned error code 2 (already consumed)"
    else
        fail "Expected error code 2, got: $retval"
    fi
}

test_keysafe_validate_token_purpose_mismatch() {
    run_test "keysafe_validate_token - should fail on purpose mismatch"
    
    # Issue a token with "backup" purpose
    local token
    token=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    
    # Try to validate with different purpose
    keysafe_validate_token "$token" "restore" 2>/dev/null
    local retval=$?
    
    if [[ $retval -eq 4 ]]; then
        pass "Function correctly returned error code 4 (purpose mismatch)"
    else
        fail "Expected error code 4, got: $retval"
    fi
}

test_keysafe_validate_token_expired() {
    run_test "keysafe_validate_token - should fail on expired token"
    
    # Issue a token
    local token
    token=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    
    # Manually expire the token by modifying the file
    local keysafe_dir
    keysafe_dir=$(get_keysafe_dir)
    local token_file="$keysafe_dir/tokens/$token"
    
    # Set EXPIRES to past timestamp
    sed -i 's/EXPIRES=.*/EXPIRES=1000000000/' "$token_file"
    
    # Try to validate expired token
    keysafe_validate_token "$token" 2>/dev/null
    local retval=$?
    
    if [[ $retval -eq 3 ]]; then
        pass "Function correctly returned error code 3 (expired)"
    else
        fail "Expected error code 3, got: $retval"
    fi
}

test_keysafe_cleanup_expired() {
    run_test "keysafe_cleanup_expired - should remove expired tokens"
    
    local keysafe_dir
    keysafe_dir=$(get_keysafe_dir)
    
    # Create multiple tokens
    local token1 token2 token3
    token1=$(keysafe_issue_token "00:11:22:33:44:55" "backup" "test-node-001" 2>/dev/null)
    token2=$(keysafe_issue_token "00:11:22:33:44:66" "backup" "test-node-002" 2>/dev/null)
    token3=$(keysafe_issue_token "00:11:22:33:44:77" "backup" "test-node-003" 2>/dev/null)
    
    # Manually expire token1 and token2
    sed -i 's/EXPIRES=.*/EXPIRES=1000000000/' "$keysafe_dir/tokens/$token1"
    sed -i 's/EXPIRES=.*/EXPIRES=1000000000/' "$keysafe_dir/tokens/$token2"
    
    # Run cleanup
    keysafe_cleanup_expired 2>/dev/null
    local retval=$?
    
    if [[ $retval -eq 0 ]]; then
        pass "Cleanup function returned success"
    else
        fail "Cleanup function returned error: $retval"
    fi
    
    # Verify expired tokens removed
    if [[ ! -f "$keysafe_dir/tokens/$token1" ]]; then
        pass "Expired token1 removed"
    else
        fail "Expired token1 still exists"
    fi
    
    if [[ ! -f "$keysafe_dir/tokens/$token2" ]]; then
        pass "Expired token2 removed"
    else
        fail "Expired token2 still exists"
    fi
    
    # Verify valid token still exists
    if [[ -f "$keysafe_dir/tokens/$token3" ]]; then
        pass "Valid token3 still exists"
    else
        fail "Valid token3 was incorrectly removed"
    fi
}

#===============================================================================
# Run all tests
#===============================================================================

main() {
    echo "=========================================="
    echo "Keysafe Function Test Suite"
    echo "=========================================="
    
    # Setup test environment
    echo "Setting up test environment..."
    setup_test_env
    
    # Run tests
    test_get_keysafe_dir
    test_get_keysafe_dir_no_cluster
    test_keysafe_issue_token
    test_keysafe_issue_token_missing_args
    test_keysafe_validate_token
    test_keysafe_validate_token_already_consumed
    test_keysafe_validate_token_purpose_mismatch
    test_keysafe_validate_token_expired
    test_keysafe_cleanup_expired
    
    # Print summary
    print_summary
    local exit_code=$?
    
    # Cleanup
    echo ""
    echo "Cleaning up test environment..."
    teardown_test_env
    
    exit $exit_code
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
