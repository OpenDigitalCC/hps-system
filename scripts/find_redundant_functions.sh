#!/bin/bash
#===============================================================================
# find_redundant_functions.sh
# ---------------------------
# Scan all .sh files recursively to find declared but unused bash functions.
#
# Usage:
#   find_redundant_functions.sh <directory>
#
# Output:
#   Lists unused functions grouped by file
#
# Returns:
#   0 on success
#   1 on invalid arguments
#   2 on directory access error
#===============================================================================

# Check arguments
if [ $# -eq 0 ]; then
  echo "Usage: $0 <directory> [directory2] [directory3] ..." >&2
  exit 1
fi

# Validate all directories
search_dirs=()
for dir in "$@"; do
  if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
    echo "Error: Directory '$dir' not found or not readable" >&2
    exit 2
  fi
  search_dirs+=("$dir")
done

# Find all .sh files in all directories
sh_files=()
for dir in "${search_dirs[@]}"; do
  while IFS= read -r -d '' file; do
    sh_files+=("$file")
  done < <(find "$dir" -type f -name "*.sh" -print0 2>/dev/null)
done

if [ ${#sh_files[@]} -eq 0 ]; then
  echo "No .sh files found in specified directories: ${search_dirs[*]}"
  exit 0
fi

# Track all declared functions and their files
declare -A function_files
declare -A function_usage

# Extract function declarations
for file in "${sh_files[@]}"; do
  # Find functions declared with standard syntax: function_name() {
  while IFS= read -r func_name; do
    function_files["$func_name"]="$file"
    function_usage["$func_name"]=0
  done < <(grep -E '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{' "$file" | \
           sed -E 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\).*/\1/')
done

# Search for function usage
for func_name in "${!function_files[@]}"; do
  # Count occurrences across all files
  count=0
  for file in "${sh_files[@]}"; do
    # Count references, excluding the declaration line
    file_count=$(grep -c "\b${func_name}\b" "$file" 2>/dev/null || echo 0)
    # Ensure we have a clean integer
    file_count=${file_count//[^0-9]/}
    file_count=${file_count:-0}
    
    # If this is the file where function is declared, subtract 1 for the declaration
    if [ "$file" = "${function_files[$func_name]}" ]; then
      ((file_count--))
    fi
    
    ((count += file_count))
  done
  
  function_usage["$func_name"]=$count
done

# Group unused functions by file
declare -A unused_by_file

for func_name in "${!function_usage[@]}"; do
  if [ "${function_usage[$func_name]}" -eq 0 ]; then
    file="${function_files[$func_name]}"
    if [ -z "${unused_by_file[$file]}" ]; then
      unused_by_file["$file"]="$func_name"
    else
      unused_by_file["$file"]="${unused_by_file[$file]} $func_name"
    fi
  fi
done

# Output results
if [ ${#unused_by_file[@]} -eq 0 ]; then
  echo "No redundant functions found."
else
  echo "Redundant functions found:"
  echo
  for file in "${!unused_by_file[@]}"; do
    echo "File: $file"
    for func in ${unused_by_file[$file]}; do
      echo "  - $func"
    done
    echo
  done
fi

exit 0
