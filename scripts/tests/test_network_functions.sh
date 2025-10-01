#!/bin/bash
# set -euo pipefail

# Optional override if running outside the container
HPS_CONFIG="${1:-}"

# Resolve script directory and source functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/functions.sh"

# Test script for network helper functions

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_count=0
pass_count=0
fail_count=0

# Test result function
assert_equals() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"
  
  test_count=$((test_count + 1))
  
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}[PASS]${NC} $test_name"
    pass_count=$((pass_count + 1))
  else
    echo -e "${RED}[FAIL]${NC} $test_name"
    echo "  Expected: '$expected'"
    echo "  Actual:   '$actual'"
    fail_count=$((fail_count + 1))
  fi
}

assert_return_code() {
  local expected_code="$1"
  local actual_code="$2"
  local test_name="$3"
  
  test_count=$((test_count + 1))
  
  if [[ "$expected_code" -eq "$actual_code" ]]; then
    echo -e "${GREEN}[PASS]${NC} $test_name"
    pass_count=$((pass_count + 1))
  else
    echo -e "${RED}[FAIL]${NC} $test_name"
    echo "  Expected return code: $expected_code"
    echo "  Actual return code:   $actual_code"
    fail_count=$((fail_count + 1))
  fi
}

echo -e "${YELLOW}=== Testing normalise_mac ===${NC}"

# Test various MAC formats
result=$(normalise_mac "52:54:00:12:34:56")
assert_equals "525400123456" "$result" "Colon-delimited MAC"

result=$(normalise_mac "52-54-00-12-34-56")
assert_equals "525400123456" "$result" "Dash-delimited MAC"

result=$(normalise_mac "5254.0012.3456")
assert_equals "525400123456" "$result" "Dot-delimited MAC (Cisco format)"

result=$(normalise_mac "52 54 00 12 34 56")
assert_equals "525400123456" "$result" "Space-delimited MAC"

result=$(normalise_mac "525400123456")
assert_equals "525400123456" "$result" "Already normalized MAC"

result=$(normalise_mac "52:54:00:AB:CD:EF")
assert_equals "525400abcdef" "$result" "Uppercase to lowercase"

# Test invalid MAC
normalise_mac "invalid" 2>/dev/null
assert_return_code 1 $? "Invalid MAC format returns error"

normalise_mac "52:54:00:12:34" 2>/dev/null
assert_return_code 1 $? "Too short MAC returns error"

normalise_mac "52:54:00:12:34:56:78" 2>/dev/null
assert_return_code 1 $? "Too long MAC returns error"

echo ""
echo -e "${YELLOW}=== Testing format_mac_colons ===${NC}"

result=$(format_mac_colons "525400123456")
assert_equals "52:54:00:12:34:56" "$result" "Format normalized MAC"

result=$(format_mac_colons "525400ABCDEF")
assert_equals "52:54:00:ab:cd:ef" "$result" "Format uppercase MAC"

# Test invalid input
format_mac_colons "invalid" 2>/dev/null
assert_return_code 1 $? "Invalid MAC returns error"

format_mac_colons "52540012345" 2>/dev/null
assert_return_code 1 $? "Too short MAC returns error"

echo ""
echo -e "${YELLOW}=== Testing strip_quotes ===${NC}"

result=$(strip_quotes '"test1.home"')
assert_equals "test1.home" "$result" "Strip double quotes"

result=$(strip_quotes "'test1.home'")
assert_equals "test1.home" "$result" "Strip single quotes"

result=$(strip_quotes 'test1.home')
assert_equals "test1.home" "$result" "No quotes to strip"

result=$(strip_quotes '""')
assert_equals "" "$result" "Empty quoted string"

result=$(strip_quotes '"quote in middle"test"')
assert_equals 'quote in middle"test' "$result" "Only strip surrounding quotes"

echo ""
echo -e "${YELLOW}=== Testing validate_ip_address ===${NC}"

validate_ip_address "10.99.1.1"
assert_return_code 0 $? "Valid IP: 10.99.1.1"

validate_ip_address "192.168.1.254"
assert_return_code 0 $? "Valid IP: 192.168.1.254"

validate_ip_address "0.0.0.0"
assert_return_code 0 $? "Valid IP: 0.0.0.0"

validate_ip_address "255.255.255.255"
assert_return_code 0 $? "Valid IP: 255.255.255.255"

validate_ip_address "192.168.1.256"
assert_return_code 1 $? "Invalid IP: octet > 255"

validate_ip_address "192.168.1"
assert_return_code 1 $? "Invalid IP: too few octets"

validate_ip_address "192.168.1.1.1"
assert_return_code 1 $? "Invalid IP: too many octets"

validate_ip_address "192.168.-1.1"
assert_return_code 1 $? "Invalid IP: negative octet"

validate_ip_address "invalid"
assert_return_code 1 $? "Invalid IP: not numeric"

validate_ip_address ""
assert_return_code 1 $? "Invalid IP: empty string"

echo ""
echo -e "${YELLOW}=== Testing validate_hostname ===${NC}"

validate_hostname "TCH-001"
assert_return_code 0 $? "Valid hostname: TCH-001"

validate_hostname "ips"
assert_return_code 0 $? "Valid hostname: ips"

validate_hostname "host.domain.com"
assert_return_code 0 $? "Valid hostname: FQDN"

validate_hostname "test1"
assert_return_code 0 $? "Valid hostname: simple name"

validate_hostname "host123"
assert_return_code 0 $? "Valid hostname: alphanumeric"

validate_hostname "-invalid"
assert_return_code 1 $? "Invalid hostname: starts with hyphen"

validate_hostname "invalid-"
assert_return_code 1 $? "Invalid hostname: ends with hyphen"

validate_hostname "host_name"
assert_return_code 1 $? "Invalid hostname: contains underscore"

validate_hostname ""
assert_return_code 1 $? "Invalid hostname: empty string"

validate_hostname "host..domain"
assert_return_code 1 $? "Invalid hostname: empty label"

# Create a 64-character label (too long)
long_label=$(printf 'a%.0s' {1..64})
validate_hostname "$long_label"
assert_return_code 1 $? "Invalid hostname: label > 63 chars"

echo ""
echo -e "${YELLOW}=== Test Summary ===${NC}"
echo "Total tests: $test_count"
echo -e "${GREEN}Passed: $pass_count${NC}"
if [[ $fail_count -gt 0 ]]; then
  echo -e "${RED}Failed: $fail_count${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
