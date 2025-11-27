#!/bin/bash
set -euo pipefail

# read HPS config
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

#client_ip="${REMOTE_ADDR:-}"
#mac="$(get_client_mac "${REMOTE_ADDR}")"
mac="$(hps_origin_tag)"

# Retrieve config file name of the cluster
CLUSTER_FILE=$(get_active_cluster_filename) || {
  cgi_auto_fail "No active cluster"
  exit 1
}

### ───── Ensure command is present else fail fast ─────

# Condition: do we have $cmd
if ! cgi_param exists cmd; then
  cgi_auto_fail "Command not specified"
  exit
else
  cmd="$(cgi_param get cmd)"
fi


# Command: Get TCH apkovol
if [[ "$cmd" == "get_tch_apkovol" ]]; then
  hps_log info "Generating Alpine apkovol"
  tch_apkovol_create
  exit 0
fi


# Command: host_allocate_networks
if [[ "$cmd" == "host_allocate_networks" ]]; then
  hps_log info "Allocating networks for remote host"
  cgi_header_plain
  storage_index=$(cgi_param get index)
  result=$(ips_allocate_storage_ip "$storage_index" "$mac")
  echo "$result"
  exit 0
fi


# Command: Handle a keysafe token request
if [[ "$cmd" == "keysafe_request_token" ]]; then
    purpose=$(cgi_param get purpose)
    token=$(keysafe_handle_token_request "$mac" "$purpose")
    cgi_header_plain
    echo "$token"
    exit 0
fi

if [[ "$cmd" == "osvc_cmd" ]]; then
  #TODO: add param validation
  osvc_cmd=$(cgi_param get osvc_cmd)
  cgi_header_plain
  osvc_process_commands "${osvc_cmd}"
  exit 0
fi



# Command: set status
if [[ "$cmd" == "set_status" ]]
 then
  if ! cgi_param exists status
   then
    cgi_auto_fail "Param status is required for command $cmd"
    exit
  else
    SET_STATUS="$(cgi_param get status)"
  fi
  host_config "$mac" set STATE "$SET_STATUS"
  cgi_success "$mac set to $SET_STATUS"
  exit
fi



#===============================================================================
# host_variable command handler
# -----------------------------
# Get, set, or unset host configuration variables via CGI interface.
#
# Parameters (via CGI):
#   cmd=host_variable
#   name=<variable_name>     (required)
#   value=<variable_value>   (optional - if present, sets the value)
#   action=unset            (optional - removes the variable)
#
# Behaviour:
#   - If 'action=unset': DELETE operation
#   - If 'value' parameter exists (even if empty): SET operation
#   - If 'value' parameter is missing: GET operation
#   - Uses host_config function to manage the actual storage
#
# Returns:
#   - GET: Success with value if found, failure if key not found
#   - SET: Success message on update, failure on error
#   - UNSET: Success message on removal, failure on error
#
# Example usage:
#   GET:    curl "http://ips/cgi-bin/boot_manager.sh?cmd=host_variable&name=reboot_logging"
#   SET:    curl "http://ips/cgi-bin/boot_manager.sh?cmd=host_variable&name=reboot_logging&value=enabled"
#   UNSET:  curl "http://ips/cgi-bin/boot_manager.sh?cmd=host_variable&name=reboot_logging&action=unset"
#
#===============================================================================
if [[ "$cmd" == "host_variable" ]]; then
  # Validate required parameter
  if ! cgi_param exists name; then 
    cgi_auto_fail "Param 'name' is required"
    exit 1
  fi
  
  # Extract variable name
  var_name="$(cgi_param get name)"
  
  # Check for action parameter
  action="$(cgi_param get action || echo "")"
  
  if [[ "$action" == "unset" ]]; then
    # UNSET operation - remove the variable
    if host_config "$mac" unset "$var_name" >/dev/null 2>&1; then
      cgi_success "$mac unset $var_name"
      exit 0
    else
      cgi_auto_fail "Failed to unset $var_name"
      exit 1
    fi
  elif cgi_param exists value; then
    # SET operation - value parameter exists
    var_value="$(cgi_param get value)"
    
    # Attempt to set the host variable
    if host_config "$mac" set "$var_name" "$var_value" >/dev/null 2>&1; then
      cgi_success "$mac set $var_name to $var_value"
      exit 0
    else
      cgi_auto_fail "Failed to set $var_name"
      exit 1
    fi
  else
    # GET operation - no value parameter
    if current_value="$(host_config "$mac" get "$var_name" 2>/dev/null)"; then
      cgi_success "$current_value"
      exit 0
    else
      cgi_auto_fail "Key '$var_name' not found"
      exit 1
    fi
  fi
fi




