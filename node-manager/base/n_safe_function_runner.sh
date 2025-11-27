#===============================================================================
# n_safe_function_runner
# ----------------------
# Safely execute a node function with automatic sourcing and timeout protection.
#
# Behaviour:
#   - Checks if function exists, attempts to source if not
#   - Priority 1: Try bootstrap (hps_load_node_functions)
#   - Priority 2: Try cache (/srv/hps/lib/hps-functions-cache.sh)
#   - Executes function with timeout protection (default: 15 seconds)
#   - Handles all errors gracefully (won't break shell)
#   - Safe for use in background jobs and subshells
#   - Logs execution via n_remote_log (if available)
#
# Arguments:
#   --timeout N    : Override default timeout in seconds (optional)
#   function_name  : Name of function to execute (required)
#   args...        : Arguments to pass to function (optional)
#
# Returns:
#   0 on success
#   1 if function not found after sourcing attempts
#   2 if function execution failed
#   124 if timeout occurred
#
# Example usage:
#   n_safe_function_runner n_rescue_show_help
#   n_safe_function_runner n_rescue_display_config
#   n_safe_function_runner --timeout 30 n_some_function arg1 arg2
#
#===============================================================================
n_safe_function_runner() {
  local timeout=15
  local function_name=""
  local log_available=0
  
  # Check if logging is available
  if type n_remote_log >/dev/null 2>&1; then
    log_available=1
  fi
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        if [[ -n "$2" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
          timeout="$2"
          shift 2
        else
          echo "ERROR: --timeout requires a numeric value" >&2
          return 1
        fi
        ;;
      *)
        if [[ -z "$function_name" ]]; then
          function_name="$1"
          shift
          break
        else
          shift
        fi
        ;;
    esac
  done
  
  # Remaining args are function arguments
  local function_args="$@"
  
  # Validate function name provided
  if [[ -z "$function_name" ]]; then
    echo "ERROR: No function name provided" >&2
    echo "Usage: n_safe_function_runner [--timeout N] <function_name> [args...]" >&2
    return 1
  fi
  
  [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: executing $function_name (timeout: ${timeout}s)" || true
  
  # Step 1: Check if function exists
  if ! type "$function_name" >/dev/null 2>&1; then
    [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: $function_name not found, attempting to source" || true
    
    # Step 2: Try to source functions
    # Try bootstrap first
    if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
      [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: trying bootstrap" || true
      . /usr/local/lib/hps-bootstrap-lib.sh 2>/dev/null || true
      if type hps_load_node_functions >/dev/null 2>&1; then
        hps_load_node_functions 2>/dev/null || true
      fi
    fi
    
    # If still not available, try cache
    if ! type "$function_name" >/dev/null 2>&1; then
      if [ -f /srv/hps/lib/hps-functions-cache.sh ]; then
        [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: trying cache" || true
        . /srv/hps/lib/hps-functions-cache.sh 2>/dev/null || true
      fi
    fi
    
    # Step 3: Final check
    if ! type "$function_name" >/dev/null 2>&1; then
      # Function still not available, give up
      [[ $log_available -eq 1 ]] && n_remote_log "[ERROR] Safe runner: $function_name not found after sourcing attempts" || true
      echo "ERROR: Function '$function_name' not found" >&2
      return 1
    fi
    
    [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: $function_name loaded successfully" || true
  fi
  
  # Step 4: Execute with timeout protection
  [[ $log_available -eq 1 ]] && n_remote_log "[DEBUG] Safe runner: executing $function_name" || true
  
  # Use bash timeout mechanism (trap + background sleep)
  (
    # Set up timeout handler
    trap 'exit 124' TERM
    
    # Start timeout watcher in background
    (
      sleep "$timeout"
      kill -TERM $$ 2>/dev/null
    ) &
    local timeout_pid=$!
    
    # Execute the function
    "$function_name" $function_args
    local func_rc=$?
    
    # Kill timeout watcher if function completed in time
    kill $timeout_pid 2>/dev/null
    wait $timeout_pid 2>/dev/null
    
    exit $func_rc
  )
  
  local result=$?
  
  # Log result
  if [[ $log_available -eq 1 ]]; then
    case $result in
      0)
        n_remote_log "[DEBUG] Safe runner: $function_name completed successfully" || true
        ;;
      124)
        n_remote_log "[WARNING] Safe runner: $function_name timed out after ${timeout}s" || true
        echo "WARNING: Function '$function_name' timed out after ${timeout}s" >&2
        ;;
      *)
        n_remote_log "[WARNING] Safe runner: $function_name failed with exit code $result" || true
        echo "WARNING: Function '$function_name' failed with exit code $result" >&2
        ;;
    esac
  fi
  
  return $result
}
