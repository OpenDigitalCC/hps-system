#!/bin/bash
#===============================================================================
# HPS Core Function Library
#===============================================================================
# Essential functions required before other libraries are loaded.
#
# Contents:
#   - hps_log   - Bootstrap logging (minimal dependencies)
#   - hps_log         - Full-featured logging (requires registry)
#   - hps_get_config  - Configuration and path retrieval
#   - hps_check_bash_syntax - Syntax validation with context
#===============================================================================



#===============================================================================
# hps_log (Full Version - With Error Call Stack)
# -------
# Full-featured logging with optional cluster-specific log files.
#
# Usage:
#   hps_log <level> <message>
#
# Parameters:
#   level   - Log level (info, warn, error, debug)
#   message - Message to log
#
# Behaviour:
#   - Always logs to system log: ${HPS_LOG}/hps-system.log
#   - Additionally logs to cluster log if cluster configured
#   - Includes hostname, function name, and client type
#   - For ERROR level: includes call stack showing function chain
#   - URL-decodes messages
#   - Logs to rsyslog if available
#   - Works with or without active cluster
#
# Returns:
#   0 always
#
# Example usage:
#   hps_log info "Host provisioned successfully"
#   hps_log error "Failed to create storage volume"
#
# Example output (ERROR with call stack):
#   [ips] [ERROR] [validate_storage] [create_host:45 → provision_node:120 → main:15] Storage pool not available
#
#===============================================================================
hps_log() {
  local level="${1^^}"
  shift
  local raw_msg="$*"
  local ident="${HPS_LOG_IDENT:-hps}"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Get log directory (use variable or default)
  local logdir="${HPS_LOG:-/srv/hps-log}"
  
  # Default to system log (always available)
  local system_log="${logdir}/hps-system.log"
  
  # Map HPS log levels to syslog priorities
  local syslog_priority
  case "$level" in
    ERROR)   syslog_priority="err" ;;
    WARN)    syslog_priority="warning" ;;
    INFO)    syslog_priority="info" ;;
    DEBUG)   syslog_priority="debug" ;;
    *)       
      syslog_priority="info"
      level="INFO"
      ;;
  esac
 
  # Get origin identifier - use hostname if configured
  local origin_id=""
  local origin_tag=""
  
  if declare -f hps_origin_tag >/dev/null 2>&1; then
    origin_tag=$(hps_origin_tag 2>/dev/null) || origin_tag=""
    
    # Try to get hostname from registry if we have a MAC
    if [[ -n "$origin_tag" ]] && declare -f host_registry >/dev/null 2>&1; then
      if host_registry "$origin_tag" exists HOSTNAME 2>/dev/null; then
        origin_id=$(host_registry "$origin_tag" get HOSTNAME 2>/dev/null) || origin_id=""
      fi
    fi
  fi
  
  # Fallback to system hostname
  if [[ -z "$origin_id" ]]; then
    origin_id=$(hostname 2>/dev/null || echo "local")
  fi
  
  # Detect client type if function available
  local client_type=""
  if declare -f detect_client_type >/dev/null 2>&1; then
    client_type="($(detect_client_type))"
  fi
  
  # URL decode function (for boot_manager compatibility)
  urldecode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
  }
  
  # Build call stack for ERROR level
  local call_stack=""
  if [[ "$level" == "ERROR" ]]; then
    # Build call stack (skip hps_log itself at index 0)
    local stack_parts=()
    local i
    for ((i=1; i<${#FUNCNAME[@]}; i++)); do
      # Stop at main or if we hit the script level
      [[ "${FUNCNAME[$i]}" == "main" ]] && break
      [[ "${FUNCNAME[$i]}" == "source" ]] && break
      
      # Add to stack: function:line
      stack_parts+=("${FUNCNAME[$i]}:${BASH_LINENO[$((i-1))]}")
      
      # Limit depth to prevent huge logs (max 5 levels)
      [[ $i -ge 5 ]] && break
    done
    
    # Format as call chain with arrow separator
    if [[ ${#stack_parts[@]} -gt 0 ]]; then
      call_stack=" [$(IFS=' → '; echo "${stack_parts[*]}")]"
    fi
  fi
  
  # Build log message with context (add call stack for errors)
  local msg="[${origin_id}] [${level}] [${FUNCNAME[1]}]${call_stack} ${client_type} $(urldecode "$raw_msg")"
  
  # Check if rsyslog is running
  local rsyslog_running=false
  if pgrep -x "rsyslogd" >/dev/null 2>&1 || [[ -S /dev/log ]]; then
    rsyslog_running=true
  fi
 
  # Determine log destination (priority order)
  local log_destination="stderr"
  local logfile=""
  
  # Ensure log directory exists
  if [[ ! -d "$logdir" ]]; then
    mkdir -p "$logdir" 2>/dev/null || true
  fi
  
  # Priority 1: Rsyslog (if available)
  if [[ "$rsyslog_running" == "true" ]]; then
    logger -t "$ident" -p "local0.${syslog_priority}" "$msg" 2>/dev/null && return 0
    # If logger fails, fall through to file logging
  fi
  
  # Priority 2: Cluster log (if cluster configured)
  if declare -f system_registry >/dev/null 2>&1; then
    if system_registry exists ACTIVE_CLUSTER 2>/dev/null; then
      local cluster
      cluster=$(system_registry get ACTIVE_CLUSTER 2>/dev/null)
      
      if [[ -n "$cluster" ]] && [[ "$cluster" != "null" ]]; then
        logfile="${logdir}/cluster-${cluster}.log"
        log_destination="cluster"
      fi
    fi
  fi
  
  # Priority 3: System log (fallback if no cluster or cluster log fails)
  if [[ -z "$logfile" ]]; then
    logfile="${system_log}"
    log_destination="system"
  fi
  
  # Write to file (or stderr if file write fails)
  if [[ -w "$logfile" ]] || [[ ! -e "$logfile" && -w "$logdir" ]]; then
    echo "[${ts}] $msg" >> "$logfile" 2>/dev/null || echo "[${ts}] $msg" >&2
  else
    echo "[${ts}] $msg" >&2
  fi
  
  return 0
}



#===============================================================================
# hps_get_config
# --------------
# Single source for configuration values and paths.
#
# Usage:
#   hps_get_config <key>
#
# Behaviour:
#   - Returns the requested configuration value or path
#   - Returns error code 1 if key is unknown
#   - Logs errors using hps_log
#   - No caching - direct lookups every time
#   - Active cluster fetched from system_registry on each call
#
# Supported Keys:
#   Active Configuration:
#     active_cluster        - Current active cluster name
#
#   Static Paths (from hps.conf):
#     system_base           - HPS_SYSTEM_BASE
#     config_base           - HPS_CONFIG_BASE
#     resources             - HPS_RESOURCES
#     log                   - HPS_LOG
#     tftp                  - TFTP root directory
#     system_log            - System-wide log file
#
#   Dynamic Paths (computed):
#     cluster_base          - Active cluster directory
#     cluster_hosts         - Active cluster hosts directory
#     cluster_services      - Active cluster services directory
#     cluster_registry      - Active cluster registry database path
#     cluster_log           - Active cluster log file
#
#   System Paths:
#     system_registry       - System registry database path
#     os_registry           - OS registry database path
#     supervisord_dir       - Supervisor configuration directory
#     supervisord_conf      - Supervisor configuration file
#
#   Network Configuration:
#     ips_address           - IPS (DHCP/DNS/HTTP) IP address
#
# Returns:
#   0 on success (value printed to stdout)
#   1 if key is unknown or lookup fails
#
# Example usage:
#   cluster=$(hps_get_config active_cluster) || return 1
#   hosts_dir=$(hps_get_config cluster_hosts) || return 1
#   log_file=$(hps_get_config cluster_log) || return 1
#
#===============================================================================
hps_get_config() {
  local key="${1:?Usage: hps_get_config <key>}"
  
  case "$key" in
    # Active configuration
    active_cluster)
      local cluster
      if declare -f system_registry >/dev/null 2>&1; then
        cluster=$(system_registry get ACTIVE_CLUSTER 2>/dev/null) || {
          hps_log error "Failed to get active cluster from registry"
          return 1
        }
        echo "$cluster"
      else
        hps_log error "system_registry function not available"
        return 1
      fi
      ;;
    
    # Static paths (from hps.conf)
    system_base)
      echo "${HPS_SYSTEM_BASE}"
      ;;
    config_base)
      echo "${HPS_CONFIG_BASE}"
      ;;
    resources)
      echo "${HPS_RESOURCES}"
      ;;
    log)
      echo "${HPS_LOG}"
      ;;
    tftp)
      echo "${HPS_CONFIG_BASE}/tftp"
      ;;
    system_log)
      echo "${HPS_LOG}/hps-system.log"
      ;;
    
    # Dynamic paths (computed - require active cluster)
    cluster_base)
      local cluster
      cluster=$(hps_get_config active_cluster) || return 1
      echo "${HPS_CONFIG_BASE}/clusters/${cluster}"
      ;;
    cluster_hosts)
      local cluster_base
      cluster_base=$(hps_get_config cluster_base) || return 1
      echo "${cluster_base}/hosts"
      ;;
    cluster_services)
      local cluster_base
      cluster_base=$(hps_get_config cluster_base) || return 1
      echo "${cluster_base}/services"
      ;;
    cluster_registry)
      local cluster_base
      cluster_base=$(hps_get_config cluster_base) || return 1
      echo "${cluster_base}/cluster.db"
      ;;
    cluster_log)
      local cluster
      cluster=$(hps_get_config active_cluster) || return 1
      echo "${HPS_LOG}/cluster-${cluster}.log"
      ;;

    # Script directories
    scripts_dir)
      echo "${HPS_SYSTEM_BASE}/scripts"
      ;;
    scripts_cluster_config)
      echo "${HPS_SYSTEM_BASE}/scripts/cluster-config.d"
      ;;
    scripts_tests)
      echo "${HPS_SYSTEM_BASE}/scripts/tests"
      ;;
    
    # System paths
    system_registry)
      echo "${HPS_CONFIG_BASE}/system.db"
      ;;
    os_registry)
      echo "${HPS_CONFIG_BASE}/os.db"
      ;;
    supervisord_dir)
      echo "${HPS_CONFIG_BASE}/services"
      ;;
    supervisord_conf)
      echo "${HPS_CONFIG_BASE}/services/supervisord.conf"
      ;;
    
    # Network configuration
    ips_address)
      # Get active cluster first
      local cluster
      cluster=$(system_registry get ACTIVE_CLUSTER 2>/dev/null) || {
        hps_log error "No active cluster configured (needed for IPS address)"
        return 1
      }

      # Get config base
      local config_base="${HPS_CONFIG_BASE:-/srv/hps-config}"

      # Direct registry access (no function calls that might recurse)
      local ips_ip
      ips_ip=$(json_registry "${config_base}/clusters/${cluster}/cluster.db" get network_dhcp_ip 2>/dev/null) || {
        hps_log error "IPS IP address not configured (network_dhcp_ip)"
        return 1
      }
      echo "$ips_ip"
      ;;

    # Unknown key
    *)
      hps_log error "Unknown configuration key: ${key}"
      return 1
      ;;
  esac
  
  return 0
}


