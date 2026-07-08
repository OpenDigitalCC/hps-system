#!/bin/bash
#
# run-bats.sh - run the HPS bats test suite.
#
# Runs every *.bats file under scripts/tests/. Pass --integration to also run
# the integration tests under scripts/tests/integration/ (these start real
# services and need a rootless user+mount namespace; see each script's header).
#
# Usage:
#   scripts/tests/run-bats.sh [--integration]

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_integration=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --integration) run_integration=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-bats: unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! command -v bats >/dev/null 2>&1; then
  echo "run-bats: bats not found (install bats-core / the 'bats' package)" >&2
  exit 1
fi

shopt -s nullglob
bats_files=("$TESTS_DIR"/*.bats)
shopt -u nullglob

if [[ ${#bats_files[@]} -eq 0 ]]; then
  echo "run-bats: no .bats files found in $TESTS_DIR" >&2
  exit 1
fi

echo "Running ${#bats_files[@]} bats file(s)"
bats "${bats_files[@]}"

if [[ $run_integration -eq 1 ]]; then
  echo
  echo "Running integration tests"
  for t in "$TESTS_DIR"/integration/*.sh; do
    [[ -e "$t" ]] || continue
    echo "--- $(basename "$t") ---"
    bash "$t"
  done
fi
