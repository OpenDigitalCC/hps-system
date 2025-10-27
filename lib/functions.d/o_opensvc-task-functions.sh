

# Note that these functions exist on IPS and also relayed to nodes


o_opensvc_task_test() {
  local msg="${1:-default_message}"
  local host=$(hostname)
  local timestamp=$(date '+%Y-%m-%d_%H:%M:%S')
  logger -t TEST "EXEC_TEST: host=${host} time=${timestamp} msg=${msg} pid=$$"
  o_log info "EXEC_TEST: host=${host} time=${timestamp} msg=${msg} pid=$$"
  return 0
}
EOF

o_opensvc_task_exec() {
  o_opensvc_task_test "task_executed_via_opensvc"
}


# Function to delete OpenSVC services
o_service_delete() {
  local service_path="$1"
  if [ -z "$service_path" ]; then
    echo "Usage: o_service_delete <service_path>"
    return 1
  fi
  
  echo "Deleting service: $service_path"
  om "$service_path" delete --force
  return $?
}

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

#===============================================================================
# o_task_function_create
# ----------------------
# Create an OpenSVC task that executes an HPS function.
# Works on both IPS and nodes.
#
# Arguments:
#   $1 - location (ips or node)
#   $2 - type (e.g., storage, monitoring)
#   $3 - function name to execute
#   $4 - service name (optional, defaults to "<location>/<type>")
#
# Behaviour:
#   - Creates an OpenSVC service if it doesn't exist
#   - Adds a task named after the function
#   - For IPS: sources /srv/hps-system/lib/functions.sh
#   - For nodes: sources bootstrap and loads node functions
#   - Uses bash shell explicitly
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_function_create ips storage hps_storage_check
#   o_task_function_create node monitoring n_check_memory
#
#===============================================================================
o_task_function_create() {
  local location="$1"
  local type="$2"
  local function_name="$3"
  local service_name="${4:-${location}-${type}}"
  
  if [ -z "$location" ] || [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_function_create <ips|node> <type> <function_name> [service_name]"
    return 1
  fi
  
  # Validate location
  if [ "$location" != "ips" ] && [ "$location" != "node" ]; then
    echo "ERROR: Location must be 'ips' or 'node'"
    return 1
  fi
  
  # Create the service path - use system namespace for production, test for testing
  local namespace="${HPS_OPENSVC_NAMESPACE:-test}"
  local service_path="${namespace}/svc/${service_name}"
  
  # Build the command based on location
  local cmd
  if [ "$location" = "ips" ]; then
    cmd="/bin/bash -c '. /srv/hps-system/lib/functions.sh && ${function_name}'"
  else
    cmd="/bin/bash -c 'source /usr/local/lib/hps-bootstrap-lib.sh && hps_load_node_functions && ${function_name}'"
  fi
  
  # Create service (ignore if already exists)
  om "${service_path}" create 2>/dev/null || true
  
  # Small delay to ensure service is ready
  sleep 0.5
  
  # Create the task
  om "${service_path}" set --kw "task#${function_name}.command=${cmd}"
  
  if [ $? -eq 0 ]; then
    echo "Created ${location} task '${function_name}' in service '${service_path}'"
    return 0
  else
    echo "ERROR: Failed to create ${location} task '${function_name}' in service '${service_path}'"
    return 1
  fi
}

#===============================================================================
# o_task_function_run
# -------------------
# Run an OpenSVC task that was created for an HPS function.
# Works on both IPS and nodes.
#
# Arguments:
#   $1 - location (ips or node)
#   $2 - type (e.g., storage, monitoring)
#   $3 - function name to run
#   $4 - service name (optional, defaults to "<location>/<type>")
#
# Behaviour:
#   - Runs the specified task in the OpenSVC service
#   - Outputs the result
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_function_run ips storage hps_storage_check
#   o_task_function_run node monitoring n_check_memory
#
#===============================================================================
o_task_function_run() {
  local location="$1"
  local type="$2"
  local function_name="$3"
  local service_name="${4:-${location}/${type}}"
  
  if [ -z "$location" ] || [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_function_run <ips|node> <type> <function_name> [service_name]"
    return 1
  fi
  
  # Create the service path
  local service_path="test/svc/${service_name}"
  
  # Run the task
  om "${service_path}" run --rid "task#${function_name}"
  
  return $?
}

#===============================================================================
# o_task_function_create_with_params
# ----------------------------------
# Create an OpenSVC task that executes an HPS function with parameters.
# Works on both IPS and nodes.
#
# Arguments:
#   $1 - location (ips or node)
#   $2 - type (e.g., storage, monitoring)
#   $3 - function name to execute
#   $4 - parameters to pass to the function
#   $5 - service name (optional, defaults to "<location>/<type>")
#
# Behaviour:
#   - Creates an OpenSVC service if it doesn't exist
#   - Adds a task named after the function
#   - Task sources appropriate functions and executes with parameters
#   - Uses bash shell explicitly
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_function_create_with_params ips storage hps_storage_check "sda 1024"
#   o_task_function_create_with_params node monitoring n_check_load "5 10"
#
#===============================================================================
o_task_function_create_with_params() {
  local location="$1"
  local type="$2"
  local function_name="$3"
  local params="$4"
  local service_name="${5:-${location}/${type}}"
  
  if [ -z "$location" ] || [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_function_create_with_params <ips|node> <type> <function_name> <params> [service_name]"
    return 1
  fi
  
  # Validate location
  if [ "$location" != "ips" ] && [ "$location" != "node" ]; then
    echo "ERROR: Location must be 'ips' or 'node'"
    return 1
  fi
  
  # Create the service path
  local service_path="test/svc/${service_name}"
  
  # Build the command based on location
  local cmd
  if [ "$location" = "ips" ]; then
    cmd="/bin/bash -c '. /srv/hps-system/lib/functions.sh && ${function_name} ${params}'"
  else
    cmd="/bin/bash -c 'source /usr/local/lib/hps-bootstrap-lib.sh && hps_load_node_functions && ${function_name} ${params}'"
  fi
  
  # Create service (ignore if already exists)
  om "${service_path}" create 2>/dev/null || true
  
  # Small delay to ensure service is ready
  sleep 0.5
  
  # Create the task with parameters
  om "${service_path}" set --kw "task#${function_name}.command=${cmd}"
  
  if [ $? -eq 0 ]; then
    echo "Created ${location} task '${function_name}' with params '${params}' in service '${service_path}'"
    return 0
  else
    echo "ERROR: Failed to create ${location} task '${function_name}' in service '${service_path}'"
    return 1
  fi
}

#===============================================================================
# o_log
# -----
# Agnostic logging function that works on both IPS and nodes.
#
# Arguments:
#   $1 - log level (info, warn, error)
#   $2 - message
#
# Behaviour:
#   - On IPS: uses hps_log if available
#   - On nodes: uses n_remote_log if available
#   - Falls back to logger if neither is available
#
# Returns:
#   0 on success
#
# Example usage:
#   o_log info "Task completed successfully"
#   o_log error "Failed to execute task"
#
#===============================================================================
o_log() {
  local level="$1"
  local message="$2"
  
  # Try hps_log first (IPS)
  if command -v hps_log >/dev/null 2>&1; then
    hps_log "$level" "$message"
  # Try n_remote_log (node)
  elif command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "[$level] $message"
  # Fall back to logger
  else
    logger -t "opensvc" "[$level] $message"
  fi
}

#===============================================================================
# o_test_params
# -------------
# Test function for parameter demonstration that works on both IPS and nodes.
#
# Arguments:
#   Any number of parameters
#
# Returns:
#   0 on success
#
# Example usage:
#   o_test_params param1 param2 param3
#
#===============================================================================
o_test_params() {
  o_log info "Function: o_test_params"
  o_log info "Number of parameters: $#"
  o_log info "Parameters: $*"
  
  local count=1
  for param in "$@"; do
    o_log info "  Param $count: $param"
    ((count++))
  done
  
  return 0
}

#===============================================================================
# o_task_list
# -----------
# List tasks in a service.
#
# Arguments:
#   $1 - location (ips or node)
#   $2 - type (e.g., storage, monitoring)
#   $3 - service name (optional, defaults to "<location>/<type>")
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_list ips storage
#   o_task_list node monitoring
#
#===============================================================================
o_task_list() {
  local location="$1"
  local type="$2"
  local service_name="${3:-${location}-${type}}"
  local namespace="${HPS_OPENSVC_NAMESPACE:-test}"
  local service_path="${namespace}/svc/${service_name}"
  
  echo "Tasks in service: ${service_path}"
  om "${service_path}" print config --rid 'task#*' 2>/dev/null || echo "Service not found"
}

#===============================================================================
# o_task_run_on_nodes
# -------------------
# Run a task on multiple nodes (called from IPS).
#
# Arguments:
#   $1 - type (e.g., storage, monitoring)
#   $2 - function name
#   $3 - node selector (optional, defaults to all nodes)
#
# Behaviour:
#   - Uses OpenSVC to run the task on selected nodes
#   - Task must already exist in node/<type> service
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_run_on_nodes monitoring n_check_memory
#   o_task_run_on_nodes storage n_check_disk "@nodes"
#
#===============================================================================
o_task_run_on_nodes() {
  local type="$1"
  local function_name="$2"
  local node_selector="${3:-}"  # Empty means current node
  
  if [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_run_on_nodes <type> <function_name> [node_selector]"
    return 1
  fi
  
  local namespace="${HPS_OPENSVC_NAMESPACE:-test}"
  local service_path="${namespace}/svc/node-${type}"
  
  # Run on nodes
  if [ -z "$node_selector" ]; then
    # Run on current node
    om "${service_path}" run --rid "task#${function_name}"
  else
    # Run on specified nodes
    om "${service_path}" run --rid "task#${function_name}" --node "${node_selector}"
  fi
  
  return $?
}

#===============================================================================
# o_task_deploy_to_node
# ---------------------
# Deploy a task configuration to a specific node from IPS.
# This creates the service and task on the target node.
#
# Arguments:
#   $1 - node name (e.g., tch-001)
#   $2 - type (e.g., storage, monitoring)
#   $3 - function name to execute
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_deploy_to_node tch-001 monitoring o_node_test_logger
#
#===============================================================================
o_task_deploy_to_node() {
  local node="$1"
  local type="$2"
  local function_name="$3"
  
  if [ -z "$node" ] || [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_deploy_to_node <node> <type> <function_name>"
    return 1
  fi
  
  local namespace="${HPS_OPENSVC_NAMESPACE:-test}"
  local service_name="node-${type}"
  local service_path="${namespace}/svc/${service_name}"
  
  # Create the service on the specific node
  echo "Creating service on node ${node}..."
  om "${service_path}" create --node "${node}"
  
  # Set the task configuration on that node
  echo "Configuring task on node ${node}..."
  om "${service_path}" set \
    --node "${node}" \
    --kw "task#${function_name}.command=/bin/bash -c 'source /usr/local/lib/hps-bootstrap-lib.sh && hps_load_node_functions && ${function_name}'"
  
  if [ $? -eq 0 ]; then
    echo "Task '${function_name}' deployed to node '${node}'"
    return 0
  else
    echo "ERROR: Failed to deploy task to node '${node}'"
    return 1
  fi
}

#===============================================================================
# o_task_run_on_node
# ------------------
# Run a task on a specific node.
#
# Arguments:
#   $1 - node name
#   $2 - type (e.g., storage, monitoring)  
#   $3 - function name
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   o_task_run_on_node tch-001 monitoring o_node_test_logger
#
#===============================================================================
o_task_run_on_node() {
  local node="$1"
  local type="$2"
  local function_name="$3"
  
  if [ -z "$node" ] || [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_run_on_node <node> <type> <function_name>"
    return 1
  fi
  
  local namespace="${HPS_OPENSVC_NAMESPACE:-test}"
  local service_path="${namespace}/svc/node-${type}"
  
  echo "Running task '${function_name}' on node '${node}'..."
  om "${service_path}" run --rid "task#${function_name}" --node "${node}"
  
  return $?
}

#===============================================================================
# o_task_deploy_to_all_nodes
# --------------------------
# Deploy a task to all compute nodes (excluding IPS).
#
# Arguments:
#   $1 - type (e.g., storage, monitoring)
#   $2 - function name
#
# Returns:
#   0 on success
#   1 on any failure
#
# Example usage:
#   o_task_deploy_to_all_nodes monitoring o_node_test_logger
#
#===============================================================================
o_task_deploy_to_all_nodes() {
  local type="$1"
  local function_name="$2"
  
  if [ -z "$type" ] || [ -z "$function_name" ]; then
    echo "ERROR: Usage: o_task_deploy_to_all_nodes <type> <function_name>"
    return 1
  fi
  
  local failed=0
  
  # Get all nodes and deploy to each (except IPS)
  for node in $(om node list | grep -v "^ips"); do
    echo "Deploying to node: ${node}"
    if o_task_deploy_to_node "${node}" "${type}" "${function_name}"; then
      echo "  ✓ Success"
    else
      echo "  ✗ Failed"
      ((failed++))
    fi
  done
  
  if [ $failed -eq 0 ]; then
    echo "All deployments successful"
    return 0
  else
    echo "${failed} deployments failed"
    return 1
  fi
}


