#!/bin/bash
#===============================================================================
# 060-opensvc-parameters.sh
# -------------------------
# Configuration fragment to set OpenSVC cluster parameters
#
# Behaviour:
#   - Shows current OpenSVC configuration if exists
#   - Shows all default OpenSVC parameters
#   - Optionally allows customization of each parameter
#   - Validates parameter values
#
# Environment:
#   - Appends to CLUSTER_CONFIG_PENDING array
#===============================================================================

cli_info "Configure OpenSVC parameters" "OpenSVC Configuration"

# Define defaults
declare -A osvc_defaults=(
  ["osvc_log_level"]="info"
  ["osvc_listener_port"]="1215"
  ["osvc_web_ui"]="yes"
  ["osvc_web_port"]="1214"
  ["osvc_hb_interval"]="5"
  ["osvc_hb_timeout"]="15"
  ["osvc_templates_url"]=""
  ["osvc_packages_url"]=""
  ["osvc_hb_type"]="unicast"
)

# Get current values
declare -A current_values
for key in "${!osvc_defaults[@]}"; do
  current_values[$key]=$(config_get_value "$key" "${osvc_defaults[$key]}")
done

# Check if configuration exists (different from defaults)
config_exists=false
for key in "${!osvc_defaults[@]}"; do
  if [[ "${current_values[$key]}" != "${osvc_defaults[$key]}" ]]; then
    config_exists=true
    break
  fi
done

# Display current configuration
if [[ "$config_exists" == "true" ]]; then
  cli_info "Current OpenSVC configuration:"
  echo "----------------------------"
  echo "Log Level:          ${current_values[osvc_log_level]}"
  echo "Listener Port:      ${current_values[osvc_listener_port]}"
  echo "Web UI Enabled:     ${current_values[osvc_web_ui]}"
  echo "Web UI Port:        ${current_values[osvc_web_port]}"
  echo "Heartbeat Interval: ${current_values[osvc_hb_interval]} seconds"
  echo "Heartbeat Timeout:  ${current_values[osvc_hb_timeout]} seconds"
  echo "Templates URL:      ${current_values[osvc_templates_url]:-<none>}"
  echo "Packages URL:       ${current_values[osvc_packages_url]:-<none>}"
  echo "Heartbeat Type:     ${current_values[osvc_hb_type]}"
  echo
  
  if [[ $(cli_prompt_yesno "Keep current OpenSVC configuration?" "y") == "y" ]]; then
    # Re-add current configuration to pending
    for key in "${!current_values[@]}"; do
      CLUSTER_CONFIG_PENDING+=("${key}:${current_values[$key]}")
    done
    cli_info "Keeping current OpenSVC configuration"
    return 0
  fi
else
  # Show defaults
  echo "Default OpenSVC parameters:"
  echo "----------------------------"
  echo "Log Level:          ${osvc_defaults[osvc_log_level]}"
  echo "Listener Port:      ${osvc_defaults[osvc_listener_port]}"
  echo "Web UI Enabled:     ${osvc_defaults[osvc_web_ui]}"
  echo "Web UI Port:        ${osvc_defaults[osvc_web_port]}"
  echo "Heartbeat Interval: ${osvc_defaults[osvc_hb_interval]} seconds"
  echo "Heartbeat Timeout:  ${osvc_defaults[osvc_hb_timeout]} seconds"
  echo "Templates URL:      ${osvc_defaults[osvc_templates_url]:-<none>}"
  echo "Packages URL:       ${osvc_defaults[osvc_packages_url]:-<none>}"
  echo "Heartbeat Type:     ${osvc_defaults[osvc_hb_type]}"
  echo
fi

# Ask if changes needed
if [[ $(cli_prompt_yesno "Customize OpenSVC parameters?" "n") == "n" ]]; then
  # Use current values (which default to defaults if not set)
  for key in "${!current_values[@]}"; do
    CLUSTER_CONFIG_PENDING+=("${key}:${current_values[$key]}")
  done
  cli_info "Using OpenSVC parameters as shown"
  return 0
