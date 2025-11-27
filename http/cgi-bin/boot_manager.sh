#!/bin/bash
set -euo pipefail

# read HPS config
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

mac="$(hps_origin_tag)"

# Retrieve config file name of the cluster
CLUSTER_FILE=$(get_active_cluster_filename) || {
  cgi_auto_fail "No active cluster"
  exit 1
}

### ───── Ensure command is present else fail fast ─────

if ! cgi_param exists cmd; then
  cgi_auto_fail "Command not specified"
  exit 1
fi
cmd="$(cgi_param get cmd)"


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
  storage_index=$(cgi_require_param index)
  result=$(ips_allocate_storage_ip "$storage_index" "$mac")
  echo "$result"
  exit 0
fi


# Command: Handle a keysafe token request
if [[ "$cmd" == "keysafe_request_token" ]]; then
  purpose=$(cgi_require_param purpose)
  token=$(keysafe_handle_token_request "$mac" "$purpose")
  cgi_header_plain
  echo "$token"
  exit 0
fi


# Command: osvc_cmd
if [[ "$cmd" == "osvc_cmd" ]]; then
  #TODO: add param validation
  osvc_cmd=$(cgi_require_param osvc_cmd)
  cgi_header_plain
  osvc_process_commands "${osvc_cmd}"
  exit 0
fi


# Command: set status
if [[ "$cmd" == "set_status" ]]; then
  SET_STATUS="$(cgi_require_param status)"
  host_config "$mac" set STATE "$SET_STATUS"
  cgi_success "$mac set to $SET_STATUS"
  exit 0
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
  var_name="$(cgi_require_param name)"
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


#===============================================================================
# cluster_variable command handler
# --------------------------------
# Get or set cluster variables via CGI interface.
#
# Parameters (via CGI):
#   cmd=cluster_variable
#   name=<variable_name>     (required)
#   value=<variable_value>   (optional - if present, sets the value)
#
# Behaviour:
#   - If 'value' param exists (even empty): SET operation
#   - If 'value' param missing: GET operation
#
# Example usage:
#   GET:  curl "http://ips/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=DHCP_IP"
#   SET:  curl "http://ips/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=DHCP_IP&value=10.0.0.1"
#
#===============================================================================
if [[ "$cmd" == "cluster_variable" ]]; then
  # Ensure dynamic paths are exported so cluster_config points at active cluster
  type export_dynamic_paths >/dev/null 2>&1 && export_dynamic_paths

  name="$(cgi_require_param name)"

  if cgi_param exists value; then
    # SET path
    value="$(cgi_param get value)"
    if cluster_config set "$name" "$value" >/dev/null 2>&1; then
      cgi_success "cluster set $name to $value"
      exit 0
    else
      cgi_auto_fail "cluster set failed"
      exit 1
    fi
  else
    # GET path
    if val="$(cluster_config get "$name" 2>/dev/null)"; then
      cgi_success "$val"
      exit 0
    else
      cgi_auto_fail "Cluster key '$name' not found"
      exit 1
    fi
  fi
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
  os_id="$(cgi_require_param os_id)"
  var_name="$(cgi_require_param name)"

  if ! os_config_exists "$os_id"; then
    cgi_auto_fail "OS '$os_id' not found"
    exit 1
  fi

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
  menu_item="$(cgi_require_param menu_item)"
  hps_log info "Processing ipxe menu item: $menu_item"
  handle_menu_item "$menu_item" "$mac"
  # Note: handle_menu_item manages its own exit/response
  exit 0
fi


# Command: write log entry
if [[ "$cmd" == "log_message" ]]; then
  LOG_MESSAGE="$(cgi_require_param message)"
  REMOTE_FUNCT=""
  if cgi_param exists function; then
    REMOTE_FUNCT="[$(cgi_param get function)] "
  fi
  cgi_header_plain
  hps_log info "${REMOTE_FUNCT}${LOG_MESSAGE}"
  exit 0
fi


