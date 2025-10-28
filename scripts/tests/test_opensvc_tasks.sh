#!/bin/bash

#===============================================================================
# test_o_task_create
# ------------------
# Test the o_task_create function.
#
# Usage:
#   ./test_o_task_create.sh
#
#===============================================================================

source /srv/hps-system/lib/functions.sh 

echo "=== Testing o_task_create function ==="
echo ""

# Test 1: Create a new service with one task
echo "Test 1: Create new service 'testservice' with task 'test1'"
o_task_create "testservice" "test1" 'logger -t TASK_TEST "Test1 executed on $(hostname -s)"' "all"
echo "Return code: $?"
echo ""

# Wait for deployment
sleep 3

# Verify service was created
echo "Verifying service configuration:"
om testservice print config
echo ""

# Test 2: Add a second task to existing service
echo "Test 2: Add second task 'test2' to testservice"
o_task_create "testservice" "test2" 'logger -t TASK_TEST "Test2 executed on $(hostname -s)"' "all"
echo "Return code: $?"
echo ""

sleep 2

# Verify both tasks exist
echo "Verifying both tasks exist:"
om testservice print config
echo ""

# Test 3: Update existing task
echo "Test 3: Update task 'test1' with new command"
o_task_create "testservice" "test1" 'logger -t TASK_TEST "Test1 UPDATED on $(hostname -s)"' "all"
echo "Return code: $?"
echo ""

sleep 2

# Verify update
echo "Verifying task was updated:"
om testservice print config
echo ""

# Test 4: Run the tasks to verify they work
echo "Test 4: Running tasks to verify execution"
echo "Running test1..."
om testservice run --rid task#test1 --node ips
sleep 2

echo "Running test2..."
om testservice run --rid task#test2 --node ips
sleep 2

echo ""
echo "=== Tests complete ==="
echo "Check logs with: grep TASK_TEST /srv/hps-system/log/rsyslog/*/$(date +%Y-%m-%d)*"
echo ""
echo "Cleanup: om testservice delete"
