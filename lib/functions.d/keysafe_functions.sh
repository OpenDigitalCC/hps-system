#
# keysafe.sh - Server-side token-based authentication for HPS
#
# This library provides secure token management for HPS operations including
# backup authentication. Supports both "open" mode (prototyping) and "secure"
# mode (Biscuit-auth protected).
#
# Location: /srv/hps-system/lib/functions.d/keysafe.sh
# Platform: IPS (Initial Provisioning System) only
#

__guard_source || return

#===============================================================================
# get_keysafe_dir
# ---------------
# Returns the keysafe directory path for the active cluster.
#
# Behaviour:
#   - Resolves active cluster symlink from HPS_CLUSTER_CONFIG_BASE_DIR
#   - Returns path to cluster's keysafe subdirectory
#   - Creates directory structure if it doesn't exist
#   - Creates tokens/ subdirectory for live token storage
#
# Environment:
#   HPS_CLUSTER_CONFIG_BASE_DIR - Base directory for cluster configs
#
# Returns:
#   Prints keysafe directory path to stdout on success
#   Returns 1 if active cluster link not found
#   Returns 2 if directory creation fails
#===============================================================================
get_keysafe_dir() {
    local cluster_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
    local keysafe_dir
    
    # Verify active cluster symlink exists
    if [[ ! -L "$cluster_dir" ]]; then
        echo "ERROR: Active cluster symlink not found: $cluster_dir" >&2
        return 1
    fi
    
    # Resolve and construct keysafe path
    keysafe_dir="$(readlink -f "$cluster_dir")/keysafe"
    
    # Create directory structure if needed
    if [[ ! -d "$keysafe_dir/tokens" ]]; then
        if ! mkdir -p "$keysafe_dir/tokens"; then
            echo "ERROR: Failed to create keysafe directory: $keysafe_dir" >&2
            return 2
        fi
    fi
    
    echo "$keysafe_dir"
    return 0
}

#===============================================================================
# keysafe_issue_token
# -------------------
# Issues a new single-use authentication token for authorized operations.
#
# Behaviour:
#   - Checks keysafe mode from cluster config (open/secure)
#   - In open mode: Generates UUID token with clear INSECURE warning
#   - In secure mode: Uses Biscuit-auth to generate cryptographic token
#   - Creates token file with metadata in keysafe/tokens/ directory
#   - Token file contains: NODE_MAC, NODE_ID, PURPOSE, ISSUED, EXPIRES
#   - Sets 60 second expiration from issue time
#
# Arguments:
#   $1 - client_mac: MAC address of requesting client (required)
#   $2 - purpose: Token purpose (e.g., "backup") (required)
#   $3 - node_id: Node identifier (optional, defaults to "unknown")
#
# Returns:
#   Prints token to stdout on success
#   Returns 1 if keysafe_dir cannot be determined
#   Returns 2 if token file creation fails
#   Returns 3 if required arguments missing
#===============================================================================
keysafe_issue_token() {
    local client_mac="$1"
    local purpose="$2"
    local node_id="${3:-unknown}"
    local keysafe_dir
    local token
    local token_file
    local issued
    local expires
    local mode
    
    # Validate required arguments
    if [[ -z "$client_mac" || -z "$purpose" ]]; then
        echo "ERROR: Missing required arguments (client_mac, purpose)" >&2
        return 3
    fi
    
    # Get keysafe directory
    keysafe_dir=$(get_keysafe_dir) || return 1
    
    # Determine keysafe mode from cluster config
    local cluster_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
    local cluster_config="$(readlink -f "$cluster_dir")/cluster.conf"
    
    if [[ -f "$cluster_config" ]]; then
        source "$cluster_config"
    fi
    
    mode="${HPS_KEYSAFE_MODE:-open}"
    
    # Get current timestamp
    issued=$(date +%s)
    expires=$((issued + 60))
    
    # Generate token based on mode
    case "$mode" in
        open)
            # OPEN MODE - INSECURE - FOR PROTOTYPING ONLY
            token=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
            echo "WARNING: Keysafe in OPEN mode - token is NOT cryptographically secure" >&2
            ;;
        secure)
            # SECURE MODE - Biscuit-auth token generation
            # TODO: Implement Biscuit token generation when binary available
            echo "ERROR: Secure mode not yet implemented - set HPS_KEYSAFE_MODE=open" >&2
            return 4
            ;;
        *)
            echo "ERROR: Invalid keysafe mode: $mode" >&2
            return 5
            ;;
    esac
    
    # Create token file with metadata
    token_file="$keysafe_dir/tokens/$token"
    
    cat > "$token_file" <<EOF
NODE_MAC=$client_mac
NODE_ID=$node_id
PURPOSE=$purpose
ISSUED=$issued
EXPIRES=$expires
MODE=$mode
EOF
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create token file: $token_file" >&2
        return 2
    fi
    
    # Return token to caller
    echo "$token"
    return 0
}

