#!/bin/bash
#===============================================================================
# HPS API Client Functions
#===============================================================================
# Client-side functions for interacting with the HPS JSON API
# These functions are loaded on TCH/SCH nodes to communicate with the IPS
#
# Dependencies:
# - curl
# - jq
# - n_get_provisioning_node (to determine IPS address)
# - get_mac (to identify this node)
#===============================================================================

#===============================================================================
# Core API Functions
#===============================================================================

#===============================================================================
# n_api_call
# ----------
# Low-level function for making API calls to the IPS server.
#
# Usage:
#   n_api_call <endpoint> <json_data>
#
# Parameters:
#   $1 - API endpoint (e.g., "api.sh")
#   $2 - JSON request data
#
# Returns:
#   0 on success (outputs response)
#   1 - Invalid JSON input
#   2 - curl error
#   3 - Failed to extract HTTP code
#   4 - Non-2xx HTTP response
#
# Example:
#   response=$(n_api_call "api.sh" '{"action":"health"}')
#===============================================================================
n_api_call() {
  local endpoint="${1:?Usage: n_api_call <endpoint> <json_data>}"
  local json_data="${2:?}"
  local ips
  
  # Validate JSON
  if ! echo "$json_data" | jq . >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON for API call" >&2
    return 1
  fi
  
  # Get IPS address
  ips="$(n_get_provisioning_node)" || {
    echo "ERROR: Cannot determine IPS address" >&2
    return 1
  }
  
  # Get MAC address
  local mac
  mac=$(get_mac 2>/dev/null || echo "")
  
  # Build URL
  local url="http://${ips}/api/${endpoint}"
  
  # Make API call with detailed error capture
  local response
  local http_code
  local curl_output
  
  curl_output=$(curl -sS -w "\nHTTPCODE:%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-HPS-MAC: ${mac}" \
    -d "$json_data" \
    "$url" 2>&1)
  local curl_exit=$?
  
  if [[ $curl_exit -ne 0 ]]; then
    echo "ERROR: curl failed with exit $curl_exit for $url" >&2
    echo "$curl_output" >&2
    return 2
  fi
  
  # Extract HTTP code and response
  if [[ "$curl_output" =~ ^(.*)HTTPCODE:([0-9]+)$ ]]; then
    response="${BASH_REMATCH[1]}"
    http_code="${BASH_REMATCH[2]}"
  else
    echo "ERROR: Could not extract HTTP code from response" >&2
    echo "$curl_output" >&2
    return 3
  fi
  
  # Check HTTP status
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "ERROR: API returned HTTP $http_code" >&2
    echo "$response" >&2
    return 4
  fi
  
  # Output response
  echo "$response"
  return 0
}

#===============================================================================
# n_api_request
# -------------
# Simplified API request that handles common patterns and extracts data.
#
# Usage:
#   n_api_request <action> [key=value ...]
#
# Parameters:
#   $1 - API action
#   $2... - Optional key=value parameters
#
# Returns:
#   0 on success (outputs result data only)
#   Non-zero on error
#
# Example:
#   result=$(n_api_request "registry_get" "registry=host" "key=hostname")
#===============================================================================
n_api_request() {
  local action="${1:?Usage: n_api_request <action> [key=value ...]}"
  shift
  
  # Start building JSON
  local json="{\"action\": \"$action\""
  
  # Add MAC if available
  local mac
  mac=$(get_mac 2>/dev/null || echo "")
  if [[ -n "$mac" ]]; then
    json+=", \"mac\": \"$mac\""
  fi
  
  # Parse key=value parameters
  local param key value
  for param in "$@"; do
    if [[ "$param" =~ ^([^=]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      
      # Check if value is already valid JSON
      if echo "$value" | jq . >/dev/null 2>&1; then
        json+=", \"$key\": $value"
      else
        # Escape as JSON string
        value=$(echo -n "$value" | jq -Rs .)
        json+=", \"$key\": $value"
      fi
    fi
  done
  
  json+="}"
  
  # Make request
  local response
  if ! response=$(n_api_call "api.sh" "$json"); then
    return $?
  fi
  
  # Validate response is JSON
  if ! echo "$response" | jq . >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON response from API" >&2
    echo "$response" >&2
    return 5
  fi
  
  # Check for success
  if ! echo "$response" | jq -e '.success' >/dev/null 2>&1; then
    local error
    error=$(echo "$response" | jq -r '.error // "Unknown error"')
    local details
    details=$(echo "$response" | jq -r '.details // empty')
    
    if [[ -n "$details" ]]; then
      echo "ERROR: $error ($details)" >&2
    else
      echo "ERROR: $error" >&2
    fi
    return 6
  fi
  
  # Output data portion only
  echo "$response" | jq -r '.data // empty'
  return 0
}

#===============================================================================
# Registry Functions
#===============================================================================

#===============================================================================
# n_host_registry
# ---------------
# Perform registry operations on host data.
#
# Usage:
#   n_host_registry <operation> <key> [value]
#
# Operations:
#   get    - Retrieve value
#   set    - Store value (must be valid JSON)
#   delete - Remove key
#   list   - List all keys
#   view   - View all data as JSON object
#
# Examples:
#   n_host_registry set "config" '{"type":"SCH"}'
#   value=$(n_host_registry get "config")
#   n_host_registry delete "config"
#===============================================================================
n_host_registry() {
  local op="${1:?Usage: n_host_registry <get|set|delete|list|view> <key> [value]}"
  local key="${2:-}"
  local value="${3:-}"
  
  case "$op" in
    get|set|delete)
      [[ -z "$key" ]] && {
        echo "ERROR: Key required for $op operation" >&2
        return 1
      }
      ;;
  esac
  
  case "$op" in
    get)
      n_api_request "registry_get" "registry=host" "key=${key}"
      ;;
    set)
      [[ -z "$value" ]] && {
        echo "ERROR: Value required for set operation" >&2
        return 1
      }
      n_api_request "registry_set" "registry=host" "key=${key}" "value=${value}"
      ;;
    delete)
      n_api_request "registry_delete" "registry=host" "key=${key}"
      ;;
    list)
      n_api_request "registry_list" "registry=host"
      ;;
    view)
      n_api_request "registry_view" "registry=host"
      ;;
    *)
      echo "ERROR: Unknown operation: $op" >&2
      return 1
      ;;
  esac
}

