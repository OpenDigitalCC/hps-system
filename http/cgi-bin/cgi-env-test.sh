#!/bin/bash
set -euo pipefail

# Source the necessary configurations
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


# Output as plain text
echo "Content-Type: text/plain"
echo

echo "===== CGI Environment Tester ====="
echo "Time: $(date)"
echo
echo "Active cluster: $(get_active_cluster_filename)"
echo

echo "== Basic Info =="
echo "UID: $(id -u) ($(id -un))"
echo "GID: $(id -g) ($(id -gn))"
echo "PWD: $(pwd)"
echo "HOME: $HOME"
echo "Shell: $SHELL"
echo "Script path: ${BASH_SOURCE[0]}"
echo "Script dirname: $(dirname "${BASH_SOURCE[0]}")"
echo

echo "== CGI Environment Variables =="
env | sort
echo

echo "== Interpreter Check =="
for shell in /bin/bash /bin/sh /usr/bin/env python3 perl awk; do
  if [[ -x "$shell" ]]; then
    echo "[✓] Found: $shell"
  else
    echo "[✗] Missing: $shell"
  fi
done
echo

echo "== Write Permission Test =="
TEST_FILE="/tmp/cgi-write-test-$$.txt"
if echo "test $(date)" > "$TEST_FILE"; then
  echo "[✓] Wrote to $TEST_FILE"
  rm -f "$TEST_FILE"
else
  echo "[✗] Cannot write to $TEST_FILE"
fi
echo

echo "== Directory Listing =="
ls -la "$(dirname "${BASH_SOURCE[0]}")"