#===============================================================================
# keysafe_validate_token
# ----------------------
# Validates and consumes a single-use token.
#
# Behaviour:
#   - Checks if token file exists (whitelist approach)
#   - Verifies token has not expired (60 second lifetime)
#   - In open mode: Basic file-based validation
#   - In secure mode: Cryptographic Biscuit validation
#   - Immediately deletes token file on successful validation (consume)
#   - Optional purpose validation if purpose argument provided
#
# Arguments:
#   $1 - token: Token string to validate (required)
#   $2 - purpose: Expected purpose (optional, validates if provided)
#
# Returns:
#   0 if token valid and consumed
#   1 if keysafe_dir cannot be determined
#   2 if token file does not exist (invalid/already consumed)
#   3 if token expired
#   4 if purpose mismatch
#   5 if required arguments missing
#===============================================================================
keysafe_validate_token() {
    local token="$1"
    local expected_purpose="$2"
    local keysafe_dir
    local token_file
    local current_time
    
    # Validate required arguments
    if [[ -z "$token" ]]; then
        echo "ERROR: Token argument required" >&2
        return 5
    fi
    
    # Get keysafe directory
    keysafe_dir=$(get_keysafe_dir) || return 1
    
    token_file="$keysafe_dir/tokens/$token"
    
    # Check if token exists (whitelist validation)
    if [[ ! -f "$token_file" ]]; then
        echo "ERROR: Invalid or already consumed token" >&2
        return 2
    fi
    
    # Load token metadata
    source "$token_file"
    
    # Validate expiration
    current_time=$(date +%s)
    if [[ $current_time -gt $EXPIRES ]]; then
        echo "ERROR: Token expired" >&2
        rm -f "$token_file"
        return 3
    fi
    
    # Validate purpose if provided
    if [[ -n "$expected_purpose" && "$PURPOSE" != "$expected_purpose" ]]; then
        echo "ERROR: Token purpose mismatch (expected: $expected_purpose, got: $PURPOSE)" >&2
        return 4
    fi
    
    # Token valid - consume immediately by deleting file
    if ! rm -f "$token_file"; then
        echo "WARNING: Token validated but consumption (delete) failed" >&2
    fi
    
    return 0
}

#===============================================================================
# keysafe_cleanup_expired
# -----------------------
# Removes expired tokens from the keysafe tokens directory.
#
# Behaviour:
#   - Scans all token files in keysafe/tokens/
#   - Sources each token file to read EXPIRES timestamp
#   - Deletes tokens where current time exceeds EXPIRES
#   - Logs cleanup actions if HPS_LOG_DIR is set
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 if keysafe_dir cannot be determined
#===============================================================================
keysafe_cleanup_expired() {
    local keysafe_dir
    local token_file
    local current_time
    local cleaned=0
    
    keysafe_dir=$(get_keysafe_dir) || return 1
    
    current_time=$(date +%s)
    
    # Iterate through token files
    for token_file in "$keysafe_dir/tokens"/*; do
        # Skip if no tokens exist
        [[ -f "$token_file" ]] || continue
        
        # Load token metadata
        unset EXPIRES
        source "$token_file"
        
        # Remove if expired
        if [[ -n "$EXPIRES" && $current_time -gt $EXPIRES ]]; then
            rm -f "$token_file"
            ((cleaned++))
        fi
    done
    
    if [[ $cleaned -gt 0 ]]; then
        echo "Cleaned up $cleaned expired token(s)" >&2
    fi
    
    return 0
}

#===============================================================================
# keysafe_handle_token_request
# -----------------------------
# Server-side handler for token requests from boot_manager CGI.
#
# Behaviour:
#   - Validates request parameters (MAC, purpose)
#   - Looks up node HOSTNAME from host_config using MAC
#   - Logs all operations and errors via hps_log
#   - Issues token via keysafe_issue_token
#   - Returns token string or error message
#
# Arguments:
#   $1 - mac: Client MAC address from boot_manager (required)
#   $2 - purpose: Token purpose (e.g., "backup") (required)
#
# Dependencies:
#   - host_config function (from boot_manager/host management)
#   - hps_log function (for logging)
#
# Returns:
#   Prints token to stdout on success
#   Prints "ERROR: message" on failure
#   Returns 0 on success, non-zero on failure
#===============================================================================
keysafe_handle_token_request() {
    local mac="$1"
    local purpose="$2"
    local node_id
    local token
    local retval
    
    # Validate MAC parameter
    if [[ -z "$mac" ]]; then
        hps_log warn "keysafe_handle_token_request: Missing MAC address"
        echo "ERROR: Missing MAC address"
        return 1
    fi
    
    # Validate purpose parameter
    if [[ -z "$purpose" ]]; then
        hps_log warn "keysafe_handle_token_request: Missing purpose parameter from MAC: $mac"
        echo "ERROR: Missing purpose parameter"
        return 2
    fi
    
    # Get node hostname from host config
    node_id=$(host_config "$mac" get HOSTNAME 2>/dev/null)
    
    if [[ -z "$node_id" ]]; then
        hps_log warn "keysafe_handle_token_request: Could not determine HOSTNAME for MAC: $mac"
        node_id="unknown"
    fi
    
    hps_log info "keysafe_handle_token_request: Issuing token for MAC: $mac, Node: $node_id, Purpose: $purpose"
    
    # Issue token
    token=$(keysafe_issue_token "$mac" "$purpose" "$node_id" 2>&1)
    retval=$?
    
    if [[ $retval -eq 0 ]]; then
        hps_log debug "keysafe_handle_token_request: Token issued successfully for $node_id"
        echo "$token"
        return 0
    else
        hps_log warn "keysafe_handle_token_request: Failed to issue token for $node_id (MAC: $mac) - Error code: $retval - $token"
        echo "ERROR: Failed to issue token"
        return 3
    fi
}
