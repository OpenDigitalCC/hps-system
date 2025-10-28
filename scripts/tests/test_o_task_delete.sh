#!/bin/bash
#===============================================================================
# test_o_task_delete
# ------------------
# Test the o_task_delete function.
#
# Usage:
#   ./test_o_task_delete.sh
#
#===============================================================================

# Source the functions
source /srv/hps-system/lib/functions.sh

echo "=== Testing o_task_delete function ==="
echo ""

# Setup: Create test service with multiple tasks
echo "Setup: Creating test service 'testdelete' with 3 tasks..."
o_task_create "testdelete" "task1" "echo Task1" "all" >/dev/null 2>&1
o_task_create "testdelete" "task2" "echo Task2" "all" >/dev/null 2>&1
o_task_create "testdelete" "task3" "echo Task3" "all" >/dev/null 2>&1
sleep 3
echo "Setup complete"
echo ""

# Show initial state
echo "Initial state:"
o_task_list testdelete
echo ""

# Test 1: Delete a single task
echo "Test 1: Delete task2 from testdelete"
o_task_delete "testdelete" "task2"
echo "Return code: $?"
sleep 2
echo ""

echo "After deleting task2:"
o_task_list testdelete
echo ""

# Test 2: Delete non-existent task
echo "Test 2: Delete non-existent task (should show warning)"
o_task_delete "testdelete" "nonexistent"
echo "Return code: $?"
echo ""

# Test 3: Delete another task (leaving one)
echo "Test 3: Delete task1, leaving only task3"
o_task_delete "testdelete" "task1"
echo "Return code: $?"
sleep 2
echo ""

echo "After deleting task1:"
o_task_list testdelete
echo ""

# Test 4: Delete entire service
echo "Test 4: Delete entire service testdelete"
o_task_delete "testdelete"
echo "Return code: $?"
sleep 3
echo ""

echo "Verify service is gone:"
o_task_list testdelete 2>&1
echo ""

# Test 5: Delete non-existent service (should show warning)
echo "Test 5: Delete non-existent service (should show warning)"
o_task_delete "nonexistent"
echo "Return code: $?"
echo ""

echo "=== Tests complete ==="
