# This file is run first

mkdir -p /lib/modules


## TODO@ This should be more sensible - we can ask IPS for this
n_get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}



#===============================================================================
# n_enable_console_output
# -----------------------
# Enable console output for boot messages.
#
# Usage:
#   n_enable_console_output
#
# Behaviour:
#   - Ensures console output is not suppressed
#   - Enables verbose boot messages
#
# Returns:
#   0 on success
#===============================================================================
n_enable_console_output() {
    # Enable console output
    if [[ -f /proc/sys/kernel/printk ]]; then
        echo "7 4 1 7" > /proc/sys/kernel/printk
        n_remote_log "Enabled verbose console output"
    fi
    
    # Ensure rc messages go to console
    export RC_QUIET=no
    export RC_VERBOSE=yes
    
    # For Alpine OpenRC - show service messages on console
    if [[ -f /etc/rc.conf ]]; then
        sed -i 's/^rc_quiet=.*/rc_quiet="NO"/' /etc/rc.conf 2>/dev/null || \
        echo 'rc_quiet="NO"' >> /etc/rc.conf
        
        sed -i 's/^rc_verbose=.*/rc_verbose="YES"/' /etc/rc.conf 2>/dev/null || \
        echo 'rc_verbose="YES"' >> /etc/rc.conf
    fi
    
    n_remote_log "Configured console for boot message output"
    return 0
}

#===============================================================================
# n_console_message
# -----------------
# Print a message directly to the console.
#
# Usage:
#   n_console_message "message"
#
# Returns:
#   0 on success
#===============================================================================
n_console_message() {
    local message="${1:-System message}"
    
    # Print to console if available
    if [[ -w /dev/console ]]; then
        echo "[HPS] ${message}" > /dev/console
    fi
    
    # Also print to tty1 if available
    if [[ -w /dev/tty1 ]]; then
        echo "[HPS] ${message}" > /dev/tty1
    fi
    
    return 0
}





#===============================================================================
# n_load_remote_host_config
# -------------------------
# Load and execute host configuration from the provisioning node.
#
# Usage:
#   n_load_remote_host_config
#
# Behaviour:
#   - Requests host configuration from IPS using host_get_config command
#   - Evaluates the returned configuration in the current shell context
#   - Logs success/failure to remote provisioning node
#   - Optionally logs the configuration content for debugging
#
# Dependencies:
#   - n_ips_command function must be available
#   - n_remote_log function must be available
#
# Security Note:
#   This function executes remote configuration using eval. Ensure the
#   provisioning node is trusted and communications are secure.
#
# Returns:
#   0 on success
#   1 if configuration fetch fails
#===============================================================================
n_load_remote_host_config() {
  local conf
  
  conf="$(n_ips_command "host_get_config")" || {
    n_remote_log "Failed to load host config"
    return 1
  }
  
  # Optional debug
  n_remote_log "Remote config loaded"
  
  eval "$conf"
}



# n_url_encode
# ----------
# Percent-encode a string for safe inclusion in URL query parameters.
# Encodes all non [A-Za-z0-9.~_-] bytes, including spaces and newlines.
#
# Usage:
#   enc="$(n_url_encode "value with spaces & symbols")"
#
# Inputs:
#   $1  Unencoded string
#
# Outputs:
#   stdout: encoded string
#
# Returns:
#   0 on success
n_url_encode() {
  # shellcheck disable=SC2039
  local s="${1-}" out="" c i
  # Process as bytes; ensure predictable classification
  LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ')              out+="%20" ;;  # fast-path for spaces
      *)                printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}


