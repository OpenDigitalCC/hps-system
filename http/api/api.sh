#!/bin/bash
#===============================================================================
# HPS API Server - api.sh
#===============================================================================
# JSON-based API handler for HPS system
# Location: /srv/hps-system/http/api/api.sh
# URL: http://ips/api/api.sh
#
# This provides a modern JSON API alongside the legacy boot_manager.sh
#===============================================================================

# Source HPS libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HPS_LIB="${SCRIPT_DIR}/../../lib/functions.sh"

if [[ ! -f "$HPS_LIB" ]]; then
  echo "Status: 500 Internal Server Error"
  echo "Content-Type: text/plain"
  echo ""
  echo "Failed to find HPS libraries at $HPS_LIB"
  exit 1
fi

source "$HPS_LIB" || {
  echo "Status: 500 Internal Server Error"
  echo "Content-Type: text/plain"
  echo ""
  echo "Failed to load HPS libraries"
  exit 1
}

#===============================================================================
# API Configuration
#===============================================================================
API_VERSION="2.0"
API_MAX_REQUEST_SIZE=10485760  # 10MB
API_LOG_PREFIX="[API]"

#===============================================================================
# CGI Helper Functions
#===============================================================================
api_response() {
  local code="${1:?}"
  local content="${2:?}"
  local content_type="${3:-application/json}"
  
  case "$code" in
    200) echo "Status: 200 OK" ;;
    201) echo "Status: 201 Created" ;;
    204) echo "Status: 204 No Content" ;;
    400) echo "Status: 400 Bad Request" ;;
    401) echo "Status: 401 Unauthorized" ;;
    403) echo "Status: 403 Forbidden" ;;
    404) echo "Status: 404 Not Found" ;;
    405) echo "Status: 405 Method Not Allowed" ;;
    413) echo "Status: 413 Request Entity Too Large" ;;
    500) echo "Status: 500 Internal Server Error" ;;
    503) echo "Status: 503 Service Unavailable" ;;
    *) echo "Status: $code" ;;
  esac
  
  echo "Content-Type: $content_type"
  echo "Cache-Control: no-cache"
  echo "X-API-Version: $API_VERSION"
  echo ""
  
  if [[ "$code" != "204" ]]; then
    echo "$content"
  fi
}

api_error() {
  local code="${1:?}"
  local message="${2:?}"
  local details="${3:-}"
  
  local json=$(jq -n \
    --arg msg "$message" \
    --arg code "$code" \
    --arg details "$details" \
    '{
      error: $msg,
      code: $code | tonumber,
      details: (if $details != "" then $details else null end),
      timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
    }')
  
  api_response "$code" "$json"
  
  # Log error
  hps_log error "$API_LOG_PREFIX Error $code: $message ${details:+(${details})}"
}

api_success() {
  local data="${1:?}"
  local code="${2:-200}"
  
  local json
  if echo "$data" | jq . >/dev/null 2>&1; then
    # Already valid JSON
    json=$(jq -n --argjson data "$data" '{
      success: true,
      data: $data,
      timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
    }')
  else
    # Wrap string data
    json=$(jq -n --arg data "$data" '{
      success: true,
      data: $data,
      timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
    }')
  fi
  
  api_response "$code" "$json"
}