# --- Command: get or set cluster variables (receiver side) ---
# cmd=cluster_variable&name=<name>[&value=<value>]
# - Requires: name
# - If 'value' param exists (even empty) -> set name=value, return success
# - If 'value' param missing            -> get current value, return it
if [[ "$cmd" == "cluster_variable" ]]; then
  # Ensure dynamic paths are exported so cluster_config points at active cluster
  type export_dynamic_paths >/dev/null 2>&1 && export_dynamic_paths

  if ! cgi_param exists name; then
    cgi_auto_fail "Param 'name' is required"
    exit
  fi

  name="$(cgi_param get name)"

  if cgi_param exists value; then
    # SET path
    value="$(cgi_param get value)"
    if cluster_config set "$name" "$value" >/dev/null 2>&1; then
      cgi_success "cluster set $name to $value"
    else
      cgi_auto_fail "cluster set failed"
    fi
  else
    # GET path — rely on 'get' rc, no separate 'exists'
    if val="$(cluster_config get "$name" 2>/dev/null)"; then
      cgi_success "$val"
    else
      cgi_auto_fail "Cluster key '$name' not found"
    fi
  fi
  exit
fi



#===============================================================================
# os_variable command handler
# ---------------------------
# Get OS configuration variables via CGI interface.
#
# Parameters (via CGI):
#   cmd=os_variable
#   os_id=<os_identifier>    (required, e.g., "x86_64:alpine:3.20")
#   name=<key_name>          (required)
#
# Behaviour:
#   - Validates os_id parameter exists
#   - Validates name parameter exists
#   - Checks OS section exists in registry
#   - Returns value for the specified key
#
# Returns:
#   - Success with value if found
#   - Failure if parameters missing, OS not found, or key not found
#
# Example usage:
#   curl "http://ips/cgi-bin/boot_manager.sh?cmd=os_variable&os_id=x86_64:alpine:3.20&name=repo_path"
#
#===============================================================================
if [[ "$cmd" == "os_variable" ]]; then
  # Validate required parameters
  if ! cgi_param exists os_id; then
    cgi_auto_fail "Param 'os_id' is required"
    exit 1
  fi

  if ! cgi_param exists name; then
    cgi_auto_fail "Param 'name' is required"
    exit 1
  fi

  # Extract parameters
  os_id="$(cgi_param get os_id)"
  var_name="$(cgi_param get name)"

  # Check OS section exists
  if ! os_config_exists "$os_id"; then
    cgi_auto_fail "OS '$os_id' not found"
    exit 1
  fi

  # Attempt to get the value
  if current_value="$(os_config_get "$os_id" "$var_name" 2>/dev/null)"; then
    cgi_success "$current_value"
    exit 0
  else
    cgi_auto_fail "Key '$var_name' not found for OS '$os_id'"
    exit 1
  fi
fi


# Command: Process ipxe menu

if [[ "$cmd" == "process_menu_item" ]]; then
  if ! cgi_param exists menu_item; then
    cgi_auto_fail "Missing required parameter: menu_item"
    exit
  fi
  menu_item="$(cgi_param get menu_item)"
  hps_log info "Processing ipxe menu item: $menu_item"
  handle_menu_item "$menu_item" "$mac"
  exit
fi


# Command: write log entry
if [[ "$cmd" == "log_message" ]]
 then
  REMOTE_FUNCT=""
  if ! cgi_param exists message
   then
    cgi_auto_fail "Param message is required for command $cmd"
  else
    if cgi_param exists function
     then
    REMOTE_FUNCT="[$(cgi_param get function)] "
    fi
    LOG_MESSAGE="$(cgi_param get message)"
    cgi_header_plain
  fi
  hps_log info "${REMOTE_FUNCT}${LOG_MESSAGE}"
  exit
fi


# Command: Determine current state
if [[ "$cmd" == "determine_state" ]]; then
  hps_log info "Host wants to know its state"
  state="$(host_config "$mac" get STATE)"
  hps_log info "State: $state"
  cgi_success "$state"
  exit
fi


# get the host config file
# TODO: deprecated / undesirable?
if [[ "$cmd" == "host_get_config" ]]; then
  hps_log info "Config requested"
  cgi_header_plain
  host_config_show $mac
  exit
fi

# Command: Configure this host

if [[ "$cmd" == "config_host" ]]; then
  if ! cgi_param exists hosttype; then
    cgi_auto_fail "hosttype is required for config_host"
  fi
  hosttype="$(cgi_param get hosttype)"
  host_config "$mac" set TYPE "$hosttype"
  exit
fi


# Command: host audit collection (generic)
if [[ "$cmd" == "host_audit" ]]; then
  if ! cgi_param exists data; then
    cgi_auto_fail "Param data is required for command $cmd"
  else
    host_audit="$(cgi_param get data)"
    # Pass to processing function
    hps_log debug "Calling: process_host_audit: ${host_audit} "
    process_host_audit "$mac" "${host_audit}"
#    cgi_header_plain
  fi
  exit
fi


# Command: Network bootstrap via kickstart
if [[ "$cmd" == "kickstart" ]]; then
  hosttype="$(host_config "$mac" get TYPE)"
  if [[ -z "${hosttype:-}" ]]; then
    cgi_auto_fail "Param hosttype is required for kickstart"
  fi
  hps_log info "Kickstart - Configuring host $hosttype"
#  host_network_configure "$mac" "$hosttype"
  generate_ks "$mac" "$hosttype"
  exit
