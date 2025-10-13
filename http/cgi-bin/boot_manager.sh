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

# Condition: is this fresh boot?
if [[ "$cmd" == "init" ]]; then
  hps_log info "[$mac] iPXE Initialisation requested from DHCP"
  
  # Check if this is a network boot host
  # Use 'get' with a default value or handle the case where key doesn't exist
  state=$(host_config "$mac" get STATE 2>/dev/null) || state=""
  
  # Log the retrieved state for debugging
  hps_log debug "Retrieved STATE for MAC ${mac}: '${state}'"
  
  # Check for network boot state
  if [[ "${state}" == "NETWORK_BOOT" ]]; then
    hps_log info "Network boot requested for MAC ${mac} (STATE=${state})"
    ipxe_network_boot "$mac"
    exit 0
  fi
  
  # Any other state value (including empty/undefined)
  if [[ -n "${state}" ]]; then
    hps_log info "Host MAC ${mac} has STATE=${state}, running standard init"
  else
    hps_log info "Host MAC ${mac} has no STATE defined, running standard init"
  fi
  
  ipxe_init
  exit 0
fi



# Command: Get TCH apkovol
if [[ "$cmd" == "get_tch_apkovol" ]]; then
  hps_log info "Generating Alpine apkovol"
  tch_apkovol_create
  exit 0
fi



# Command: Handle a keysafe token request
if [[ "$cmd" == "keysafe_request_token" ]]; then
    purpose=$(cgi_param get purpose)
    token=$(keysafe_handle_token_request "$mac" "$purpose")
    cgi_header_plain
    echo "$token"
    exit 0  # <- ADD THIS
fi

# Command: Get alpine bootstrap 
if [[ "$cmd" == "get_alpine_bootstrap" ]]; then
  cgi_header_plain
  hps_log info "Generating Alpine bootstrap"
  
  stage="initramfs"
  if cgi_param exists stage; then
    stage="$(cgi_param get stage)"
  fi
  
  if ! get_alpine_bootstrap "$stage" ; then
    cgi_fail "Failed to generate bootstrap: get_alpine_bootstrap exited nonzero"
  fi
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


# --- Command: get or set host variables (receiver side) ---
# cmd=host_variable&name=<name>[&value=<value>]
# - Requires: name
# - If 'value' param exists (even empty) -> set name=value, return success
# - If 'value' param missing            -> get current value, return it
if [[ "$cmd" == "host_variable" ]]; then
  if ! cgi_param exists name; then cgi_auto_fail "Param 'name' is required"; exit; fi
  name="$(cgi_param get name)"

  if cgi_param exists value; then
    # SET path
    value="$(cgi_param get value)"
    if host_config "$mac" set "$name" "$value" >/dev/null 2>&1; then
      cgi_success "$mac set $name to $value"
    else
      cgi_auto_fail "set failed"
    fi
  else
    # GET path — call 'get' directly and trust its rc
    val=""
    if val="$(host_config "$mac" get "$name" 2>/dev/null)"; then
      cgi_success "$val"
    else
      cgi_auto_fail "Key '$name' not found"
    fi
  fi
  exit
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


# Command: Network bootstrap via kickstart
if [[ "$cmd" == "kickstart" ]]; then
  if ! cgi_param exists hosttype; then
    cgi_auto_fail "Param hosttype is required for kickstart"
  fi
  hosttype="$(cgi_param get hosttype)"
  hps_log info "Kickstart - Configuring host $hosttype"
  host_network_configure "$mac" "$hosttype"
  generate_ks "$mac" "$hosttype"
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


# Command: get the distro bootstrap script - renaming it to node_load_functions and supporting both for now
if [[ "$cmd" == "node_bootstrap_functions" ]]; then
  hps_log info "Node requests to bootstrap node functions"
  cgi_header_plain
  bootstrap_initialise_functions "$mac"
  hps_log info "Running queue on node"
  echo "n_queue_run"
  exit
fi

# Command: get the node function library appropriate for this distro
if [[ "$cmd" == "node_get_functions" ]]; then
  cgi_header_plain
    if cgi_param exists distro; then
      DISTRO="$(cgi_param get distro)"
      hps_log info "Node requests function lib for $DISTRO"
      node_get_functions "${DISTRO}"
  else
    cgi_auto_fail "$cmd: Parameter distro not provided"
  fi
  exit
fi

# Command: Generate an opensvc conf
if [[ "$cmd" == "generate_opensvc_conf" ]]; then
  hps_log info "Request to generate opensvc.conf"
  cgi_header_plain
  generate_opensvc_conf "$mac"
  exit
fi


# ----------------------

# Router: Decide what to do next
if [[ "$cmd" == "boot_action" ]]
 then
  hps_log info "Host wants to know what to do next"
  if host_config_exists "$mac"
   then
    hps_log info "Found config"
   else
    hps_log info "No config found, initialising"
    host_initialise_config "$mac"
  fi
  state="$(host_config "$mac" get STATE)"
  hps_log info "STATE: $state"

  case "$state" in
    UNCONFIGURED)
      hps_log info "Unconfigured — offering install options."
      ipxe_configure_main_menu
      ;;

    CONFIGURED)
      hps_log info "Configured — offering install options."
      # establish type and o/s from config and cluster, then go to install that
      ipxe_host_install_menu
      ;;

    INSTALLED)
      hps_log info "Already installed. Booting from disk."
      ipxe_boot_from_disk
      exit
      ;;

    UNMANAGED)
      hps_log info "Device set to UNMANAGED, booting from disk"
      ipxe_boot_from_disk
      exit
      ;;

    INSTALLING)
      hps_log info "Currently installing. Continuing install."
      HTYPE=$(host_config "$mac" get TYPE)
      hps_log debug "[$mac] Installing TYPE: $HTYPE"
      ipxe_boot_installer "$HTYPE" ""
      ;;

    ACTIVE)
#      hps_log info "Active and provisioned. Booting configured image."
#      ipxe_boot_provisioned
      cgi_auto_fail "Section not yet written for state $state"
      ;;

    REINSTALL)
#      hps_log info "Reinstall requested. Returning to install menu."
#      ipxe_host_install_menu
      host_config "$mac" set STATE UNCONFIGURED
      ipxe_init
      ;;

    FAILED)
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



