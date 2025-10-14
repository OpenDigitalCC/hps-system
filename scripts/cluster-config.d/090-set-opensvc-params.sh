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
  ["OSVC_LOG_LEVEL"]="info"
  ["OSVC_LISTENER_PORT"]="1215"
  ["OSVC_WEB_UI"]="yes"
  ["OSVC_WEB_PORT"]="1214"
  ["OSVC_HB_INTERVAL"]="5"
  ["OSVC_HB_TIMEOUT"]="15"
  ["OSVC_TEMPLATES_URL"]=""
  ["OSVC_PACKAGES_URL"]=""
  ["OSVC_HB_TYPE"]="multicast"
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
  echo "Log Level:          ${current_values[OSVC_LOG_LEVEL]}"
  echo "Listener Port:      ${current_values[OSVC_LISTENER_PORT]}"
  echo "Web UI Enabled:     ${current_values[OSVC_WEB_UI]}"
  echo "Web UI Port:        ${current_values[OSVC_WEB_PORT]}"
  echo "Heartbeat Interval: ${current_values[OSVC_HB_INTERVAL]} seconds"
  echo "Heartbeat Timeout:  ${current_values[OSVC_HB_TIMEOUT]} seconds"
  echo "Templates URL:      ${current_values[OSVC_TEMPLATES_URL]:-<none>}"
  echo "Packages URL:       ${current_values[OSVC_PACKAGES_URL]:-<none>}"
  echo "Heartbeat Type:     ${current_values[OSVC_HB_TYPE]}"
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
  echo "Log Level:          ${osvc_defaults[OSVC_LOG_LEVEL]}"
  echo "Listener Port:      ${osvc_defaults[OSVC_LISTENER_PORT]}"
  echo "Web UI Enabled:     ${osvc_defaults[OSVC_WEB_UI]}"
  echo "Web UI Port:        ${osvc_defaults[OSVC_WEB_PORT]}"
  echo "Heartbeat Interval: ${osvc_defaults[OSVC_HB_INTERVAL]} seconds"
  echo "Heartbeat Timeout:  ${osvc_defaults[OSVC_HB_TIMEOUT]} seconds"
  echo "Templates URL:      ${osvc_defaults[OSVC_TEMPLATES_URL]:-<none>}"
  echo "Packages URL:       ${osvc_defaults[OSVC_PACKAGES_URL]:-<none>}"
  echo "Heartbeat Type:     ${osvc_defaults[OSVC_HB_TYPE]}"
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
log_level=$(cli_prompt "Log level (debug/info/warn/error)" "${current_values[OSVC_LOG_LEVEL]}" \
  "^(debug|info|warn|error)$" "Invalid log level")
CLUSTER_CONFIG_PENDING+=("OSVC_LOG_LEVEL:$log_level")

# Listener Port
listener_port=$(cli_prompt "Listener port (1024-65535)" "${current_values[OSVC_LISTENER_PORT]}" \
  "^([1-9][0-9]{3,4})$" "Invalid port number")
if [[ $listener_port -lt 1024 ]] || [[ $listener_port -gt 65535 ]]; then
  hps_log "error" "Port must be between 1024 and 65535"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("OSVC_LISTENER_PORT:$listener_port")

# Web UI
current_web_ui=$([[ "${current_values[OSVC_WEB_UI]}" == "yes" ]] && echo "y" || echo "n")
web_ui=$(cli_prompt_yesno "Enable Web UI?" "$current_web_ui")
if [[ "$web_ui" == "y" ]]; then
  CLUSTER_CONFIG_PENDING+=("OSVC_WEB_UI:yes")
  
  # Web Port (only if UI enabled)
  web_port=$(cli_prompt "Web UI port (1024-65535)" "${current_values[OSVC_WEB_PORT]}" \
    "^([1-9][0-9]{3,4})$" "Invalid port number")
  if [[ $web_port -lt 1024 ]] || [[ $web_port -gt 65535 ]]; then
    hps_log "error" "Port must be between 1024 and 65535"
    return 1
  fi
  if [[ $web_port -eq $listener_port ]]; then
    hps_log "error" "Web port cannot be the same as listener port"
    return 1
  fi
  CLUSTER_CONFIG_PENDING+=("OSVC_WEB_PORT:$web_port")
else
  CLUSTER_CONFIG_PENDING+=("OSVC_WEB_UI:no")
  CLUSTER_CONFIG_PENDING+=("OSVC_WEB_PORT:${current_values[OSVC_WEB_PORT]}")
fi

# Heartbeat Interval
hb_interval=$(cli_prompt "Heartbeat interval in seconds (1-60)" "${current_values[OSVC_HB_INTERVAL]}" \
  "^[1-9][0-9]?$" "Invalid interval")
if [[ $hb_interval -gt 60 ]]; then
  hps_log "error" "Heartbeat interval must be 60 seconds or less"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("OSVC_HB_INTERVAL:$hb_interval")

# Heartbeat Timeout
hb_timeout=$(cli_prompt "Heartbeat timeout in seconds (5-300)" "${current_values[OSVC_HB_TIMEOUT]}" \
  "^[1-9][0-9]*$" "Invalid timeout")
if [[ $hb_timeout -lt 5 ]] || [[ $hb_timeout -gt 300 ]]; then
  hps_log "error" "Heartbeat timeout must be between 5 and 300 seconds"
  return 1
fi
if [[ $hb_timeout -le $hb_interval ]]; then
  hps_log "error" "Heartbeat timeout must be greater than interval"
  return 1
fi
CLUSTER_CONFIG_PENDING+=("OSVC_HB_TIMEOUT:$hb_timeout")

# Templates URL (optional)
cli_note "Leave blank to use default OpenSVC templates"
templates_url=$(cli_prompt "Templates URL" "${current_values[OSVC_TEMPLATES_URL]}" "" "")
CLUSTER_CONFIG_PENDING+=("OSVC_TEMPLATES_URL:$templates_url")

# Packages URL (optional)
cli_note "Leave blank to use default OpenSVC packages"
packages_url=$(cli_prompt "Packages URL" "${current_values[OSVC_PACKAGES_URL]}" "" "")
CLUSTER_CONFIG_PENDING+=("OSVC_PACKAGES_URL:$packages_url")

# Heartbeat Type
hb_type=$(cli_prompt "Heartbeat type (multicast/unicast)" "${current_values[OSVC_HB_TYPE]}" \
  "^(multicast|unicast)$" "Invalid heartbeat type")
CLUSTER_CONFIG_PENDING+=("OSVC_HB_TYPE:$hb_type")

cli_info "OpenSVC parameters configured"
