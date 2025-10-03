# This file is run first

mkdir -p /lib/modules

# Debug console output
exec 2>&1  # Redirect stderr to stdout
echo "Console test at $(date)" > /dev/console
echo "Console test at $(date)" > /dev/tty1


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
#   - Returns raw response data to caller for processing
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
# Returns:
#   0 on success (HTTP request completed)
#   1 if gateway cannot be determined
#   curl exit code on HTTP failure
#
# Output:
#   Writes response body to stdout for caller to capture
#===============================================================================
n_ips_command() {
  local cmd="${1:?Usage: n_ips_command <command> [param=value ...]}"
  shift
  
  local ips
  ips="$(n_get_provisioning_node)" || return 1
  
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
  
  # Execute POST request
  curl -fsS -X POST "http://${ips}/cgi-bin/boot_manager.sh?${query}"
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
#
# Dependencies:
#   - n_ips_command function must be available
#
# Returns:
#   Exit code from n_ips_command
#===============================================================================
n_remote_log() {
  local message="${1:?Usage: n_remote_log <message>}"
  local function="${FUNCNAME[1]}"
  
  n_ips_command "log_message" "message=${message}" "function=${function}"
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
#
# Dependencies:
#   - n_ips_command function must be available
#
# Output:
#   GET: Raw value of the variable
#   SET: Success/failure message from server
#
# Returns:
#   Exit code from n_ips_command
#===============================================================================
n_remote_host_variable() {
  local name="${1:?Usage: n_remote_host_variable <name> [<value>]}"
  local value="${2-}"
  
  if [[ -n "$value" ]]; then
    # SET operation
    n_ips_command "host_variable" "name=${name}" "value=${value}"
  else
    # GET operation
    n_ips_command "host_variable" "name=${name}"
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
#
# Dependencies:
#   - n_ips_command function must be available
#
# Output:
#   GET: Raw value of the variable
#   SET: Success/failure message from server
#
# Returns:
#   Exit code from n_ips_command
#===============================================================================
n_remote_cluster_variable() {
  local name="${1:?Usage: n_remote_cluster_variable <name> [<value>]}"
  local value="${2-}"
  
  if [[ $# -ge 2 ]]; then
    # SET operation - check arg count to handle empty string values
    n_ips_command "cluster_variable" "name=${name}" "value=${value}"
  else
    # GET operation
    n_ips_command "cluster_variable" "name=${name}"
  fi
}

n_remote_log "Starting to load node functions"

n_enable_console_output    # Add this first