#===============================================================================
# Request Validation
#===============================================================================
validate_request() {
  # Check method
  if [[ "$REQUEST_METHOD" != "POST" ]] && [[ "$REQUEST_METHOD" != "GET" ]]; then
    api_error 405 "Method not allowed" "Only GET and POST are supported"
    exit 1
  fi
  
  # For POST, check content type and size
  if [[ "$REQUEST_METHOD" == "POST" ]]; then
    if [[ "${CONTENT_TYPE%%/*}" != "application/json" ]] && [[ "${CONTENT_TYPE%%;*}" != "application/json" ]]; then
      api_error 400 "Invalid content type" "Expected application/json, got ${CONTENT_TYPE}"
      exit 1
    fi
    
    if [[ -n "$CONTENT_LENGTH" ]] && [[ "$CONTENT_LENGTH" -gt "$API_MAX_REQUEST_SIZE" ]]; then
      api_error 413 "Request too large" "Maximum size: $API_MAX_REQUEST_SIZE bytes"
      exit 1
    fi
    
    if [[ -z "$CONTENT_LENGTH" ]] || [[ "$CONTENT_LENGTH" -eq 0 ]]; then
      api_error 400 "Empty request body"
      exit 1
    fi
  fi
  
  # Get client identity using HPS function
  CLIENT_MAC=$(hps_origin_tag)
  CLIENT_IP="${HTTP_X_REAL_IP:-${HTTP_X_FORWARDED_FOR:-$REMOTE_ADDR}}"
  
  # Authenticate - must be a known host or localhost
  if [[ "$CLIENT_MAC" == "localhost" ]] || [[ "$CLIENT_IP" == "127.0.0.1" ]]; then
    # Local access allowed
    CLIENT_MAC="${HTTP_X_HPS_MAC:-localhost}"
  elif [[ -n "$CLIENT_MAC" ]]; then
    # Check if this is a known host
    if ! host_config_exists "$CLIENT_MAC"; then
      api_error 401 "Unauthorized" "Unknown host: $CLIENT_MAC"
      exit 1
    fi
  else
    # No MAC identified
    api_error 401 "Unauthorized" "Cannot identify client"
    exit 1
  fi
}