fi


# Command: Get remote node functions
if [[ "$cmd" == "get_remote_functions" ]]; then
  cgi_header_plain
  
  # $mac already set by CGI framework via hps_origin_tag
  if [[ -z "$mac" ]]; then
    cgi_auto_fail "$cmd: Could not determine requesting node MAC"
    exit 1
  fi
  
  # Generate function bundle
  if ! hps_get_remote_functions ; then
    cgi_auto_fail "$cmd: Failed to generate function bundle for MAC $mac"
    exit 1
  fi
  
  exit 0
fi


# Command: Get installer functions
if [[ "$cmd" == "get_installer_functions" ]]; then
  hps_log debug "Request for get_installer_functions"
  cgi_header_plain
  # Determine OS and TYPE from host config
  type=$(host_config "$mac" get TYPE)
  hps_log debug "---  get_installer_functions for mac $mac"
  os_id=$(host_config "$mac" get os_id)
  osname=$(get_os_name $os_id)

  # Path to installer functions
  installer_func_file="${LIB_DIR}/host-installer/${osname}/installer-functions.sh"
  hps_log debug "Request for get_installer_functions from $installer_func_file"
  
  if [[ -f "$installer_func_file" ]]; then
    hps_log info "get_installer_functions Serving installer functions: $installer_func_file"
    cat "$installer_func_file"
  else
    hps_log error "get_installer_functions Installer functions not found: $installer_func_file"
    cgi_auto_fail "ERROR: Installer functions not found for ${osname}-${type}"
    exit 1
  fi
  
  exit 0
fi


# deprecated by get_remote_functions?
# Command: Get the bootstrap functions, which allow the fullfunction lib to be downloaded
if [[ "$cmd" == "node_get_bootstrap_functions" ]]; then
  cgi_header_plain
  hps_log info "Streaming create_bootstrap_core_lib"
  # Stream the lib
  create_bootstrap_core_lib
  exit 0
fi

# deprecated by get_remote_functions?
# Command: get the node function library appropriate for this distro
if [[ "$cmd" == "node_get_functions" ]]; then
  cgi_header_plain
  
  # Check if distro parameter exists
  if ! cgi_param exists distro; then
    cgi_auto_fail "$cmd: Parameter 'distro' not provided"
    exit 1
  fi
  
  # Get distro value
  DISTRO="$(cgi_param get distro)"
  
  # Validate distro is not empty
  if [[ -z "$DISTRO" ]]; then
    cgi_auto_fail "$cmd: Parameter 'distro' is empty"
    exit 1
  fi
  
  # Log and generate function library
  hps_log info "Node requests function lib for $DISTRO"
  node_build_functions "${DISTRO}"
  exit 0
fi



# ---------------------- Router  based on state


# Condition: is this fresh boot?
# this is the link passed from dhcp - all hosts start here
if [[ "$cmd" == "init" ]]; then
  hps_log info "[$mac] iPXE Initialisation requested from DHCP client"

# hard-coded for now until we can audit to detect running arch
  ARCH="x86_64"

  if host_config_exists "$mac"
   then
    hps_log info "Found config for $mac"
   else
    hps_log info "No config found, initialising"
    host_initialise_config "$mac" "$ARCH"
  fi

  state=$(host_config "$mac" get STATE 2>/dev/null) || state=""

  rescue=$(host_config "$mac" get RESCUE 2>/dev/null) || rescue=""

  if [[ "$rescue" == "true" ]]; then
    hps_log info "RESCUE mode active for MAC $mac, forcing network boot"
    ipxe_network_boot "$mac"
    return 0
  fi

  hps_log info "Node STATE: $state"

  case "$state" in
  
    NETWORK_BOOT)
      hps_log info "State: $state requested for MAC ${mac}"
      ipxe_network_boot "$mac"
      ;;  
  
    UNCONFIGURED)
      hps_log info "State: $state - offering configure options."
      ipxe_configure_main_menu
      ;;

    CONFIGURED)
      hps_log info "State: $state - offering install options."
      # establish type and o/s from config and cluster, then go to install that
      ipxe_host_install_menu
      ;;

    INSTALLED|DISK_BOOT|UNMANAGED)
      hps_log info "State: $state - Booting from disk."
      ipxe_boot_from_disk
      exit
      ;;

    INSTALLING)
      hps_log info "State: $state - Continuing install."
      ipxe_boot_installer "$mac"
      ;;

    REINSTALL)
      hps_log info "Unconfiguring host"
      host_config "$mac" set STATE UNCONFIGURED
      ipxe_goto_menu init_menu
      ;;

    FAILED|INSTALL_FAILED)
      hps_log info "Install failed"
      ipxe_configure_main_menu
#      cgi_auto_fail "Installation marked as FAILED"
    ;;

    *)
      hps_log info "Unknown or unset state. Failing.."
      cgi_auto_fail "State $state unknown or unhandled"
      ;;
  esac

  exit
fi




### ───── Unknown or unhandled command ─────

cgi_auto_fail "Unknown or unsupported command: $cmd"



