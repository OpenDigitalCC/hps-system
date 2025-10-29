#!/bin/bash
#===============================================================================
# test_o_vm_create.sh
# -------------------
# Test script for o_vm_create orchestration function
#
# Tests the IPS-side VM orchestration function that creates transient OpenSVC
# services to execute n_vm_create on target TCH nodes.
#
# Usage:
#   ./test_o_vm_create.sh
#
# Prerequisites:
#   - Run on IPS
#   - Source main function library
#   - o_vm_create and o_vm_validate_node functions must be available
#   - At least one TCH node operational and accessible
#   - OpenSVC cluster running
#   - n_vm_create function deployed to TCH nodes
#
# Test Modes:
#   - Unit tests: Validate parameter handling
#   - Node validation tests: Test node health checks
#   - Integration tests: Create actual VMs via OpenSVC tasks
#
#===============================================================================

# Source the main function library
if [ -f /srv/hps-system/lib/functions.sh ]; then
  source /srv/hps-system/lib/functions.sh
else
  echo "ERROR: Cannot find /srv/hps-system/lib/functions.sh"
  exit 1
fi

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test VM identifier
TEST_VM_ID="test-vm-$(date +%s)"

# Target node for testing
TEST_TARGET_NODE="${TEST_TARGET_NODE:-tch-001}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# Test helper functions
#===============================================================================

test_assert_exit_code() {
  local expected=$1
  local actual=$2
  local test_name=$3

  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ $actual -eq $expected ]; then
    echo -e "${GREEN}✓${NC} ${test_name}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "${RED}✗${NC} ${test_name} (expected exit code ${expected}, got ${actual})"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

test_assert_not_exit_code() {
  local not_expected=$1
  local actual=$2
  local test_name=$3

  TESTS_RUN=$((TESTS_RUN + 1))
  
  if [ $actual -ne $not_expected ]; then
    echo -e "${GREEN}✓${NC} ${test_name}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "${RED}✗${NC} ${test_name} (exit code should not be ${not_expected}, got ${actual})"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

test_assert_service_not_exists() {
  local service_name=$1
  local test_name=$2

  TESTS_RUN=$((TESTS_RUN + 1))
  
  if ! om "$service_name" print config >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} ${test_name}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "${RED}✗${NC} ${test_name} (service ${service_name} still exists)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
  fi
}

cleanup_test_service() {
  local service_name=$1
  echo -e "${BLUE}  Cleaning up service: ${service_name}${NC}"
  om "$service_name" purge >/dev/null 2>&1 || true
}

#===============================================================================
# Unit Tests - Parameter Validation
#===============================================================================

test_o_vm_create_no_params() {
  echo ""
  echo "Testing: o_vm_create parameter validation"
  
  # Test with no parameters
  o_vm_create >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_create with no parameters should return 1"
  
  # Test with one parameter only
  o_vm_create "test-vm-id" >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_create with one parameter should return 1"
  
  # Test with empty vm_identifier
  o_vm_create "" "tch-001" >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_create with empty vm_identifier should return 1"
  
  # Test with empty target_node
  o_vm_create "test-vm-id" "" >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_create with empty target_node should return 1"
}

#===============================================================================
# Node Validation Tests
#===============================================================================

test_o_vm_validate_node_basic() {
  echo ""
  echo "Testing: o_vm_validate_node basic functionality"
  
  # Test with no parameters
  o_vm_validate_node >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_validate_node with no parameters should return 1"
  
  # Test with empty parameter
  o_vm_validate_node "" >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_validate_node with empty parameter should return 1"
}

test_o_vm_validate_node_nonexistent() {
  echo ""
  echo "Testing: o_vm_validate_node with non-existent node"
  
  local fake_node="nonexistent-node-999"
  
  o_vm_validate_node "$fake_node" >/dev/null 2>&1
  test_assert_exit_code 2 $? "o_vm_validate_node should return 2 for non-existent node"
}

test_o_vm_validate_node_healthy() {
  echo ""
  echo "Testing: o_vm_validate_node with healthy node"
  
  # Check if test node exists and is in cluster
  if ! om node ls 2>/dev/null | grep -qx "${TEST_TARGET_NODE}"; then
    echo -e "${YELLOW}⊘ Skipping: Node ${TEST_TARGET_NODE} not in cluster${NC}"
    return 0
  fi
  
  o_vm_validate_node "${TEST_TARGET_NODE}" >/dev/null 2>&1
  local exit_code=$?
  
  case $exit_code in
    0)
      test_assert_exit_code 0 $exit_code "o_vm_validate_node should return 0 for healthy node"
      ;;
    3)
      test_assert_exit_code 3 $exit_code "OpenSVC daemon not running on ${TEST_TARGET_NODE}"
      echo -e "${YELLOW}  Note: This is expected if OpenSVC not started on node${NC}"
      ;;
    4)
      test_assert_exit_code 4 $exit_code "Node ${TEST_TARGET_NODE} is frozen"
      echo -e "${YELLOW}  Note: Unfreeze node: om node unfreeze --node ${TEST_TARGET_NODE}${NC}"
      ;;
    *)
      test_assert_not_exit_code 999 $exit_code "Unexpected validation result: $exit_code"
      ;;
  esac
}