#===============================================================================
# n_ips_command
# -------------
# Generic function to send commands to the IPS (Initial Provisioning System).
#
# Usage:
#   n_ips_command "command" ["param1=value1" "param2=value2" ...]
#
# Parameters:
#   $1     - Command name to execute on IPS (required)
#   $2...  - Additional parameters as "key=value" pairs (optional)
#
# Behaviour:
#   - Calls n_get_provisioning_node to determine the gateway IP/hostname
#   - URL-encodes all parameter values to handle special characters
#   - Constructs query string with command and encoded parameters
#   - POSTs to boot_manager.sh CGI endpoint
#   - Checks for HTTP 502 and other error responses
#   - Returns raw response data to caller for processing on success
#   - Stores error details in global variables on failure
#
# Examples:
#   n_ips_command "log_message" "message=System started" "function=init"
#   n_ips_command "get_config" "node=$(hostname)"
#   response=$(n_ips_command "node_status" "state=ready")
#
# Dependencies:
#   - n_get_provisioning_node function must be available
#   - n_url_encode function must be available
#   - curl command must be installed
#   - Provisioning node must be reachable via HTTP
#
# Error Handling:
#   - Sets global variables on failure:
#     * N_IPS_COMMAND_LAST_ERROR - Human-readable error description
#     * N_IPS_COMMAND_LAST_RESPONSE - Server's error response body (if any)
#   - No error output to stdout or stderr (silent operation)
#   - Callers must check return code and/or global variables
#
# Returns:
#   0 on success (HTTP 2xx response)
#   1 if gateway cannot be determined
#   2 if curl fails (network error)
#   3 if HTTP error response (4xx, 5xx)
#
# Output:
#   Success: Response body to stdout
#   Failure: No output (check global variables)
#
# Example error handling:
#   if ! result=$(n_ips_command "some_command"); then
#     echo "Error: $N_IPS_COMMAND_LAST_ERROR" >&2
#     echo "Response: $N_IPS_COMMAND_LAST_RESPONSE" >&2
#   fi
#===============================================================================
n_ips_command() {
  local cmd="${1:?Usage: n_ips_command <command> [param=value ...]}"
  shift
  
  # Clear previous error info
  N_IPS_COMMAND_LAST_ERROR=""
  N_IPS_COMMAND_LAST_RESPONSE=""
  
  local ips
  ips="$(n_get_provisioning_node)" || {
    N_IPS_COMMAND_LAST_ERROR="Failed to determine IPS gateway"
    return 1
  }
  
  # Start building query string with command
  local query="cmd=${cmd}"
  
  # Process additional parameters
  local param key value
  for param in "$@"; do
    # Split on first = to handle values containing =
    key="${param%%=*}"
    value="${param#*=}"
    
    # URL encode the value but not the key
    value="$(n_url_encode "$value")"
    query="${query}&${key}=${value}"
  done
  
  local url="http://${ips}/cgi-bin/boot_manager.sh?${query}"
  local response
  local http_code
  local curl_exit
  
  # Execute POST request with separate capture of HTTP code
  # Using -w to get HTTP code, -s for silent, -S to show errors
  # Redirect stderr to capture curl errors silently
  response=$(curl -sS -w "\n%{http_code}" -X POST "$url" 2>&1)
  curl_exit=$?
  
  # Check if curl itself failed
  if [[ $curl_exit -ne 0 ]]; then
    N_IPS_COMMAND_LAST_ERROR="curl failed (exit $curl_exit) for command: $cmd"
    N_IPS_COMMAND_LAST_RESPONSE="$response"
    return 2
  fi
  
  # Extract HTTP code from last line
  http_code=$(echo "$response" | tail -n1)
  # Remove HTTP code from response
  response=$(echo "$response" | sed '$d')
  
  # Check HTTP response code
  if [[ "$http_code" =~ ^[45][0-9][0-9]$ ]]; then
    N_IPS_COMMAND_LAST_ERROR="HTTP $http_code for command: $cmd (URL: $url)"
    N_IPS_COMMAND_LAST_RESPONSE="$response"
    
    # Special handling for 502 Bad Gateway
    if [[ "$http_code" == "502" ]]; then
      N_IPS_COMMAND_LAST_ERROR="HTTP 502 Bad Gateway - An error occurred while reading CGI reply (no response received). Command: $cmd url: $url"
    fi
    
    # Don't output error responses
    return 3
  fi
  
  # Success - output response to stdout
  echo "$response"
  return 0
}

