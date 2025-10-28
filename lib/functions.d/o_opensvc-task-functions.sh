
# Note that these functions exist on IPS and also relayed to nodes


#===============================================================================
# o_node_test_logger_ips
# ----------------------
# IPS version of test logger that uses IPS functions.
#
#===============================================================================
o_node_test_logger_ips() {
  local custom_msg="${1:-No custom message}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Use hps_log on IPS
  hps_log info "NODE_TASK_TEST: Running on IPS host: $(hostname)"
  hps_log info "NODE_TASK_TEST: Timestamp: ${timestamp}"
  hps_log info "NODE_TASK_TEST: Process ID: $$"
  hps_log info "NODE_TASK_TEST: Custom message: ${custom_msg}"
  
  return 0
}


# --------# -

#===============================================================================
# o_task_create
# -------------
# Create or update a task resource in an OpenSVC service.
#
# Usage:
#   o_task_create <service_name> <task_id> <command> <nodes>
#
# Parameters:
#   service_name - Service name (e.g., "storage", "healthcheck", "system")
#   task_id      - Task resource ID (e.g., "check_capacity", "vm_start")
#   command      - The command to execute (spaces allowed, no quotes needed)
#   nodes        - Space-separated node list or "all" for all cluster nodes
#
# Behavior:
#   - Creates service if it doesn't exist (with orchestrate=no)
#   - Adds new task or updates existing task using om config update
#   - Preserves all existing tasks and service ID
#   - Unfreezes and clears error states
#   - Service ready for o_task_run
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_create "storage" "check_capacity" "df -h" "tch-001 tch-002"
#   o_task_create "healthcheck" "ping_test" "ping -c 1 8.8.8.8" "all"
#   o_task_create "system" "reboot_node" "reboot" "tch-001"
#
#===============================================================================
o_task_create() {
  local service_name="$1"
  local task_id="$2"
  local command="$3"
  local nodes="$4"
  
  # Validate parameters
  if [ -z "$service_name" ] || [ -z "$task_id" ] || [ -z "$command" ] || [ -z "$nodes" ]; then
    o_log "o_task_create: missing required parameters" "err"
    return 1
  fi
  
  # Check for unsupported quote characters in command
  if echo "$command" | grep -q '["]'; then
    o_log "o_task_create: command contains unsupported quote characters. Use commands without quotes (e.g., 'echo Task1' not 'echo \"Task 1\"')" "err"
    return 1
  fi
  
  # Expand "all" to actual node list
  if [ "$nodes" = "all" ]; then
    nodes="ips tch-001 tch-002"
  fi
  
  # Check if service exists
  if om "$service_name" print config >/dev/null 2>&1; then
    o_log "Service $service_name exists, will update task" "info"
  else
    # Create new service
    o_log "Creating new service $service_name" "info"
    if ! om "$service_name" create --kw nodes="$nodes" --kw orchestrate=no >/dev/null 2>&1; then
      o_log "Failed to create service $service_name" "err"
      return 1
    fi
    # Wait for service to be registered by daemon
    sleep 2
  fi
  
  # Add or update task using config update
  o_log "Adding/updating task $task_id in service $service_name" "info"
  if ! om "$service_name" config update --set "task#${task_id}.command=${command}" >/dev/null 2>&1; then
    o_log "Failed to add/update task $task_id" "err"
    return 1
  fi
  
  # Unfreeze and clear error states
  o_log "Unfreezing service $service_name" "info"
  om "$service_name" unfreeze >/dev/null 2>&1
  
  o_log "Clearing error states for service $service_name" "info"
  om "$service_name" clear >/dev/null 2>&1
  
  o_log "Task $task_id created/updated in service $service_name" "info"
  return 0
}



#!/bin/bash

#===============================================================================
# o_task_delete
# -------------
# Delete a task from a service, or delete an entire service.
#
# Usage:
#   o_task_delete <service_name> [task_id]
#
# Parameters:
#   service_name - Service name (required)
#   task_id      - Specific task to delete (optional, if omitted deletes service)
#
# Behavior:
#   - If task_id provided: Removes only that task using om config update --delete
#   - If task_id omitted: Deletes entire service (abort, purge, delete)
#   - Uses aggressive cleanup (abort + purge) to force service removal
#   - Empty services are preserved when deleting last task
#
# Returns:
#   0 on success
#   1 on failure (task/service doesn't exist)
#
# Example usage:
#   o_task_delete "storage" "check_capacity"    # Delete one task
#   o_task_delete "testservice"                 # Delete entire service
#
#===============================================================================
o_task_delete() {
  local service_name="$1"
  local task_id="$2"
  
  # Validate service name
  if [ -z "$service_name" ]; then
    o_log "o_task_delete: service_name is required" "err"
    return 1
  fi
  
  # Check if service exists
  if ! om "$service_name" print config >/dev/null 2>&1; then
    o_log "Service $service_name does not exist" "warning"
    return 1
  fi
  
  # Delete entire service if no task_id provided
  if [ -z "$task_id" ]; then
    o_log "Deleting entire service $service_name" "info"
    
    # Abort any running operations
    o_log "Aborting any operations on $service_name" "info"
    om "$service_name" abort >/dev/null 2>&1
    
    sleep 2
    
    # Purge (unprovision and delete)
    o_log "Purging service $service_name" "info"
    om "$service_name" purge >/dev/null 2>&1
    
    sleep 2
    
    # Final delete to ensure config is removed
    o_log "Deleting service $service_name" "info"
    if om "$service_name" delete >/dev/null 2>&1; then
      o_log "Service $service_name deleted successfully" "info"
      return 0
    else
      # Check if service is actually gone
      if ! om "$service_name" print config >/dev/null 2>&1; then
        o_log "Service $service_name deleted successfully" "info"
        return 0
      else
        o_log "Failed to delete service $service_name" "err"
        return 1
      fi
    fi
  fi
  
  # Delete specific task
  o_log "Deleting task $task_id from service $service_name" "info"
  
  # Check if task exists
  local task_exists
  task_exists=$(om "$service_name" print config | grep -E "^\[task#${task_id}\]")
  
  if [ -z "$task_exists" ]; then
    o_log "Task $task_id does not exist in service $service_name" "warning"
    return 1
  fi
  
  # Delete task using config update
  if om "$service_name" config update --delete "task#${task_id}" >/dev/null 2>&1; then
    o_log "Task $task_id deleted from service $service_name" "info"
    return 0
  else
    o_log "Failed to delete task $task_id from service $service_name" "err"
    return 1
  fi
}