#===============================================================================
# Request Parser
#===============================================================================
parse_request() {
  if [[ "$REQUEST_METHOD" == "GET" ]]; then
    # Simple GET support for health checks
    REQUEST_ACTION="${QUERY_STRING%%&*}"
    REQUEST_ACTION="${REQUEST_ACTION#action=}"
  else
    # Read POST body
    local post_data
    read -n "$CONTENT_LENGTH" post_data
    
    # Parse JSON
    if ! REQUEST_JSON=$(echo "$post_data" | jq -r '.' 2>/dev/null); then
      api_error 400 "Invalid JSON" "Failed to parse request body"
      exit 1
    fi
    
    # Extract all common fields in a single jq call
    eval "$(echo "$REQUEST_JSON" | jq -r '@sh "
      REQUEST_ACTION=\(.action // "")
      REQUEST_MAC=\(.mac // "")
      REQUEST_REGISTRY=\(.registry // "")  
      REQUEST_KEY=\(.key // "")
      REQUEST_VALUE=\(.value // "")
      REQUEST_NAME=\(.name // "")
      REQUEST_OPERATION=\(.operation // "")
      REQUEST_MESSAGE=\(.message // "")
      REQUEST_FUNCTION=\(.function // "")
      REQUEST_FIELD=\(.field // "")
      REQUEST_REQID=\(.reqid // "")
    "')"
    
    # Use provided MAC or detected MAC  
    REQUEST_MAC="${REQUEST_MAC:-$CLIENT_MAC}"
  fi
  
  # Validate action
  if [[ -z "$REQUEST_ACTION" ]]; then
    api_error 400 "Missing action parameter"
    exit 1
  fi
  
  # Log request (don't log sensitive data)
  hps_log info "$API_LOG_PREFIX Request from $CLIENT_IP/$CLIENT_MAC: $REQUEST_ACTION"
}

#===============================================================================
# Registry Action Handler
#===============================================================================
handle_registry_action() {
  # Variables already extracted by parse_request
  local registry="$REQUEST_REGISTRY"
  local operation="$REQUEST_OPERATION"
  local key="$REQUEST_KEY"
  local value="$REQUEST_VALUE"

  # Get active cluster once (if function needs it)
  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "No active cluster configured"
    return 1
  } 
   
  # Extract operation from action if needed (registry_get -> get)
  if [[ -z "$operation" ]] && [[ "$REQUEST_ACTION" =~ ^registry_ ]]; then
    operation="${REQUEST_ACTION#registry_}"
  fi
  
  # Validate registry type
  case "$registry" in
    host|cluster) ;;
    *)
      api_error 400 "Invalid registry type" "Must be 'host' or 'cluster'"
      return
      ;;
  esac
  
  # Validate required parameters
  if [[ "$registry" == "host" ]] && [[ -z "$REQUEST_MAC" ]]; then
    api_error 400 "MAC address required for host registry"
    return
  fi
  
  # Execute operation
  case "$operation" in
    get)
      if [[ -z "$key" ]]; then
        api_error 400 "Key required for get operation"
        return
      fi
      
      local result
      if [[ "$registry" == "host" ]]; then
        result=$(host_registry "$REQUEST_MAC" get "$key" 2>&1) || {
          api_error 404 "Key not found" "$key"
          return
        }
      else
        result=$(cluster_registry "$cluster" get "$key" 2>&1) || {
          api_error 404 "Key not found" "$key"
          return
        }
      fi
      api_success "$result"
      ;;
      
    set)
      if [[ -z "$key" ]]; then
        api_error 400 "Key required for set operation"
        return
      fi
      
      if [[ -z "$value" ]] && ! echo "$REQUEST_JSON" | jq -e 'has("value")' >/dev/null; then
        api_error 400 "Value required for set operation"
        return
      fi
      
      # Validate value is JSON
      if ! echo "$value" | jq . >/dev/null 2>&1; then
        # Try wrapping as string
        value="\"$value\""
        if ! echo "$value" | jq . >/dev/null 2>&1; then
          api_error 400 "Invalid JSON value"
          return
        fi
      fi
      
      if [[ "$registry" == "host" ]]; then
        host_registry "$REQUEST_MAC" set "$key" "$value" >/dev/null 2>&1 || {
          api_error 500 "Failed to set value" "Registry write error"
          return
        }
      else
        cluster_registry "$cluster" set "$key" "$value" >/dev/null 2>&1 || {
          api_error 500 "Failed to set value" "Registry write error"
          return
        }
      fi
      
      # Simple JSON response without jq
      api_response 201 "{\"success\":true,\"data\":{\"key\":\"$key\",\"action\":\"set\"}}"
      ;;
      
    delete|unset)
      if [[ -z "$key" ]]; then
        api_error 400 "Key required for delete operation"
        return
      fi
      
      if [[ "$registry" == "host" ]]; then
        host_registry "$REQUEST_MAC" delete "$key" >/dev/null 2>&1
      else
        cluster_registry "$cluster" delete "$key" >/dev/null 2>&1
      fi
      
      # Simple JSON response
      api_response 200 "{\"success\":true,\"data\":{\"key\":\"$key\",\"action\":\"deleted\"}}"
      ;;
      
    list)
      local keys
      if [[ "$registry" == "host" ]]; then
        keys=$(host_registry "$REQUEST_MAC" list 2>/dev/null | jq -R . | jq -s .)
      else
        keys=$(cluster_registry list 2>/dev/null | jq -R . | jq -s .)
      fi
      api_success "$keys"
      ;;
      
    view)
      local view
      if [[ "$registry" == "host" ]]; then
        view=$(host_registry "$REQUEST_MAC" view 2>/dev/null)
      else
        view=$(cluster_registry "$cluster" view 2>/dev/null)
      fi
      
      if [[ -z "$view" ]] || [[ "$view" == "{}" ]]; then
        api_success "{}"
      else
        api_success "$view"
      fi
      ;;
      
    search)
      # Field and value already extracted
      local field="$REQUEST_FIELD"
      local search_value="$REQUEST_VALUE"
      
      if [[ -z "$field" ]] || [[ -z "$search_value" ]]; then
        api_error 400 "Field and value required for search"
        return
      fi
      
      local results
      readarray -t results < <(registry_search "$registry" "$field" "$search_value")
      local json_array=$(printf '%s\n' "${results[@]}" | jq -R . | jq -s .)
      
      api_success "$json_array"
      ;;
      
    *)
      api_error 400 "Unknown registry operation" "$operation"
      ;;
  esac
}

#===============================================================================
# Legacy Action Handler
#===============================================================================
handle_legacy_action() {

  # Get active cluster once (if function needs it)
  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "No active cluster configured"
    return 1
  } 
   
  case "$REQUEST_ACTION" in
    log_message)
      # Variables already extracted
      local message="$REQUEST_MESSAGE"
      local function="${REQUEST_FUNCTION:-unknown}"
      
      if [[ -z "$message" ]]; then
        api_error 400 "Message required"
        return
      fi
      
      # Use existing log function
      log_from_host "${REQUEST_MAC:-unknown}" "$function" "$message"
      
      # Simple success response
      api_response 200 "{\"success\":true,\"data\":\"Message logged\"}"
      ;;
      
    host_variable)
      # Variables already extracted
      local name="$REQUEST_NAME"
      local value="$REQUEST_VALUE"
      local operation="$REQUEST_OPERATION"
      
      if [[ -z "$name" ]]; then
        api_error 400 "Variable name required"
        return
      fi
      
      if [[ -z "$REQUEST_MAC" ]]; then
        api_error 400 "MAC address required"
        return
      fi
      
      if [[ "$operation" == "unset" ]]; then
        host_registry "$REQUEST_MAC" delete "$name" >/dev/null 2>&1
        api_response 200 "{\"success\":true,\"data\":{\"action\":\"unset\",\"name\":\"$name\"}}"
      elif echo "$REQUEST_JSON" | jq -e 'has("value")' >/dev/null; then
        # SET - wrap in quotes if not already JSON
        if ! echo "$value" | jq . >/dev/null 2>&1; then
          value="\"$value\""
        fi
        host_registry "$REQUEST_MAC" set "$name" "$value" >/dev/null 2>&1 || {
          api_error 500 "Failed to set variable"
          return
        }
        api_response 200 "{\"success\":true,\"data\":{\"action\":\"set\",\"name\":\"$name\"}}"
      else
        # GET
        local result
        result=$(host_registry "$REQUEST_MAC" get "$name" 2>&1) || {
          api_error 404 "Variable not found" "$name"
          return
        }
        # Unwrap if it's a JSON string
        if echo "$result" | jq -e 'type == "string"' >/dev/null 2>&1; then
          result=$(echo "$result" | jq -r '.')
        fi
        api_success "\"$result\""
      fi
      ;;
      
    cluster_variable)
      # Variables already extracted
      local name="$REQUEST_NAME"
      local value="$REQUEST_VALUE"
      local operation="$REQUEST_OPERATION"
      
      if [[ -z "$name" ]]; then
        api_error 400 "Variable name required"
        return
      fi
      
      if [[ "$operation" == "unset" ]]; then
        cluster_registry "$cluster" delete "$name" >/dev/null 2>&1
        api_response 200 "{\"success\":true,\"data\":{\"action\":\"unset\",\"name\":\"$name\"}}"
      elif echo "$REQUEST_JSON" | jq -e 'has("value")' >/dev/null; then
        # SET
        if ! echo "$value" | jq . >/dev/null 2>&1; then
          value="\"$value\""
        fi
        cluster_registry "$cluster" set "$name" "$value" >/dev/null 2>&1 || {
          api_error 500 "Failed to set variable"
          return
        }
        api_response 200 "{\"success\":true,\"data\":{\"action\":\"set\",\"name\":\"$name\"}}"
      else
        # GET
        local result
        result=$(cluster_registry "$cluster" get "$name" 2>&1) || {
          api_error 404 "Variable not found" "$name"
          return
        }
        if echo "$result" | jq -e 'type == "string"' >/dev/null 2>&1; then
          result=$(echo "$result" | jq -r '.')
        fi
        api_success "\"$result\""
      fi
      ;;
      
    *)
      return 1  # Not a legacy action
      ;;
  esac
  
  return 0
}

