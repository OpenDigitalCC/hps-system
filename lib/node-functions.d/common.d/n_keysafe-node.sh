#
# keysafe_node.sh - Client-side token-based authentication for HPS nodes
#
# This library provides node-side functions for requesting and using tokens
# from the IPS keysafe service.
#
# Location: Node library (auto-distributed from IPS)
# Platform: Compute nodes only
#

#===============================================================================
# n_keysafe_request_token
# -----------------------
# Requests a single-use authentication token from IPS keysafe.
#
# Behaviour:
#   - Uses n_ips_command to communicate with boot_manager CGI
#   - Passes purpose parameter to indicate token usage
#   - MAC address authentication handled automatically by boot_manager
#   - Returns token string or error message
#   - Token is valid for 60 seconds, single-use only
#
# Arguments:
#   $1 - purpose: Token purpose (e.g., "backup", "restore") (required)
#
# Dependencies:
#   - n_ips_command function (node communication wrapper)
#
# Returns:
#   Prints token to stdout on success
#   Returns 1 if n_ips_command fails
#   Returns 2 if purpose argument missing
#   Returns 3 if response contains ERROR
#
# Example:
#   token=$(n_keysafe_request_token "backup")
#   if [[ $? -eq 0 ]]; then
#       echo "Token: $token"
#   fi
#===============================================================================
n_keysafe_request_token() {
    local purpose="$1"
    local response
    
    # Validate required argument
    if [[ -z "$purpose" ]]; then
        echo "ERROR: Purpose argument required" >&2
        return 2
    fi
    
    # Request token from IPS via n_ips_command wrapper
    response=$(n_ips_command keysafe_request_token purpose="$purpose" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to communicate with IPS" >&2
        return 1
    fi
    
    # Check if response contains an error
    if echo "$response" | grep -q "^ERROR:"; then
        echo "$response" >&2
        return 3
    fi
    
    # Return token (filter out any warnings or extra output)
    echo "$response" | grep -v "^WARNING:" | grep -v "^Content-Type:" | head -n1
    return 0
}