#===============================================================================
# n_cluster_registry
# ------------------
# Perform registry operations on cluster data.
#
# Usage:
#   n_cluster_registry <operation> <key> [value]
#
# Operations: same as n_host_registry
#===============================================================================
n_cluster_registry() {
  local op="${1:?Usage: n_cluster_registry <get|set|delete|list|view> <key> [value]}"
  local key="${2:-}"
  local value="${3:-}"
  
  case "$op" in
    get|set|delete)
      [[ -z "$key" ]] && {
        echo "ERROR: Key required for $op operation" >&2
        return 1
      }
      ;;
  esac
  
  case "$op" in
    get)
      n_api_request "registry_get" "registry=cluster" "key=${key}"
      ;;
    set)
      [[ -z "$value" ]] && {
        echo "ERROR: Value required for set operation" >&2
        return 1
      }
      n_api_request "registry_set" "registry=cluster" "key=${key}" "value=${value}"
      ;;
    delete)
      n_api_request "registry_delete" "registry=cluster" "key=${key}"
      ;;
    list)
      n_api_request "registry_list" "registry=cluster"
      ;;
    view)
      n_api_request "registry_view" "registry=cluster"
      ;;
    *)
      echo "ERROR: Unknown operation: $op" >&2
      return 1
      ;;
  esac
}

#===============================================================================
# Legacy Compatibility Functions
#===============================================================================