#===============================================================================
# System Action Handler
#===============================================================================
handle_system_action() {
  case "$REQUEST_ACTION" in
    ping|health|status)
      # Get system info safely
      local uptime_info="System running"
      if [[ -f /proc/uptime ]]; then
        local uptime_seconds=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
        local days=$((uptime_seconds / 86400))
        local hours=$(((uptime_seconds % 86400) / 3600))
        local minutes=$(((uptime_seconds % 3600) / 60))
        uptime_info="up ${days}d ${hours}h ${minutes}m"
      fi
      
      local cluster_name="unknown"
      if [[ -L "/srv/hps-config/clusters/active-cluster" ]]; then
        cluster_name=$(readlink /srv/hps-config/clusters/active-cluster | xargs basename)
      fi
      
      local health_data=$(jq -n \
        --arg version "$API_VERSION" \
        --arg uptime "$uptime_info" \
        --arg hostname "$(hostname)" \
        --arg cluster "$cluster_name" \
        '{
          status: "healthy",
          version: $version,
          hostname: $hostname,
          cluster: $cluster,
          uptime: $uptime,
          timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
        }')
      api_success "$health_data"
      ;;
      
    ctrl_exec_pair_request)
      # A provisioning node reports the pairing reqid it obtained from the
      # dispatcher. The registry-bound approver decides whether to approve.
      # Authorisation is by the binding checks in ce_approve_pair_request,
      # not by this endpoint (the caller is already MAC-authenticated).
      if [[ -z "$REQUEST_REQID" ]]; then
        api_error 400 "Missing reqid parameter"
        return
      fi
      if ce_approve_pair_request "$REQUEST_MAC" "$REQUEST_REQID"; then
        api_success "{\"paired\": true, \"mac\": \"$REQUEST_MAC\"}"
      else
        api_error 403 "Pairing request denied" "$REQUEST_MAC"
      fi
      ;;

    node_functions|bootstrap_functions)
      # Return node functions bundle
      local functions_file="/srv/hps-system/lib/node-functions"
      if [[ ! -f "$functions_file" ]]; then
        # Try alternate location
        functions_file="/tmp/node-functions"
      fi
      
      if [[ -f "$functions_file" ]]; then
        local content
        content=$(base64 -w0 < "$functions_file" 2>/dev/null) || {
          api_error 500 "Failed to encode functions"
          return
        }
        
        local size=$(stat -c%s "$functions_file" 2>/dev/null || echo "0")
        api_success "{
          \"filename\": \"node-functions\",
          \"size\": $size,
          \"encoding\": \"base64\",
          \"content\": \"$content\"
        }"
      else
        api_error 404 "Node functions not found"
      fi
      ;;
      
    *)
      return 1  # Not a system action
      ;;
  esac
  
  return 0
}

#===============================================================================
# Main Request Router
#===============================================================================
route_request() {
  # Try registry actions
  if [[ "$REQUEST_ACTION" =~ ^registry_ ]]; then
    handle_registry_action
    return
  fi
  
  # Try legacy actions
  if handle_legacy_action; then
    return
  fi
  
  # Try system actions
  if handle_system_action; then
    return
  fi
  
  # Unknown action
  api_error 404 "Unknown action" "$REQUEST_ACTION"
}

#===============================================================================
# Main Entry Point
#===============================================================================
main() {
  # Set up error handling - but don't use ERR trap as it interferes with normal flow
  set -o pipefail
  
  # Validate request
  validate_request
  
  # Parse request
  parse_request
  
  # Route to handler
  route_request
}

# Execute
main "$@"
