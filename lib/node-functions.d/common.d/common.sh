# /srv/hps/functions.d/common.sh

## NODE Functions for any O/S


#===============================================================================
# n_node_information
# ------------------
# Display concise node information that fits on a standard 80x24 terminal.
#
# Usage:
#   n_node_information
#
# Behaviour:
#   - Loads host configuration variables
#   - Shows essential node information
#   - Checks console login status
#   - Fits output to standard terminal size
#
# Returns:
#   0 on success
#   1 on failure to load configuration
#===============================================================================
n_node_information() {
  # Load host configuration
  if ! n_load_remote_host_config 2>/dev/null; then
    echo "Error: Unable to load host configuration"
    return 1
  fi
  
  # Get essential info
  local provisioning_node=$(n_get_provisioning_node 2>/dev/null || echo "unknown")
  local dns_domain=$(n_remote_cluster_variable DNS_DOMAIN 2>/dev/null | tr -d '"' || echo "unknown")
  local mac_address=$(ip link show 2>/dev/null | awk '/ether/ {print $2; exit}' || echo "unknown")
  local uptime_display="unknown"
  if [[ -f /proc/uptime ]]; then
    local uptime_seconds=$(cut -d. -f1 /proc/uptime)
    uptime_display=$(printf '%dd %dh %dm' $((uptime_seconds/86400)) $((uptime_seconds%86400/3600)) $((uptime_seconds%3600/60)))
  fi
  
  # Check console status
  local console_status="enabled"
  if [[ -f /sbin/nologin-console ]] && grep -q "nologin-console" /etc/inittab 2>/dev/null; then
    console_status="disabled"
  fi
  
  # Count active services
  local active_count=0
  for svc in networking sshd rsyslog dbus libvirtd; do
    if rc-service ${svc} status >/dev/null 2>&1; then
      ((active_count++))
    fi
  done
  
  # Clear screen only if running interactively and not in boot
  if [[ -t 1 ]] && [[ "$(cat /proc/uptime | cut -d. -f1)" -gt 60 ]]; then
    clear
  fi
  
  # Display compact info (24 lines total)
  echo "================================================================================"
  echo "           HPS NODE: ${HOSTNAME:-unknown}"
  echo "================================================================================"
  echo "Type:     ${TYPE:-unknown} / ${HOST_PROFILE:-unknown}      State: ${STATE:-unknown}"
  echo "IP:       ${IP:-unknown}/${NETMASK:-unknown}"
  echo "Gateway:      ${provisioning_node}    MAC: ${mac_address}"
  echo "Domain:       ${dns_domain}"
  echo "--------------------------------------------------------------------------------"
  echo "Uptime:       ${uptime_display}    Services: ${active_count}/5 active"
  echo "Virt:     ${virtualization_status:-none} (${virtualization_type:-n/a})"
  echo "Console:      ${console_status}"
  echo "Updated:      ${UPDATED:-unknown}"
  echo "================================================================================"
  
  # Add appropriate footer based on console status
  if [[ "${console_status}" == "disabled" ]]; then
    echo ""
    echo "Console access disabled. Connect via SSH to ${IP:-this node}"
    echo ""
  fi
  
  return 0
}



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
    n_remote_log "Error: No function specified" >&2
    return 1
  fi
  
  # Append to queue file
  echo "${func_call}" >> "${N_QUEUE_FILE}" || {
    n_remote_log "Error: Failed to add to queue" >&2
    return 1
  }
  
  n_remote_log "Queued: ${func_call}"
  return 0
}



n_queue_run() {
  local total=0
  local current=0
  local failed=0
  local func_call
  local func_name
  local start_time
  local end_time
  local duration
  local result
  local timeout=300  # 5 minute default timeout
  
  # Check if queue file exists
  if [[ ! -f "${N_QUEUE_FILE}" ]]; then
    n_remote_log "No functions queued for execution"
    return 0
  fi
  
  # Read entire queue into array to prevent file modification issues
  local -a queue_array
  mapfile -t queue_array < "${N_QUEUE_FILE}"
  total=${#queue_array[@]}
  
  if [[ ${total} -eq 0 ]]; then
    n_remote_log "No functions queued for execution"
    return 0
  fi
  
  n_remote_log "Starting execution of ${total} queued functions"
  
  # Process array instead of reading file
  for func_call in "${queue_array[@]}"; do
    # Skip empty lines
    [[ -z "${func_call}" ]] && continue
    
    # Increment counter safely
    current=$((current + 1))
    
    # Extract function name (first word)
    func_name="${func_call%% *}"
    
    n_remote_log "EXEC [${current}/${total}]: ${func_call}"
    
    # Record start time
    start_time=$(date +%s)


# In n_queue_run, use direct execution:
eval "${func_call}" 2>&1 | tee >(n_remote_log)
result=${PIPESTATUS[0]}


## Export functions first
#export -f $(declare -F | grep " n_" | cut -d' ' -f3)

## Then timeout will work
#timeout 30 bash -c "eval '${func_call}' 2>&1 | n_remote_log"


    result=$?
    # Record end time and calculate duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    if [[ ${result} -eq 0 ]]; then
      n_remote_log "SUCCESS [${current}/${total}]: ${func_name} completed in ${duration}s"
    elif [[ ${result} -eq 143 ]]; then
      # 143 = 128 + 15 (SIGTERM)
      failed=$((failed + 1))
      n_remote_log "TIMEOUT [${current}/${total}]: ${func_name} exceeded ${timeout}s timeout"
    else
      failed=$((failed + 1))
      n_remote_log "FAILED [${current}/${total}]: ${func_name} failed with code ${result} after ${duration}s"
    fi
  done
  
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
  n_remote_log "Function queue cleared"
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