#===============================================================================
# n_remote_log
# ------------
# Send log messages from remote nodes to the provisioning node's logging system.
#
# Usage:
#   n_remote_log "message text"
#
# Parameters:
#   $1 - Log message to send (required)
#
# Behaviour:
#   - Retrieves the calling function name from bash call stack
#   - Sends log_message command to IPS with message and function context
#   - Outputs any errors to stdout for visibility
#
# Dependencies:
#   - n_ips_command function must be available
#
# Output:
#   Success: No output
#   Failure: Error details to stdout
#
# Returns:
#   0 on success
#   Exit code from n_ips_command on failure (1-3)
#===============================================================================
n_remote_log() {
  local message="${1:?Usage: n_remote_log <message>}"
  local function="${FUNCNAME[1]}"
  
  if ! n_ips_command "log_message" "message=${message}" "function=${function}"; then
    # Output error info to stdout
    echo "n_remote_log: $N_IPS_COMMAND_LAST_ERROR"
    if [[ -n "$N_IPS_COMMAND_LAST_RESPONSE" ]]; then
      echo "Server response: $N_IPS_COMMAND_LAST_RESPONSE"
    fi
    return $?
  fi
  
  return 0
}

#===============================================================================
# n_remote_host_variable
# ----------------------
# Get or set a host variable on the provisioning node.
#
# Usage:
#   n_remote_host_variable <name> <value>   # set
#   n_remote_host_variable <name>           # get
#
# Parameters:
#   $1 - Variable name (required)
#   $2 - Variable value (optional; if provided, will set)
#
# Behaviour:
#   - GET: When called with only name, retrieves the variable value
#   - SET: When called with name and value, sets the variable
#   - Uses host_variable command on IPS
#   - Logs errors to IPS via n_remote_log
#
# Dependencies:
#   - n_ips_command function must be available
#   - n_remote_log function must be available
#
# Output:
#   GET: Raw value of the variable (or nothing on error)
#   SET: Success/failure message from server (or nothing on error)
#
# Returns:
#   0 on success
#   Exit code from n_ips_command on failure (1-3)
#===============================================================================
n_remote_host_variable() {
  local name="${1:?Usage: n_remote_host_variable <name> [<value>]}"
  local value="${2-}"
  local result
  local exit_code
  
  if [[ -n "$value" ]]; then
    # SET operation
    result=$(n_ips_command "host_variable" "name=${name}" "value=${value}")
    exit_code=$?
  else
    # GET operation
    result=$(n_ips_command "host_variable" "name=${name}")
    exit_code=$?
  fi
  
  if [[ $exit_code -eq 0 ]]; then
    # Success - output result
    echo "$result"
    return 0
  else
    # Log error
    local operation=$([[ -n "$value" ]] && echo "set" || echo "get")
    n_remote_log "Failed to $operation host variable '$name': $N_IPS_COMMAND_LAST_ERROR"
    return $exit_code
  fi
}

#===============================================================================
# n_remote_cluster_variable
# -------------------------
# Get or set a cluster variable on the provisioning node.
#
# Usage:
#   n_remote_cluster_variable <name> <value>   # set
#   n_remote_cluster_variable <name>           # get
#
# Parameters:
#   $1 - Variable name (required)
#   $2 - Variable value (optional; if provided, will set)
#
# Behaviour:
#   - GET: When called with only name, retrieves the variable value
#   - SET: When called with name and value, sets the variable
#   - Uses cluster_variable command on IPS
#   - Logs errors to IPS via n_remote_log
#
# Dependencies:
#   - n_ips_command function must be available
#   - n_remote_log function must be available
#
# Output:
#   GET: Raw value of the variable (or nothing on error)
#   SET: Success/failure message from server (or nothing on error)
#
# Returns:
#   0 on success
#   Exit code from n_ips_command on failure (1-3)
#===============================================================================
n_remote_cluster_variable() {
  local name="${1:?Usage: n_remote_cluster_variable <name> [<value>]}"
  local value="${2-}"
  local result
  local exit_code
  
  if [[ $# -ge 2 ]]; then
    # SET operation - check arg count to handle empty string values
    result=$(n_ips_command "cluster_variable" "name=${name}" "value=${value}")
    exit_code=$?
  else
    # GET operation
    result=$(n_ips_command "cluster_variable" "name=${name}")
    exit_code=$?
  fi
  
  if [[ $exit_code -eq 0 ]]; then
    # Success - output result
    echo "$result"
    return 0
  else
    # Log error
    local operation=$([[ $# -ge 2 ]] && echo "set" || echo "get")
    n_remote_log "Failed to $operation cluster variable '$name': $N_IPS_COMMAND_LAST_ERROR"
    return $exit_code
  fi
}



n_remote_log "Starting to load node functions"