#===============================================================================
# o_task_list
# -----------
# List all OpenSVC services and their tasks.
#
# Usage:
#   o_task_list [service_name]
#
# Parameters:
#   service_name - (optional) Specific service to list. If omitted, lists all.
#
# Behavior:
#   - Lists services with their orchestration settings and tasks
#   - Shows task commands for each service
#   - If service_name provided, shows only that service
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_list
#   o_task_list storage
#
#===============================================================================
o_task_list() {
  local service_name="$1"
  
  # Get list of services
  local services
  if [ -n "$service_name" ]; then
    # Check if specific service exists
    if ! om "$service_name" print config >/dev/null 2>&1; then
      o_log "Service $service_name not found" "err"
      return 1
    fi
    services="$service_name"
  else
    # Get all services
    services=$(om svc list 2>/dev/null | grep -v "^OBJECT" | awk '{print $1}')
    
    if [ -z "$services" ]; then
      echo "No services found"
      return 0
    fi
  fi
  
  echo "Services:"
  
  # Process each service
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    
    # Get service configuration
    local config
    config=$(om "$svc" print config 2>/dev/null)
    
    if [ -z "$config" ]; then
      continue
    fi
    
    # Extract service details
    local orchestrate
    orchestrate=$(echo "$config" | grep "^orchestrate = " | sed 's/^orchestrate = //' | tr '\n' ' ' | xargs)
    
    local nodes
    nodes=$(echo "$config" | grep "^nodes = " | sed 's/^nodes = //' | tr '\n' ' ' | xargs)
    
    # Get task list
    local tasks
    tasks=$(echo "$config" | grep -E "^\[task#" | sed 's/\[//;s/\]//')
    
    # Skip services with no tasks
    if [ -z "$tasks" ]; then
      continue
    fi
    
    # Print service header
    echo "  $svc (orchestrate=${orchestrate:-none}, nodes=${nodes:-none})"
    
    # Print each task
    while IFS= read -r task; do
      [ -z "$task" ] && continue
      
      # Get task command
      local task_cmd
      task_cmd=$(om "$svc" print config --section "$task" 2>/dev/null | grep "^command = " | sed 's/^command = //')
      
      if [ -n "$task_cmd" ]; then
        echo "    - $task: $task_cmd"
      fi
    done <<< "$tasks"
    
    echo ""
  done <<< "$services"
  
  return 0
}


#===============================================================================
# o_log
# -----
# Log messages to syslog with priority levels for OpenSVC operations.
#
# Usage:
#   o_log <message> [priority]
#
# Parameters:
#   message  - The log message string (required)
#   priority - Syslog priority: err, warning, info, debug (optional, default: info)
#   facility - Syslog facility (optional, default: user)
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_log "Task started successfully" "info"
#   o_log "Connection failed" "err"
#   o_log "Low disk space" "warning"
#   o_log "Task completed"
#   o_log "Critical error" "err" "local0"
#
#===============================================================================
o_log() {
  local message="$1"
  local priority="${2:-info}"
  local facility="${3:-user}"
  local tag="opensvc"
  
  # Validate message parameter
  if [ -z "$message" ]; then
    logger -t "$tag" -p user.err "o_log called with empty message"
    return 1
  fi
  
  # Validate priority parameter
  case "$priority" in
    err|warning|info|debug)
      ;;
    *)
      logger -t "$tag" -p user.warning "o_log: invalid priority '$priority', using 'info'"
      priority="info"
      ;;
  esac
  
  # Validate facility parameter
  case "$facility" in
    user|local0|local1|local2|local3|local4|local5|local6|local7|daemon|auth|syslog)
      ;;
    *)
      logger -t "$tag" -p user.warning "o_log: invalid facility '$facility', using 'user'"
      facility="user"
      ;;
  esac
  
  # Log the message
  logger -t "$tag" -p "${facility}.${priority}" "$message"
  return $?
}