fi

# Customize parameters
cli_info "Customize OpenSVC parameters"

# Log Level
log_level=$(cli_prompt "Log level (debug/info/warn/error)" "${current_values[osvc_log_level]}" \
  "^(debug|info|warn|error)$" "Invalid log level")
CLUSTER_CONFIG_PENDING+=("osvc_log_level:$log_level")

# Listener Port
listener_port=$(cli_prompt "Listener port (1024-65535)" "${current_values[osvc_listener_port]}" \
  "^([1-9][0-9]{3,4})$" "Invalid port number")
if [[ $listener_port -lt 1024 ]] || [[ $listener_port -gt 65535 ]]; then
  hps_log "error" "Port must be between 1024 and 65535"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("osvc_listener_port:$listener_port")

# Web UI
current_web_ui=$([[ "${current_values[osvc_web_ui]}" == "yes" ]] && echo "y" || echo "n")
web_ui=$(cli_prompt_yesno "Enable Web UI?" "$current_web_ui")
if [[ "$web_ui" == "y" ]]; then
  CLUSTER_CONFIG_PENDING+=("osvc_web_ui:yes")
  
  # Web Port (only if UI enabled)
  web_port=$(cli_prompt "Web UI port (1024-65535)" "${current_values[osvc_web_port]}" \
    "^([1-9][0-9]{3,4})$" "Invalid port number")
  if [[ $web_port -lt 1024 ]] || [[ $web_port -gt 65535 ]]; then
    hps_log "error" "Port must be between 1024 and 65535"
    return 1
  fi
  if [[ $web_port -eq $listener_port ]]; then
    hps_log "error" "Web port cannot be the same as listener port"
    return 1
  fi
  CLUSTER_CONFIG_PENDING+=("osvc_web_port:$web_port")
else
  CLUSTER_CONFIG_PENDING+=("osvc_web_ui:no")
  CLUSTER_CONFIG_PENDING+=("osvc_web_port:${current_values[osvc_web_port]}")
fi

# Heartbeat Interval
hb_interval=$(cli_prompt "Heartbeat interval in seconds (1-60)" "${current_values[osvc_hb_interval]}" \
  "^[1-9][0-9]?$" "Invalid interval")
if [[ $hb_interval -gt 60 ]]; then
  hps_log "error" "Heartbeat interval must be 60 seconds or less"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("osvc_hb_interval:$hb_interval")

# Heartbeat Timeout
hb_timeout=$(cli_prompt "Heartbeat timeout in seconds (5-300)" "${current_values[osvc_hb_timeout]}" \
  "^[1-9][0-9]*$" "Invalid timeout")
if [[ $hb_timeout -lt 5 ]] || [[ $hb_timeout -gt 300 ]]; then
  hps_log "error" "Heartbeat timeout must be between 5 and 300 seconds"
  return 1
fi
if [[ $hb_timeout -le $hb_interval ]]; then
  hps_log "error" "Heartbeat timeout must be greater than interval"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("osvc_hb_timeout:$hb_timeout")

# Templates URL (optional)
cli_note "Leave blank to use default OpenSVC templates"
templates_url=$(cli_prompt "Templates URL" "${current_values[osvc_templates_url]}" "" "")
CLUSTER_CONFIG_PENDING+=("osvc_templates_url:$templates_url")

# Packages URL (optional)
cli_note "Leave blank to use default OpenSVC packages"
packages_url=$(cli_prompt "Packages URL" "${current_values[osvc_packages_url]}" "" "")
CLUSTER_CONFIG_PENDING+=("osvc_packages_url:$packages_url")

# Heartbeat Type
hb_type=$(cli_prompt "Heartbeat type (multicast/unicast)" "${current_values[osvc_hb_type]}" \
  "^(multicast|unicast)$" "Invalid heartbeat type")
CLUSTER_CONFIG_PENDING+=("osvc_hb_type:$hb_type")

cli_info "OpenSVC parameters configured"
