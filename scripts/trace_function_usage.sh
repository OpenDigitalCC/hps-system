#!/bin/bash
#===============================================================================
# trace_function_usage.sh - Find all functions that call a target function
# Usage: trace_function_usage.sh <function_name>
#===============================================================================

TARGET_FUNC="${1}"
FUNC_DIR="${2:-/srv/hps-system/lib}"

if [[ -z "$TARGET_FUNC" ]]; then
  echo "Usage: $0 <function_name> [search_directory]"
  echo "Example: $0 get_active_cluster_dir"
  echo "Example: $0 cluster_config /srv/hps-system"
  exit 1
fi

# Find all direct callers
echo "=== Direct callers of ${TARGET_FUNC} ==="
echo ""

grep -rn "\b${TARGET_FUNC}\b" "$FUNC_DIR" --include="*.sh" | \
grep -v "^[^:]*:[^:]*:\s*${TARGET_FUNC}\s*(" | \
grep -v "^[^:]*:[^:]*:#" | \
while IFS=: read -r file line content; do
  # Extract the function name that contains this call
  containing_func=$(awk -v line="$line" '
    /^[[:alnum:]_]+\s*\(\)/ { func=$1; gsub(/[[:space:]()]+/, "", func) }
    NR == line { if (func) print func; exit }
  ' "$file")
  
  if [[ -n "$containing_func" ]]; then
    echo "File: $file"
    echo "Line: $line"
    echo "Function: $containing_func()"
    echo "Call: $(echo "$content" | sed 's/^[[:space:]]*//')"
    echo "---"
  else
    # If we couldn't find containing function, show the context anyway
    echo "File: $file"
    echo "Line: $line"
    echo "Function: (at top level or not found)"
    echo "Call: $(echo "$content" | sed 's/^[[:space:]]*//')"
    echo "---"
  fi
done

echo ""
echo "=== Summary ==="
echo "Total occurrences: $(grep -rn "\b${TARGET_FUNC}\b" "$FUNC_DIR" --include="*.sh" | grep -v "^[^:]*:[^:]*:\s*${TARGET_FUNC}\s*(" | wc -l)"
