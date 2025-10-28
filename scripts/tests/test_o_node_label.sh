#!/bin/bash
#===============================================================================
# test_o_node_label
# -----------------
# Test the node label management functions.
#
# Usage:
#   ./test_o_node_label.sh
#
#===============================================================================

# Source the functions
source /srv/hps-system/lib/functions.sh

echo "=== Testing Node Label Functions ==="
echo ""

# Cleanup: Remove any existing test labels
echo "Cleanup: Removing any existing test labels..."
o_node_label_remove "all" "test_role" >/dev/null 2>&1
o_node_label_remove "all" "test_az" >/dev/null 2>&1
o_node_label_remove "all" "test_env" >/dev/null 2>&1
sleep 2
echo "Cleanup complete"
echo ""

# Test 1: Add label to single node
echo "Test 1: Add label test_role=control to ips"
o_node_label_add "ips" "test_role" "control"
echo "Return code: $?"
sleep 1
echo ""

# Verify Test 1
echo "Verify: Check if ips has test_role label"
if o_node_label_exists "ips" "test_role"; then
  echo "✅ PASS: Label exists"
else
  echo "❌ FAIL: Label does not exist"
fi
echo ""

# Test 2: Add label to multiple nodes
echo "Test 2: Add label test_role=compute to tch-001 and tch-002"
o_node_label_add "tch-001 tch-002" "test_role" "compute"
echo "Return code: $?"
sleep 1
echo ""

# Verify Test 2
echo "Verify: Check if tch-001 has test_role=compute"
if o_node_label_exists "tch-001" "test_role" "compute"; then
  echo "✅ PASS: tch-001 has correct label"
else
  echo "❌ FAIL: tch-001 label incorrect"
fi
echo ""

# Test 3: Add different labels to different nodes
echo "Test 3: Add test_az labels to nodes"
o_node_label_add "tch-001" "test_az" "zone1"
o_node_label_add "tch-002" "test_az" "zone2"
echo "Return code: $?"
sleep 1
echo ""

# Test 4: List nodes with OR logic (single label)
echo "Test 4: List nodes with test_role=compute"
nodes=$(o_node_label_list "test_role=compute" "or" true)
echo "Found nodes: $nodes"
node_count=$(echo "$nodes" | grep -c "^" 2>/dev/null || echo 0)
if [ "$node_count" -eq 2 ]; then
  echo "✅ PASS: Found 2 nodes"
else
  echo "❌ FAIL: Expected 2 nodes, found $node_count"
fi
echo ""

# Test 5: List nodes with OR logic (multiple values)
echo "Test 5: List nodes with test_az=zone1 OR test_az=zone2"
nodes=$(o_node_label_list "test_az=zone1 test_az=zone2" "or" true)
echo "Found nodes: $nodes"
node_count=$(echo "$nodes" | grep -c "^" 2>/dev/null || echo 0)
if [ "$node_count" -eq 2 ]; then
  echo "✅ PASS: Found 2 nodes"
else
  echo "❌ FAIL: Expected 2 nodes, found $node_count"
fi
echo ""

# Test 6: List nodes with AND logic
echo "Test 6: List nodes with test_role=compute AND test_az=zone1"
nodes=$(o_node_label_list "test_role=compute test_az=zone1" "and" true)
echo "Found nodes: $nodes"
if echo "$nodes" | grep -q "tch-001" && ! echo "$nodes" | grep -q "tch-002"; then
  echo "✅ PASS: Found only tch-001"
else
  echo "❌ FAIL: Expected only tch-001"
fi
echo ""

# Test 7: Update existing label
echo "Test 7: Update test_role on ips from control to master"
o_node_label_add "ips" "test_role" "master"
echo "Return code: $?"
sleep 1

if o_node_label_exists "ips" "test_role" "master"; then
  echo "✅ PASS: Label updated successfully"
else
  echo "❌ FAIL: Label not updated"
fi
echo ""

# Test 8: Add label to all nodes
echo "Test 8: Add test_env=production to all nodes"
o_node_label_add "all" "test_env" "production"
echo "Return code: $?"
sleep 1

all_nodes=$(om node ls)
pass=true
for node in $all_nodes; do
  if ! o_node_label_exists "$node" "test_env" "production"; then
    echo "❌ FAIL: Node $node missing test_env label"
    pass=false
  fi
done
if [ "$pass" = true ]; then
  echo "✅ PASS: All nodes have test_env label"
fi
echo ""

# Test 9: Remove label from single node
echo "Test 9: Remove test_az from tch-001"
o_node_label_remove "tch-001" "test_az"
echo "Return code: $?"
sleep 1

if ! o_node_label_exists "tch-001" "test_az"; then
  echo "✅ PASS: Label removed successfully"
else
  echo "❌ FAIL: Label still exists"
fi
echo ""

# Test 10: Remove label from multiple nodes
echo "Test 10: Remove test_role from tch-001 and tch-002"
o_node_label_remove "tch-001 tch-002" "test_role"
echo "Return code: $?"
sleep 1

if ! o_node_label_exists "tch-001" "test_role" && ! o_node_label_exists "tch-002" "test_role"; then
  echo "✅ PASS: Labels removed from both nodes"
else
  echo "❌ FAIL: Labels still exist"
fi
echo ""

# Test 11: Remove label from all nodes
echo "Test 11: Remove test_env from all nodes"
o_node_label_remove "all" "test_env"
echo "Return code: $?"
sleep 1

all_nodes=$(om node ls)
pass=true
for node in $all_nodes; do
  if o_node_label_exists "$node" "test_env"; then
    echo "❌ FAIL: Node $node still has test_env label"
    pass=false
  fi
done
if [ "$pass" = true ]; then
  echo "✅ PASS: test_env removed from all nodes"
fi
echo ""

# Test 12: Check non-existent label
echo "Test 12: Check for non-existent label"
if ! o_node_label_exists "ips" "nonexistent_label"; then
  echo "✅ PASS: Correctly reports label doesn't exist"
else
  echo "❌ FAIL: Incorrectly reports label exists"
fi
echo ""

# Test 13: List with no matching nodes
echo "Test 13: List nodes with non-existent label"
nodes=$(o_node_label_list "nonexistent=value" "or" true)
if [ -z "$nodes" ]; then
  echo "✅ PASS: Correctly returns empty result"
else
  echo "❌ FAIL: Should return empty result"
fi
echo ""

# Final cleanup
echo "Final cleanup: Removing all test labels..."
o_node_label_remove "all" "test_role" >/dev/null 2>&1
o_node_label_remove "all" "test_az" >/dev/null 2>&1
o_node_label_remove "all" "test_env" >/dev/null 2>&1
sleep 2
echo "Cleanup complete"
echo ""

echo "=== Tests complete ==="
