#!/bin/bash

#===============================================================================
# o_node_test_logger
# ------------------
# Test function that logs information about where it's running.
# Designed to verify task execution on nodes.
#
# Behaviour:
#   - Logs hostname, date, and any parameters passed
#   - Uses o_log for agnostic logging
#   - Includes process ID to track execution
#
# Returns:
#   0 on success
#
# Example usage:
#   o_node_test_logger
#   o_node_test_logger "custom message"
#
#===============================================================================
o_node_test_logger() {
  local custom_msg="${1:-No custom message}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Log using the agnostic logging function
  o_log info "NODE_TASK_TEST: Running on host: $(hostname)"
  o_log info "NODE_TASK_TEST: Timestamp: ${timestamp}"
  o_log info "NODE_TASK_TEST: Process ID: $$"
  o_log info "NODE_TASK_TEST: Custom message: ${custom_msg}"
  
  # Also use logger directly to ensure visibility
  logger -t "node_task_test" "Executed on $(hostname) at ${timestamp}, PID: $$, MSG: ${custom_msg}"
  
  return 0
}

#===============================================================================
# Test script to demonstrate IPS creating and running node tasks
#===============================================================================

echo "=== Node Task Execution Test ==="
echo

# Step 1: Create the task on IPS
echo "1. Creating node task from IPS..."
if o_task_function_create node monitoring o_node_test_logger; then
  echo "   ✓ Task created successfully"
else
  echo "   ✗ Failed to create task"
  exit 1
fi

# Step 2: Verify task configuration
echo
echo "2. Verifying task configuration..."
o_task_list node monitoring

# Step 3: Run the task on nodes
echo
echo "3. Running task on all nodes..."
if o_task_run_on_nodes monitoring o_node_test_logger; then
  echo "   ✓ Task execution command sent"
else
  echo "   ✗ Failed to run task on nodes"
fi

# Step 4: Create and run a task with parameters
echo
echo "4. Creating task with parameters..."
if o_task_function_create_with_params node monitoring o_node_test_logger "Test from IPS at $(date)"; then
  echo "   ✓ Parameterized task created"
fi

echo
echo "5. Running parameterized task on nodes..."
o_task_run_on_nodes monitoring o_node_test_logger

echo
echo "=== Test Complete ==="
echo "Check logs on nodes for NODE_TASK_TEST entries"
echo "On nodes, check: journalctl -t node_task_test -n 10"
echo "Or HPS logs for entries with NODE_TASK_TEST"
