
# NOTE:This file is not verified - be careful to not break anything here


############### Core functions to support other functions

__guard_source() {
    local src="${BASH_SOURCE[1]}"
    local _guard_var="_GUARD_$(basename "$src" | sed 's/[^a-zA-Z0-9_]/_/g')"
    [[ -n "${!_guard_var:-}" ]] && return 1
    declare "$_guard_var=1"
    return 0
}


#===============================================================================
# hps_check_bash_syntax
# ---------------------
# Check bash code for syntax errors with context.
#
# Usage:
#   hps_check_bash_syntax <file_or_stdin> [label]
#
# Parameters:
#   $1 - File path or '-' for stdin
#   $2 - Optional label for the code being checked
#
# Returns:
#   0 if syntax is valid
#   1 if errors found
#===============================================================================
hps_check_bash_syntax() {
  local input="${1:--}"
  local label="${2:-bash code}"
  local tempfile
  
  echo "[SYNTAX] Checking $label..." >&2
  
  # Handle input
  if [[ "$input" == "-" ]]; then
    tempfile="/tmp/bash-syntax-check-$$"
    cat > "$tempfile"
  else
    tempfile="$input"
  fi
  
  # Run syntax check and capture output
  local syntax_errors
  if syntax_errors=$(bash -n "$tempfile" 2>&1); then
    echo "[SYNTAX] ✓ Syntax check passed for $label" >&2
    [[ "$input" == "-" ]] && rm -f "$tempfile"
    return 0
  else
    echo "[SYNTAX] ✗ Syntax errors found in $label:" >&2
    
    # Load file into array for context
    local -a lines
    mapfile -t lines < "$tempfile"
    
    # Parse each error
    while IFS= read -r error; do
      # Extract line number from error message
      if [[ "$error" =~ line[[:space:]]+([0-9]+): ]]; then
        local error_line="${BASH_REMATCH[1]}"
        local error_msg="${error#*: line $error_line: }"
        
        # Find which function contains this line
        local func_name="(not in function)"
        local current_func=""
        local line_no=0
        local func_start_line=0
        
        # First pass: find the function
        for line_no in "${!lines[@]}"; do
          local line="${lines[$line_no]}"
          
          # Check if we're at a function definition
          if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\) ]]; then
            current_func="${BASH_REMATCH[1]}"
            func_start_line=$line_no
          fi
          
          # If we've reached the error line, we know which function
          if [[ $((line_no + 1)) -eq $error_line ]]; then
            func_name="${current_func:-"(top level)"}"
            break
          fi
        done
        
        echo "" >&2
        echo "  Error: $error_msg" >&2
        echo "  Function: $func_name" >&2
        [[ "$current_func" ]] && echo "  Function starts at line: $((func_start_line + 1))" >&2
        echo "  Error at line $error_line" >&2
        echo "" >&2
        echo "  Context:" >&2
        
        # Show context (5 lines before and after)
        local start=$((error_line - 6))
        local end=$((error_line + 4))
        [[ $start -lt 0 ]] && start=0
        [[ $end -ge ${#lines[@]} ]] && end=$((${#lines[@]} - 1))
        
        for ((i=start; i<=end; i++)); do
          local line_num=$((i + 1))
          local prefix="    "
          if [[ $line_num -eq $error_line ]]; then
            prefix=">>> "
            echo "${prefix}${line_num}: ${lines[$i]}" >&2
          else
            echo "${prefix}${line_num}: ${lines[$i]}" >&2
          fi
        done
        echo "" >&2
        
      else
        # Couldn't parse line number, show raw error
        echo "  $error" >&2
      fi
    done <<< "$syntax_errors"
    
    # Add helpful hints
    echo "[HINT] Common causes for ')' syntax errors:" >&2
    echo "  - Missing opening '(' earlier in the function" >&2
    echo "  - Unclosed quotes or command substitution before this line" >&2
    echo "  - Missing 'then' in if statement or 'do' in loop" >&2
    echo "  - Extra closing ')' from copy/paste error" >&2
    
    [[ "$input" == "-" ]] && rm -f "$tempfile"
    return 1
  fi
}

#===============================================================================
# hps_find_syntax_pattern
# ------------------------
# Search for common syntax error patterns near an error line.
#
# Usage:
#   hps_find_syntax_pattern <file> <error_line>
#
# Parameters:
#   $1 - File to analyze
#   $2 - Line number with error
#===============================================================================
hps_find_syntax_pattern() {
  local file="$1"
  local error_line="$2"
  
  echo "[PATTERN] Checking for common issues near line $error_line:" >&2
  
  # Check for unmatched quotes before error line
  local quote_check=$(sed -n "1,${error_line}p" "$file" | grep -n "['\"]" | tail -5)
  if [[ -n "$quote_check" ]]; then
    echo "  Recent quotes (check for unclosed):" >&2
    echo "$quote_check" | sed 's/^/    /' >&2
  fi
  
  # Check for unmatched parentheses
  local open_parens=$(sed -n "1,${error_line}p" "$file" | tr -cd '(' | wc -c)
  local close_parens=$(sed -n "1,${error_line}p" "$file" | tr -cd ')' | wc -c)
  if [[ $open_parens -ne $close_parens ]]; then
    echo "  Parentheses mismatch: $open_parens '(' vs $close_parens ')'" >&2
    echo "  Missing $(($open_parens - $close_parens)) closing parentheses" >&2
  fi
  
  # Look for if/then/fi structure issues
  local if_count=$(sed -n "1,${error_line}p" "$file" | grep -c "^[[:space:]]*if[[:space:]]")
  local then_count=$(sed -n "1,${error_line}p" "$file" | grep -c "then")
  local fi_count=$(sed -n "1,${error_line}p" "$file" | grep -c "^[[:space:]]*fi")
  
  if [[ $if_count -ne $then_count ]]; then
    echo "  Possible missing 'then': $if_count 'if' vs $then_count 'then'" >&2
  fi
}


#===============================================================================
# hps_debug_function_load
# -------------------
# Debug why a function file or eval fails to load.
#
# Usage:
#   hps_debug_function_load <file_or_code> [label]
#   hps_debug_function_load /path/to/functions.sh
#   echo "$functions" | hps_debug_function_load - "node functions"
#
# Parameters:
#   $1 - File path or '-' for stdin
#   $2 - Optional label
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
hps_debug_function_load() {
  local input="${1:--}"
  local label="${2:-function file}"
  local tempfile
  
  echo "[DEBUG] Analyzing $label..." >&2
  
  # Handle input
  if [[ "$input" == "-" ]]; then
    tempfile="/tmp/debug-functions-$$"
    cat > "$tempfile"
  else
    tempfile="$input"
  fi
  
  # First, basic syntax check
  if ! hps_check_bash_syntax "$tempfile" "$label"; then
    echo "[DEBUG] Fix syntax errors before proceeding" >&2
    [[ "$input" == "-" ]] && rm -f "$tempfile"
    return 1
  fi
  
  # List all functions found
  echo "[DEBUG] Functions found in $label:" >&2
  grep -E "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)" "$tempfile" | \
    sed 's/().*//' | sed 's/^[[:space:]]*/  - /' >&2
  
  # Try to load function by function
  echo "[DEBUG] Testing individual function loads..." >&2
  local all_passed=true
  local current_func=""
  local func_body=""
  local in_function=false
  local brace_count=0
  
  while IFS= read -r line; do
    # Detect function start
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\) ]] && [[ "$in_function" == false ]]; then
      in_function=true
      current_func="${BASH_REMATCH[1]}"
      func_body="$line"$'\n'
      brace_count=0
      # Count braces on the same line
      [[ "$line" =~ \{ ]] && ((brace_count++))
      [[ "$line" =~ \} ]] && ((brace_count--))
      continue
    fi
    
    # Accumulate function body
    if [[ "$in_function" == true ]]; then
      func_body+="$line"$'\n'
      
      # Count braces
      local temp="${line//[^\{]/}"
      ((brace_count+=${#temp}))
      temp="${line//[^\}]/}"
      ((brace_count-=${#temp}))
      
      # Check if function is complete
      if [[ $brace_count -eq 0 ]] && [[ "$line" =~ \} ]]; then
        echo -n "  Testing $current_func... " >&2
        if (eval "$func_body" 2>&1) >/dev/null; then
          echo "✓ OK" >&2
        else
          echo "✗ FAILED" >&2
          echo "    Error: $(eval "$func_body" 2>&1)" >&2
          all_passed=false
        fi
        in_function=false
        func_body=""
      fi
    fi
  done < "$tempfile"
  
  # Try full load
  echo "[DEBUG] Testing full file load..." >&2
  if (source "$tempfile" 2>&1) >/dev/null; then
    echo "[DEBUG] ✓ Full load successful" >&2
  else
    echo "[DEBUG] ✗ Full load failed:" >&2
    (source "$tempfile" 2>&1) | sed 's/^/    /' >&2
    all_passed=false
  fi
  
  [[ "$input" == "-" ]] && rm -f "$tempfile"
  [[ "$all_passed" == true ]] && return 0 || return 1
}

#===============================================================================
# hps_safe_eval
# ---------
# Safely evaluate code with automatic debugging on failure.
#
# Usage:
#   hps_safe_eval "$code" "description"
#
# Parameters:
#   $1 - Code to evaluate
#   $2 - Optional description
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
hps_safe_eval() {
  local code="$1"
  local desc="${2:-code}"
  
  if eval "$code" 2>/dev/null; then
    return 0
  else
    echo "[EVAL] Failed to evaluate $desc" >&2
    echo "[EVAL] Running diagnostics..." >&2
    echo "$code" | hps_debug_function_load - "$desc"
    return 1
  fi
}

#===============================================================================
# hps_source_with_debug
# ---------------------
# Source a file with automatic debugging on failure.
#
# Usage:
#   hps_source_with_debug <file> [continue_on_error]
#
# Parameters:
#   $1 - File to source
#   $2 - If "continue", don't exit on error (default: exit)
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
hps_source_with_debug() {
  local file="$1"
  local continue_on_error="${2:-}"
  
  if source "$file" 2>/dev/null; then
    return 0
  else
    echo "[ERROR] Failed to source: $file" >&2
    
    # Use debug function if available
    if declare -f hps_debug_function_load >/dev/null 2>&1; then
      hps_debug_function_load "$file"
    elif declare -f hps_check_bash_syntax >/dev/null 2>&1; then
      hps_check_bash_syntax "$file"
    else
      # Basic fallback
      echo "[ERROR] Syntax check:" >&2
      bash -n "$file" 2>&1 | sed 's/^/  /' >&2
    fi
    
    if [[ "$continue_on_error" != "continue" ]]; then
      return 1
    fi
  fi
}

__guard_source || return

#:name: hps_log
#:group: logging
#:synopsis: Log messages to syslog and file with context information.
#:usage: hps_log <level> <message>
#:description:
#  Logs messages with timestamp, level, function name, and origin context.
#  If the current host has a configured hostname, displays hostname instead of origin tag.
#  URL-decodes messages and detects client type (script/ipxe/cli).
#:parameters:
#  level   - Log level (info, warn, error, debug)
#  message - Message to log (will be URL-decoded)
#:returns:
#  0 always
hps_log() {
  local level="${1^^}"; shift
  local raw_msg="$*"
  local ident="${HPS_LOG_IDENT:-hps}"
  local logfile="${HPS_LOG_DIR}/hps-system.log"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  
  # URL decode function
  url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
  }
  
  # Get origin identifier - use hostname if configured, otherwise origin tag
  local origin_id
  local origin_tag
  origin_tag=$(hps_origin_tag)
  
  if host_config "$origin_tag" exists HOSTNAME 2>/dev/null; then
    origin_id=$(host_config "$origin_tag" get HOSTNAME 2>/dev/null)
    [[ -z "$origin_id" ]] && origin_id="$origin_tag"
  else
    origin_id="$origin_tag"
  fi
  
  # Decode the message
  local msg
  msg="[$origin_id] ($(detect_client_type)) $(url_decode "$raw_msg")"
  
  # Send to syslog
  logger -t "$ident" -p "user.${level,,}" "[${FUNCNAME[1]}] $msg"
  
  # Write to file if possible
  if [[ -w "$logfile" || ( ! -e "$logfile" && -w "$(dirname "$logfile")" ) ]]; then
    echo "[${ts}] [$ident] [$level] [${FUNCNAME[1]}] $msg" >> "$logfile"
  else
    logger -t "$ident" -p "user.err" "Failed to write to $logfile"
  fi
}



