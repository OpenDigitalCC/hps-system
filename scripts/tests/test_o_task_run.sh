#!/bin/bash
#===============================================================================
# test_o_task_run
# ---------------
# Test the o_task_run function.
#
# Usage:
#   ./test_o_task_run.sh
#
#===============================================================================

# Source the functions
source /srv/hps-system/lib/functions.sh

echo "=== Testing o_task_run function ==="
echo ""

# Setup: Create test service with tasks
echo "Setup: Creating test service 'taskruntest' with 2 tasks..."
o_task_create "taskruntest" "simple" "logger -t TASK_RUN_TEST Simple_task_on_\$(hostname)" "all" >/dev/null 2>&1
o_task_create "taskruntest" "shellcmd" "/bin/sh -c 'echo Test_from_\$(hostname) > /tmp/taskruntest.txt'" "all" >/dev/null 2>&1
sleep 3
echo "Setup complete"
echo ""

# Show initial state
echo "Initial state:"
o_task_list taskruntest
echo ""

# Test 1: Run task on all nodes
echo "Test 1: Run simple task on all nodes"
o_task_run "taskruntest" "simple"
echo "Return code: $?"
sleep 2
echo ""

# Test 2: Run task on specific node
echo "Test 2: Run simple task on tch-001 only"
o_task_run "taskruntest" "simple" "tch-001"
echo "Return code: $?"
sleep 2
echo ""

# Test 3: Run task on ips node only
echo "Test 3: Run simple task on ips only"
o_task_run "taskruntest" "simple" "ips"
echo "Return code: $?"
sleep 2
echo ""

# Test 4: Run shell command task
echo "Test 4: Run shell command task (creates files)"
o_task_run "taskruntest" "shellcmd" "all"
echo "Return code: $?"
sleep 2
echo ""

# Test 5: Verify shell command created files (read them back)
echo "Test 5: Create and run verification task"
o_task_create "taskruntest" "verify" "/bin/sh -c 'cat /tmp/taskruntest.txt'" "all" >/dev/null 2>&1
sleep 2
o_task_run "taskruntest" "verify" "all"
echo "Return code: $?"
echo ""

# Test 6: Run on non-existent node (should fail)
echo "Test 6: Run on non-existent node (should fail with code 3)"
o_task_run "taskruntest" "simple" "nonexistent"
echo "Return code: $?"
echo ""

# Test 7: Run non-existent task (should fail)
echo "Test 7: Run non-existent task (should fail with code 2)"
o_task_run "taskruntest" "notask"
echo "Return code: $?"
echo ""

# Test 8: Run on non-existent service (should fail)
echo "Test 8: Run on non-existent service (should fail with code 1)"
o_task_run "noservice" "notask"
echo "Return code: $?"
echo ""

# Check logs from all nodes
echo "Checking logs from all nodes:"
echo "--- IPS logs ---"
grep TASK_RUN_TEST /srv/hps-system/log/rsyslog/ips/$(date +%Y-%m-%d).log 2>/dev/null | tail -5
echo ""
echo "--- TCH-001 logs ---"
grep TASK_RUN_TEST /srv/hps-system/log/rsyslog/10.99.1.6/$(date +%Y-%m-%d).log 2>/dev/null | tail -5
echo ""
echo "--- TCH-002 logs ---"
grep TASK_RUN_TEST /srv/hps-system/log/rsyslog/10.99.1.3/$(date +%Y-%m-%d).log 2>/dev/null | tail -5
echo ""

# Cleanup
echo "Cleanup: Deleting test service taskruntest"
o_task_delete "taskruntest"
echo "Return code: $?"
sleep 3
echo ""

# Verify cleanup
echo "Verify service is gone:"
o_task_list taskruntest 2>&1
echo ""

echo "=== Tests complete ==="