# Command: Determine current state
if [[ "$cmd" == "determine_state" ]]; then
  hps_log info "Host wants to know its state"
  state="$(host_config "$mac" get STATE)"
  hps_log info "State: $state"
  cgi_success "$state"
  exit 0
fi


# Command: get the host config file
# TODO: deprecated / undesirable?
if [[ "$cmd" == "host_get_config" ]]; then
  hps_log info "Config requested"
  cgi_header_plain
  host_config_show $mac
  exit 0
fi


# Command: Configure this host
if [[ "$cmd" == "config_host" ]]; then
  hosttype="$(cgi_require_param hosttype)"
  host_config "$mac" set TYPE "$hosttype"
  cgi_success "$mac configured as $hosttype"
  exit 0
fi


# Command: host audit collection (generic)
if [[ "$cmd" == "host_audit" ]]; then
  host_audit="$(cgi_require_param data)"
  hps_log debug "Calling: process_host_audit: ${host_audit} "
  process_host_audit "$mac" "${host_audit}"
  exit 0
fi


# Command: Network bootstrap via kickstart
if [[ "$cmd" == "kickstart" ]]; then
  hosttype="$(host_config "$mac" get TYPE)"
  if [[ -z "${hosttype:-}" ]]; then
    cgi_auto_fail "Host TYPE not configured for kickstart"
    exit 1
  fi
  hps_log info "Kickstart - Configuring host $hosttype"
  generate_ks "$mac" "$hosttype"
  # Note: generate_ks outputs kickstart content directly
  exit 0
fi


# Command: Get remote node functions
if [[ "$cmd" == "get_remote_functions" ]]; then
  cgi_header_plain
  
  if [[ -z "$mac" ]]; then
    cgi_auto_fail "$cmd: Could not determine requesting node MAC"
    exit 1
  fi
  
  if ! hps_get_remote_functions; then
    cgi_auto_fail "$cmd: Failed to generate function bundle for MAC $mac"
    exit 1
  fi
  
  exit 0
fi


# Command: Get installer functions
if [[ "$cmd" == "get_installer_functions" ]]; then
  hps_log debug "Request for get_installer_functions"
  cgi_header_plain
  
  type=$(host_config "$mac" get TYPE)
  hps_log debug "---  get_installer_functions for mac $mac"
  os_id=$(host_config "$mac" get os_id)
  osname=$(get_os_name $os_id)

  installer_func_file="${LIB_DIR}/host-installer/${osname}/installer-functions.sh"
  hps_log debug "Request for get_installer_functions from $installer_func_file"
  
  if [[ -f "$installer_func_file" ]]; then
    hps_log info "get_installer_functions Serving installer functions: $installer_func_file"
    cat "$installer_func_file"
    exit 0
  else
    hps_log error "get_installer_functions Installer functions not found: $installer_func_file"
    cgi_auto_fail "ERROR: Installer functions not found for ${osname}-${type}"
    exit 1
  fi
fi


# Command: Get the bootstrap functions
# DEPRECATED: use get_remote_functions
if [[ "$cmd" == "node_get_bootstrap_functions" ]]; then
  hps_log warn "DEPRECATED: node_get_bootstrap_functions - use get_remote_functions"
  cgi_header_plain
  hps_log info "Streaming create_bootstrap_core_lib"
  create_bootstrap_core_lib
  exit 0
fi


# Command: get the node function library appropriate for this distro
# DEPRECATED: use get_remote_functions
if [[ "$cmd" == "node_get_functions" ]]; then
  hps_log warn "DEPRECATED: node_get_functions - use get_remote_functions"
  cgi_header_plain
  DISTRO="$(cgi_require_param distro)"
  hps_log info "Node requests function lib for $DISTRO"
  node_build_functions "${DISTRO}"
  exit 0
fi


# Command: init - iPXE boot initialisation
if [[ "$cmd" == "init" ]]; then
  ipxe_init_handler "$mac"
  exit $?
fi


### ───── Unknown or unhandled command ─────

cgi_auto_fail "Unknown or unsupported command: $cmd"
exit 1
