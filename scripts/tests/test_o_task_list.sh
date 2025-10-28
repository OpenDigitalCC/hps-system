#!/bin/bash

#===============================================================================
# test_o_task_list
# ----------------
# Test the o_task_list function.
#
# Usage:
#   ./test_o_task_list.sh
#
#===============================================================================

# Source the functions
source /srv/hps-system/lib/functions.sh

echo "=== Testing o_task_list function ==="
echo ""

# Setup: Create test services if they don't exist
echo "Setup: Creating test services..."
o_task_create "testlist1" "task1" 'echo "Task 1"' "all" >/dev/null 2>&1
o_task_create "testlist1" "task2" 'echo "Task 2"' "all" >/dev/null 2>&1
o_task_create "testlist2" "health" 'ping -c 1 8.8.8.8' "tch-001 tch-002" >/dev/null 2>&1

sleep 2
echo "Setup complete"
echo ""

# Test 1: List all services
echo "Test 1: List all services"
o_task_list
echo ""

# Test 2: List specific service
echo "Test 2: List specific service 'testlist1'"
o_task_list testlist1
echo ""

# Test 3: List non-existent service
echo "Test 3: List non-existent service (should show error)"
o_task_list nonexistent
echo "Return code: $?"
echo ""

# Cleanup
echo "=== Cleanup ==="
echo "Run: om testlist1 delete && om testlist2 delete"
echo ""

echo "=== Tests complete ==="