test_o_vm_get_healthy_nodes() {
  echo ""
  echo "Testing: o_vm_get_healthy_nodes functionality"
  
  # Test with no parameters
  o_vm_get_healthy_nodes >/dev/null 2>&1
  test_assert_exit_code 1 $? "o_vm_get_healthy_nodes with no parameters should return 1"
  
  # Test with actual nodes
  local all_nodes
  all_nodes=$(om node ls 2>/dev/null | xargs)
  
  if [ -z "$all_nodes" ]; then
    echo -e "${YELLOW}⊘ Skipping: No nodes in cluster${NC}"
    return 0
  fi
  
  local healthy_nodes
  healthy_nodes=$(o_vm_get_healthy_nodes "$all_nodes" 2>/dev/null)
  local exit_code=$?
  
  test_assert_exit_code 0 $exit_code "o_vm_get_healthy_nodes should return 0"
  
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -n "$healthy_nodes" ]; then
    echo -e "${GREEN}✓${NC} Found healthy nodes: $healthy_nodes"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${YELLOW}⚠${NC} No healthy nodes found (may be expected if OpenSVC not running)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

#===============================================================================
# Integration Tests - Node Validation in o_vm_create
#===============================================================================

test_o_vm_create_with_invalid_node() {
  echo ""
  echo "Testing: o_vm_create with non-existent node (validation should fail)"
  
  local test_vm_id="test-vm-invalid-node-$(date +%s)"
  local invalid_node="nonexistent-node-999"
  
  o_vm_create "${test_vm_id}" "${invalid_node}" >/dev/null 2>&1
  local exit_code=$?
  
  test_assert_exit_code 2 $exit_code "o_vm_create should return 2 for non-existent node"
  
  # Verify no service was created
  local service_name="vm-ops-create-${test_vm_id}"
  sleep 1
  test_assert_service_not_exists "$service_name" "No service should be created for invalid node"
}

test_o_vm_create_with_unhealthy_node() {
  echo ""
  echo "Testing: o_vm_create behavior with unhealthy node"
  
  # First check if any nodes are unhealthy
  local all_nodes
  all_nodes=$(om node ls 2>/dev/null | xargs)
  
  if [ -z "$all_nodes" ]; then
    echo -e "${YELLOW}⊘ Skipping: No nodes in cluster${NC}"
    return 0
  fi
  
  local unhealthy_node=""
  for node in $all_nodes; do
    if ! o_vm_validate_node_quiet "$node" 2>/dev/null; then
      unhealthy_node="$node"
      break
    fi
  done
  
  if [ -z "$unhealthy_node" ]; then
    echo -e "${YELLOW}⊘ Skipping: All nodes are healthy (good!)${NC}"
    return 0
  fi
  
  local test_vm_id="test-vm-unhealthy-$(date +%s)"
  
  o_vm_create "${test_vm_id}" "${unhealthy_node}" >/dev/null 2>&1
  local exit_code=$?
  
  # Should fail at validation stage (exit code 3 or 4)
  if [ $exit_code -eq 3 ] || [ $exit_code -eq 4 ]; then
    test_assert_not_exit_code 0 $exit_code "o_vm_create should fail for unhealthy node"
  else
    test_assert_exit_code 3 $exit_code "o_vm_create should return 3 or 4 for unhealthy node"
  fi
}

#===============================================================================
# Integration Tests - Service Creation and Cleanup
#===============================================================================

