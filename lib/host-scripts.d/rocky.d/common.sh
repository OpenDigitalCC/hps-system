# /srv/hps/functions.d/common.sh


#===============================================================================
# node_storage_manager
# --------------------
# Wrapper function to manage zvol and iSCSI operations on storage nodes.
#
# Behaviour:
#   - Validates component and action arguments
#   - Dispatches to component-specific management functions
#   - Uses remote_log for all progress and error reporting
#   - Returns appropriate exit codes for orchestration
#
# Arguments:
#   $1 - component (lio|zvol)
#   $2 - action (start|stop|create|delete|etc)
#   $@ - additional arguments passed to component function
#
# Examples:
#   node_storage_manager lio start
#   node_storage_manager zvol create --pool ztest --name vm-a --size 40G
#
# Returns:
#   0 on success
#   1 on error (invalid component or operation failure)
#===============================================================================
node_storage_manager() {
  local component="$1"
  local action="$2"
  shift 2
  
  # Validate arguments
  if [ -z "$component" ] || [ -z "$action" ]; then
    remote_log "Usage: node_storage_manager <component> <action> [options]"
    return 1
  fi
  
  # Dispatch to appropriate function
  case "$component" in
    lio)
      remote_log "Executing LIO ${action}"
      node_lio_manage "$action" "$@"
      ;;
    zvol)
      remote_log "Executing zvol ${action}"
      node_zvol_manage "$action" "$@"
      ;;
    *)
      remote_log "Unknown component '${component}'. Valid: lio, zvol"
      return 1
      ;;
  esac
  
  local result=$?
  if [ $result -eq 0 ]; then
    remote_log "${component} ${action} completed successfully"
  else
    remote_log "${component} ${action} failed with code ${result}"
  fi
  
  return $result
}


## NODE Functions

refresh_node_functions() {
  local provisioning_node
  local functions_url
  
  # Get the provisioning node IP
  provisioning_node=$(get_provisioning_node)
  
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






# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process through the local system config file."
  return 1
}

get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}

load_remote_host_config() {
  local conf
  local gateway="$(get_provisioning_node)"
  conf="$(curl -fsSL "http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_get_config")" || {
    remote_log "Failed to load host config"
    return 1
  }
  # Optional debug
  remote_log "Remote config: $conf"
  eval "$conf"
}

# url_encode
# ----------
# Percent-encode a string for safe inclusion in URL query parameters.
# Encodes all non [A-Za-z0-9.~_-] bytes, including spaces and newlines.
#
# Usage:
#   enc="$(url_encode "value with spaces & symbols")"
#
# Inputs:
#   $1  Unencoded string
#
# Outputs:
#   stdout: encoded string
#
# Returns:
#   0 on success
url_encode() {
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


# remote_host_variable
# --------------------
# Get or set a host variable on the provisioning node.
# Uses cmd=host_variable&name=<name>[&value=<value>]
#
# Usage:
#   remote_host_variable <name> <value>   # set
#   remote_host_variable <name>           # get
#
# Inputs:
#   $1  name   (string; required)
#   $2  value  (string; optional; if provided, will set)
#
# Env/Deps:
#   get_provisioning_node  -> returns <ip-or-hostname> of provisioning node
#   url_encode             -> percent-encodes parameters
#
# Outputs:
#   stdout: server response (get: raw value; set: success/fail message)
#
# Returns:
#   curl exit status (0 on success)
remote_host_variable() {
  local name="${1:?Usage: remote_host_variable <name> [<value>]}"
  local value="${2-}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1

  local enc_name enc_value url
  enc_name="$(url_encode "$name")"

  if [[ -n "$2" ]]; then
    enc_value="$(url_encode "$value")"
    url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_variable&name=${enc_name}&value=${enc_value}"
  else
    url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_variable&name=${enc_name}"
  fi

  curl -fsS -X POST "$url"
}


# remote_cluster_variable
# -----------------------
# Get or set a cluster variable on the provisioning node.
# Uses cmd=cluster_variable&name=<name>[&value=<value>]
#
# Usage:
#   remote_cluster_variable <name> <value>   # set
#   remote_cluster_variable <name>           # get
#
# Outputs: server response to stdout
# Returns: curl exit status (0 on success)
remote_cluster_variable() {
  local name="${1:?Usage: remote_cluster_variable <name> [<value>]}"
  local value="${2-}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1

  local enc_name enc_value
  enc_name="$(url_encode "$name")"

  if [[ $# -ge 2 ]]; then
    # SET: POST with value
    enc_value="$(url_encode "$value")"
    curl -fsS -X POST \
      "http://${gateway}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=${enc_name}&value=${enc_value}"
  else
    # GET: GET without value param
    curl -fsS -X GET \
      "http://${gateway}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=${enc_name}"
  fi
}



# remote_log (refactor to reuse url_encode) — optional
remote_log() {
  local message="${1:?Usage: remote_log <message>}"
  local function="${FUNCNAME[1]}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1
  local enc_message
  enc_message="$(url_encode "$message")"
  local enc_funct
  enc_function="$(url_encode "$function")"
  curl -fsS -X POST "http://${gateway}/cgi-bin/boot_manager.sh?cmd=log_message&message=${enc_message}&function=${enc_function}"
}