#===============================================================================
# n_remote_host_variable
# ----------------------
# Get, set, or unset a host variable (backward compatible).
#
# Usage:
#   n_remote_host_variable <name>              # get
#   n_remote_host_variable <name> <value>      # set  
#   n_remote_host_variable <name> --unset      # delete
#
# This maintains compatibility with the existing interface while using
# the new API backend.
#===============================================================================
n_remote_host_variable() {
  local name="${1:?Usage: n_remote_host_variable <name> [value|--unset]}"
  local value="${2:-}"
  
  # Clear any previous error state
  N_IPS_COMMAND_LAST_ERROR=""
  N_IPS_COMMAND_LAST_RESPONSE=""
  
  local result
  local exit_code
  
  if [[ $# -eq 1 ]]; then
    # GET operation
    if result=$(n_api_request "host_variable" "name=${name}" 2>&1); then
      echo "$result"
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to get host variable: $result"
      # Check if it's a "not found" error
      if [[ "$result" =~ "not found" ]] || [[ "$result" =~ "404" ]]; then
        return 4  # Custom code for not found
      fi
      return $exit_code
    fi
  elif [[ "$value" == "--unset" ]]; then
    # UNSET operation
    if result=$(n_api_request "host_variable" "name=${name}" "operation=unset" 2>&1); then
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to unset host variable: $result"
      return $exit_code
    fi
  else
    # SET operation
    if result=$(n_api_request "host_variable" "name=${name}" "value=${value}" 2>&1); then
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to set host variable: $result"
      return $exit_code
    fi
  fi
}

#===============================================================================
# n_remote_cluster_variable
# -------------------------
# Get or set a cluster variable (backward compatible).
#
# Usage:
#   n_remote_cluster_variable <name>         # get
#   n_remote_cluster_variable <name> <value> # set
#   n_remote_cluster_variable <name> --unset # delete
#===============================================================================
n_remote_cluster_variable() {
  local name="${1:?Usage: n_remote_cluster_variable <name> [value|--unset]}"
  local value="${2:-}"
  
  # Clear any previous error state
  N_IPS_COMMAND_LAST_ERROR=""
  N_IPS_COMMAND_LAST_RESPONSE=""
  
  local result
  local exit_code
  
  if [[ $# -eq 1 ]]; then
    # GET operation
    if result=$(n_api_request "cluster_variable" "name=${name}" 2>&1); then
      echo "$result"
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to get cluster variable: $result"
      if [[ "$result" =~ "not found" ]] || [[ "$result" =~ "404" ]]; then
        return 4
      fi
      return $exit_code
    fi
  elif [[ "$value" == "--unset" ]]; then
    # UNSET operation
    if result=$(n_api_request "cluster_variable" "name=${name}" "operation=unset" 2>&1); then
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to unset cluster variable: $result"
      return $exit_code
    fi
  else
    # SET operation
    if result=$(n_api_request "cluster_variable" "name=${name}" "value=${value}" 2>&1); then
      return 0
    else
      exit_code=$?
      N_IPS_COMMAND_LAST_ERROR="Failed to set cluster variable: $result"
      return $exit_code
    fi
  fi
}

#===============================================================================
# n_remote_log
# ------------
# Send log messages via API (enhanced version).
#
# Usage:
#   n_remote_log "message"
#   echo "message" | n_remote_log
#
# Automatically includes the calling function name.
#===============================================================================
n_remote_log() {
  local message=""
  local function="${FUNCNAME[1]:-unknown}"
  
  # Get message from args or stdin
  if [[ $# -gt 0 ]]; then
    message="$*"
  elif [[ ! -t 0 ]]; then
    message=$(cat)
  else
    echo "Usage: n_remote_log <message>" >&2
    return 1
  fi
  
  [[ -z "$message" ]] && return 0
  
  # Process line by line to handle multi-line input
  local line
  local failed=0
  
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      if ! n_api_request "log_message" \
        "message=${line}" \
        "function=${function}" >/dev/null 2>&1; then
        ((failed++))
      fi
    fi
  done <<< "$message"
  
  return $((failed > 0 ? 1 : 0))
}

#===============================================================================
# Utility Functions
#===============================================================================

#===============================================================================
# n_api_health
# ------------
# Check API health/status.
#
# Usage:
#   n_api_health
#
# Returns health information as JSON.
#===============================================================================
n_api_health() {
  n_api_request "health"
}

#===============================================================================
# n_registry_search
# -----------------
# Search registry for hosts matching criteria.
#
# Usage:
#   n_registry_search <field> <value>
#
# Example:
#   n_registry_search "type" "SCH"
#===============================================================================
n_registry_search() {
  local field="${1:?Usage: n_registry_search <field> <value>}"
  local value="${2:?}"
  
  n_api_request "registry_search" \
    "registry=host" \
    "field=${field}" \
    "value=${value}"
}

#===============================================================================
# Compatibility Override
#===============================================================================
# This can be enabled to override n_ips_command with API version
if [[ "${HPS_USE_API:-false}" == "true" ]]; then
  n_ips_command() {
    local cmd="${1:?}"
    shift
    
    case "$cmd" in
      log_message|host_variable|cluster_variable)
        # Convert old-style parameters to API call
        local args=("$cmd")
        local param key value
        
        for param in "$@"; do
          if [[ "$param" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            args+=("${key}=${value}")
          fi
        done
        
        n_api_request "${args[@]}"
        ;;
        
      *)
        echo "ERROR: Command not supported via API: $cmd" >&2
        return 1
        ;;
    esac
  }
fi

#===============================================================================
# Debug Functions
#===============================================================================
if [[ "${HPS_API_DEBUG:-false}" == "true" ]]; then
  n_api_debug() {
    echo "=== HPS API Debug Info ===" >&2
    echo "IPS: $(n_get_provisioning_node 2>&1)" >&2
    echo "MAC: $(get_mac 2>&1)" >&2
    echo "API URL: http://$(n_get_provisioning_node)/api/api.sh" >&2
    
    echo -e "\n=== Testing API connectivity ===" >&2
    if n_api_health >/dev/null 2>&1; then
      echo "✓ API is accessible" >&2
      n_api_health | jq . >&2
    else
      echo "✗ API is not accessible" >&2
    fi
  }
fi