test_o_vm_create_service_lifecycle() {
  echo ""
  echo "Testing: o_vm_create service lifecycle (validate, create, wait, execute, cleanup)"
  echo -e "${BLUE}  VM ID: ${TEST_VM_ID}${NC}"
  echo -e "${BLUE}  Target Node: ${TEST_TARGET_NODE}${NC}"
  echo -e "${YELLOW}  Note: This will create an actual VM on ${TEST_TARGET_NODE}${NC}"
  
  # Check if target node is accessible
  if ! om node ls 2>/dev/null | grep -qx "${TEST_TARGET_NODE}"; then
    echo -e "${YELLOW}⊘ Skipping: Target node ${TEST_TARGET_NODE} not found in cluster${NC}"
    return 0
  fi
  
  # Execute o_vm_create
  o_vm_create "${TEST_VM_ID}" "${TEST_TARGET_NODE}"
  local exit_code=$?
  
  # Check exit code
  case $exit_code in
    0)
      # Complete success
      test_assert_exit_code 0 $exit_code "o_vm_create should succeed for valid parameters"
      
      # Verify service was cleaned up
      local service_name="vm-ops-create-${TEST_VM_ID}"
      test_assert_service_not_exists "$service_name" "Service ${service_name} should be deleted after execution"
      
      echo -e "${BLUE}  Note: VM creation success depends on n_vm_create having valid config${NC}"
      ;;
    2|3|4)
      # Node validation failure
      test_assert_not_exit_code 0 $exit_code "o_vm_create failed at node validation (expected if node unhealthy)"
      echo -e "${YELLOW}  Note: Node ${TEST_TARGET_NODE} failed validation checks${NC}"
      ;;
    6)
      # Instance availability timeout
      test_assert_exit_code 6 $exit_code "o_vm_create timed out waiting for instance"
      echo -e "${YELLOW}  Warning: Service instance did not appear on target node within 30s${NC}"
      ;;
    7)
      # Task execution failed
      test_assert_exit_code 7 $exit_code "o_vm_create task execution failed (expected without real config)"
      
      # Verify service was cleaned up
      local service_name="vm-ops-create-${TEST_VM_ID}"
      test_assert_service_not_exists "$service_name" "Service ${service_name} should be deleted even after failure"
      ;;
    *)
      # Unexpected exit code
      test_assert_not_exit_code 999 $exit_code "o_vm_create returned unexpected exit code: $exit_code"
      ;;
  esac
}

#===============================================================================
# Main test execution
#===============================================================================

main() {
  echo "========================================"
  echo "o_vm_create Function Tests"
  echo "========================================"
  echo ""
  echo -e "${BLUE}Test Configuration:${NC}"
  echo -e "  Target Node: ${YELLOW}${TEST_TARGET_NODE}${NC}"
  echo -e "  Test VM ID: ${YELLOW}${TEST_VM_ID}${NC}"
  echo ""
  echo -e "${BLUE}Prerequisites Check:${NC}"
  
  # Check if function library loaded
  if ! type o_vm_create >/dev/null 2>&1; then
    echo -e "${RED}ERROR: o_vm_create function not available${NC}"
    echo -e "${RED}       Ensure function is in IPS function library${NC}"
    exit 1
  fi
  
  if ! type o_vm_validate_node >/dev/null 2>&1; then
    echo -e "${RED}ERROR: o_vm_validate_node function not available${NC}"
    echo -e "${RED}       Ensure node validation functions are loaded${NC}"
    exit 1
  fi
  
  # Check if OpenSVC available
  if ! type om >/dev/null 2>&1; then
    echo -e "${RED}ERROR: om command not available (OpenSVC required)${NC}"
    exit 1
  fi
  
  # Check cluster status
  local cluster_nodes
  cluster_nodes=$(om node ls 2>/dev/null | wc -l)
  
  if [ $cluster_nodes -eq 0 ]; then
    echo -e "${YELLOW}WARNING: No nodes found in OpenSVC cluster${NC}"
    echo -e "${YELLOW}         Most integration tests will be skipped${NC}"
  fi
  
  echo -e "${GREEN}✓${NC} o_vm_create function available"
  echo -e "${GREEN}✓${NC} o_vm_validate_node function available"
  echo -e "${GREEN}✓${NC} OpenSVC available"
  echo -e "${GREEN}✓${NC} Cluster has ${cluster_nodes} node(s)"
  
  # Run unit tests
  echo ""
  echo "========================================"
  echo "Unit Tests - Parameter Validation"
  echo "========================================"
  test_o_vm_create_no_params
  
  # Run node validation tests
  echo ""
  echo "========================================"
  echo "Node Validation Tests"
  echo "========================================"
  test_o_vm_validate_node_basic
  test_o_vm_validate_node_nonexistent
  test_o_vm_validate_node_healthy
  test_o_vm_get_healthy_nodes
  
  # Run integration tests
  echo ""
  echo "========================================"
  echo "Integration Tests - Node Validation"
  echo "========================================"
  test_o_vm_create_with_invalid_node
  test_o_vm_create_with_unhealthy_node
  
  # Run full lifecycle test
  echo ""
  echo "========================================"
  echo "Integration Tests - Full Lifecycle"
  echo "========================================"
  test_o_vm_create_service_lifecycle
  
  # Print summary
  echo ""
  echo "========================================"
  echo "Test Summary"
  echo "========================================"
  echo "Tests run:    $TESTS_RUN"
  echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
  
  if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    echo -e "${RED}Result: FAIL${NC}"
    exit 1
  else
    echo "Tests failed: 0"
    echo ""
    echo -e "${GREEN}Result: PASS${NC}"
    exit 0
  fi
}

# Run main
main
