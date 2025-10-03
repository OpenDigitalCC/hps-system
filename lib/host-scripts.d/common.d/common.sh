# /srv/hps/functions.d/common.sh



## NODE Functions



#===============================================================================
# Function Queue Framework (File-based)
# -------------------------------------
# Queue functions for controlled execution with logging and error handling.
# Uses a file to persist queue across scripts.
#
# Usage:
#   n_queue_add "function_name" "arg1" "arg2" ...
#   n_queue_run
#   n_queue_clear
#===============================================================================

# Queue file location
N_QUEUE_FILE="${N_QUEUE_FILE:-/tmp/hps_function_queue}"

#===============================================================================
# n_queue_add
# -----------
# Add a function call to the execution queue.
#
# Usage:
#   n_queue_add "function_name" "arg1" "arg2" ...
#
# Arguments:
#   All arguments form the complete function call
#
# Returns:
#   0 on success
#===============================================================================
n_queue_add() {
    local func_call="$*"
    
    if [[ -z "${func_call}" ]]; then
        echo "Error: No function specified" >&2
        n_remote_log "Error: No function specified"
        return 1
    fi
    
    # Append to queue file
    echo "${func_call}" >> "${N_QUEUE_FILE}" || {
        echo "Error: Failed to add to queue" >&2
        n_remote_log "Error: Failed to add to queue"
        return 1
    }
    n_remote_log "${func_call}"
    echo "Queued: ${func_call}"
    return 0
}

#===============================================================================
# n_queue_run
# -----------
# Execute all queued functions in order with logging.
#
# Usage:
#   n_queue_run
#
# Behaviour:
#   - Executes each queued function in order
#   - Logs start, success, and failure of each function
#   - Continues on failure unless critical
#   - Clears queue after execution
#
# Returns:
#   0 if all functions succeeded
#   Number of failed functions otherwise
#===============================================================================
n_queue_run() {
    local total=0
    local current=0
    local failed=0
    local func_call
    local func_name
    local start_time
    local end_time
    local duration
    
    # Check if queue file exists
    if [[ ! -f "${N_QUEUE_FILE}" ]]; then
        echo "No functions queued for execution"
        return 0
    fi
    
    # Count total functions
    total=$(wc -l < "${N_QUEUE_FILE}")
    
    if [[ ${total} -eq 0 ]]; then
        echo "No functions queued for execution"
        return 0
    fi
    
    n_remote_log "Starting execution of ${total} queued functions"
    echo "Executing ${total} queued functions..."
    echo "========================================"
    
    # Read and execute each line
    while IFS= read -r func_call; do
        # Skip empty lines
        [[ -z "${func_call}" ]] && continue
        
        ((current++))
        
        # Extract function name (first word)
        func_name="${func_call%% *}"
        
        echo ""
        echo "[${current}/${total}] Executing: ${func_call}"
        n_remote_log "EXEC [${current}/${total}]: ${func_call}"
        
        # Record start time
        start_time=$(date +%s)
        
        # Execute the function
        eval "${func_call}"
        local result=$?
        
        # Record end time and calculate duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        if [[ ${result} -eq 0 ]]; then
            echo "✓ Success (${duration}s)"
            n_remote_log "SUCCESS [${current}/${total}]: ${func_name} completed in ${duration}s"
        else
            ((failed++))
            echo "✗ Failed with code ${result} (${duration}s)"
            n_remote_log "FAILED [${current}/${total}]: ${func_name} failed with code ${result} after ${duration}s"
        fi
    done < "${N_QUEUE_FILE}"
    
    echo ""
    echo "========================================"
    echo "Execution complete: $((total - failed)) succeeded, ${failed} failed"
    n_remote_log "Queue execution complete: $((total - failed)) succeeded, ${failed} failed"
    
    # Clear the queue
    n_queue_clear
    
    return ${failed}
}

#===============================================================================
# n_queue_clear
# -------------
# Clear the function queue.
#
# Usage:
#   n_queue_clear
#
# Returns:
#   0 on success
#===============================================================================
n_queue_clear() {
    rm -f "${N_QUEUE_FILE}"
    echo "Function queue cleared"
    return 0
}

#===============================================================================
# n_queue_list
# ------------
# List all queued functions.
#
# Usage:
#   n_queue_list
#
# Returns:
#   0 on success
#===============================================================================
n_queue_list() {
    local total=0
    local i=0
    
    if [[ ! -f "${N_QUEUE_FILE}" ]]; then
        echo "No functions queued"
        return 0
    fi
    
    total=$(wc -l < "${N_QUEUE_FILE}")
    
    if [[ ${total} -eq 0 ]]; then
        echo "No functions queued"
        return 0
    fi
    
    echo "Queued functions (${total}):"
    echo "========================"
    
    while IFS= read -r func_call; do
        [[ -z "${func_call}" ]] && continue
        ((i++))
        echo "${i}. ${func_call}"
    done < "${N_QUEUE_FILE}"
    
    return 0
}

refresh_node_functions() {
  local provisioning_node
  local functions_url
  
  # Get the provisioning node IP
  provisioning_node=$(n_get_provisioning_node)
  
  if [ -z "$provisioning_node" ]; then
    echo "ERROR: Could not determine provisioning node" >&2
    return 1
  fi
  
  # Construct the URL
  functions_url="http://${provisioning_node}/cgi-bin/boot_manager.sh?cmd=node_get_functions&distro=x86_64-linux-rocky-10.0"
  
  # Ensure directory exists
  mkdir -p /srv/hps/lib
  
  # Download the functions
  if curl -fsSL "$functions_url" > /srv/hps/lib/node_functions.sh; then
    echo "Successfully refreshed node functions from ${provisioning_node}"
    
    # Reload functions in current shell if being sourced
    if [ -n "$BASH_VERSION" ]; then
      . /srv/hps/lib/node_functions.sh
    fi
    
    return 0
  else
    echo "ERROR: Failed to download functions from ${provisioning_node}" >&2
    return 1
  fi
}