#===============================================================================
# hps_check_bash_syntax
# ---------------------
# Check bash code for syntax errors with context.
#
# Usage:
#   hps_check_bash_syntax <file_or_stdin> [label]
#
# Parameters:
#   file_or_stdin - File path or '-' for stdin
#   label         - Optional label for the code being checked
#
# Behaviour:
#   - Validates bash syntax using 'bash -n'
#   - Shows context around errors (5 lines before/after)
#   - Identifies which function contains the error
#   - Provides helpful hints for common issues
#
# Returns:
#   0 if syntax is valid
#   1 if errors found
#
# Example usage:
#   hps_check_bash_syntax /path/to/script.sh
#   echo "$code" | hps_check_bash_syntax - "generated functions"
#
#===============================================================================
hps_check_bash_syntax() {
  local input="${1:--}"
  local label="${2:-bash code}"
  local tempfile
  
  echo "[SYNTAX] Checking $label..." >&2
  
  # Handle input
  if [[ "$input" == "-" ]]; then
    tempfile="/tmp/bash-syntax-check-$$"
    cat > "$tempfile"
  else
    tempfile="$input"
  fi
  
  # Run syntax check
  local syntax_errors
  if syntax_errors=$(bash -n "$tempfile" 2>&1); then
    echo "[SYNTAX] ✓ Syntax check passed for $label" >&2
    [[ "$input" == "-" ]] && rm -f "$tempfile"
    return 0
  fi
  
  echo "[SYNTAX] ✗ Syntax errors found in $label:" >&2
  
  # Load file into array for context
  local -a lines
  mapfile -t lines < "$tempfile"
  
  # Parse each error
  while IFS= read -r error; do
    # Extract line number from error message
    if [[ "$error" =~ line[[:space:]]+([0-9]+): ]]; then
      local error_line="${BASH_REMATCH[1]}"
      local error_msg="${error#*: line $error_line: }"
      
      # Find which function contains this line
      local func_name="(top level)"
      local current_func=""
      local func_start_line=0
      
      for line_no in "${!lines[@]}"; do
        local line="${lines[$line_no]}"
        
        # Check for function definition
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\) ]]; then
          current_func="${BASH_REMATCH[1]}"
          func_start_line=$line_no
        fi
        
        # Found the error line
        if [[ $((line_no + 1)) -eq $error_line ]]; then
          func_name="${current_func:-"(top level)"}"
          break
        fi
      done
      
      echo "" >&2
      echo "  Error: $error_msg" >&2
      echo "  Function: $func_name" >&2
      [[ -n "$current_func" ]] && echo "  Function starts at line: $((func_start_line + 1))" >&2
      echo "  Error at line $error_line" >&2
      echo "" >&2
      echo "  Context:" >&2
      
      # Show context (5 lines before and after)
      local start=$((error_line - 6))
      local end=$((error_line + 4))
      [[ $start -lt 0 ]] && start=0
      [[ $end -ge ${#lines[@]} ]] && end=$((${#lines[@]} - 1))
      
      for ((i=start; i<=end; i++)); do
        local line_num=$((i + 1))
        if [[ $line_num -eq $error_line ]]; then
          echo ">>> ${line_num}: ${lines[$i]}" >&2
        else
          echo "    ${line_num}: ${lines[$i]}" >&2
        fi
      done
      echo "" >&2
      
    else
      # Couldn't parse line number, show raw error
      echo "  $error" >&2
    fi
  done <<< "$syntax_errors"
  
  # Helpful hints for common issues
  echo "[HINT] Common syntax error causes:" >&2
  echo "  - Missing 'then' after if statement" >&2
  echo "  - Missing 'do' after for/while loop" >&2
  echo "  - Unclosed quotes or command substitution" >&2
  echo "  - Unmatched parentheses or braces" >&2
  echo "  - Missing semicolon before closing brace" >&2
  
  [[ "$input" == "-" ]] && rm -f "$tempfile"
  return 1
}

#===============================================================================
# Compatibility Aliases
#===============================================================================

#===============================================================================
# get_ips_address
# ---------------
# Alias for hps_get_config ips_address.
# Get the IPS IP address from cluster registry.
#
# Usage:
#   get_ips_address
#
# Returns:
#   0 on success (IP address via stdout)
#   1 if IP not configured
#
# Example usage:
#   ips_ip=$(get_ips_address)
#
#===============================================================================
get_ips_address() {
  hps_get_config ips_address
}
