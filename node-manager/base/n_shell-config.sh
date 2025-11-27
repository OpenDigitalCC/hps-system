#===============================================================================
# HPS Node Shell Configuration Functions
# For Alpine Linux nodes (TCH, SCH, Rescue)
#===============================================================================


#===============================================================================
# n_configure_bash_shell
# ----------------------
# Configure bash as default shell and source HPS functions on login.
#
# Behaviour:
#   - Changes /bin/sh symlink from busybox to bash
#   - Creates /etc/profile.d/hps.sh drop-in to auto-load HPS functions
#   - Uses n_safe_function_runner to display rescue help/config on login
#   - Sets correct permissions (755) on profile drop-in
#   - Logs all operations
#   - Idempotent: Safe to run multiple times
#
# Prerequisites:
#   - Bash must be installed (assumes already present)
#   - n_remote_log must be available for logging
#   - n_safe_function_runner must be in function library
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 if shell symlink change fails
#   2 if profile.d configuration fails
#
# Example usage:
#   n_configure_bash_shell
#
# Notes:
#   - Changes take effect on next login or script execution
#   - Current shell session unaffected
#   - Makes bash the system-wide default shell
#
#===============================================================================
n_configure_bash_shell() {
  n_remote_log "[INFO] Configuring bash as default shell"
  
  echo "Configuring bash as default shell..." >&2
  
  # Step 1: Verify bash is installed
  if ! command -v bash >/dev/null 2>&1; then
    echo "ERROR: bash not found, cannot configure" >&2
    n_remote_log "[ERROR] bash not installed"
    return 1
  fi
  
  local bash_path
  bash_path=$(command -v bash)
  echo "  Found bash at: $bash_path" >&2
  
  # Step 2: Change /bin/sh symlink from busybox to bash
  echo "  Changing /bin/sh symlink..." >&2
  
  # Check current symlink
  if [[ -L /bin/sh ]]; then
    local current_target
    current_target=$(readlink /bin/sh)
    echo "    Current: /bin/sh -> $current_target" >&2
    
    # If already pointing to bash, skip
    if [[ "$current_target" == "/bin/bash" ]] || [[ "$current_target" == "bash" ]]; then
      echo "    Already configured correctly" >&2
      n_remote_log "[DEBUG] /bin/sh already points to bash"
    else
      # Create/update symlink atomically with -sf
      if ln -sf /bin/bash /bin/sh 2>/dev/null; then
        echo "    ✓ Changed: /bin/sh -> /bin/bash" >&2
        n_remote_log "[INFO] Changed /bin/sh symlink to bash"
      else
        echo "    ✗ Failed to change symlink" >&2
        n_remote_log "[ERROR] Failed to change /bin/sh symlink"
        return 1
      fi
    fi
  else
    echo "    WARNING: /bin/sh is not a symlink" >&2
    n_remote_log "[WARNING] /bin/sh is not a symlink, skipping"
  fi
  
  # Verify symlink
  if [[ -L /bin/sh ]]; then
    local new_target
    new_target=$(readlink /bin/sh)
    if [[ "$new_target" == "/bin/bash" ]] || [[ "$new_target" == "bash" ]]; then
      echo "    Verified: /bin/sh -> $new_target" >&2
    else
      echo "    WARNING: Verification failed, symlink points to: $new_target" >&2
      n_remote_log "[WARNING] /bin/sh verification failed: points to $new_target"
    fi
  fi
  
  echo "" >&2
  
  # Step 3: Create profile.d drop-in
  echo "  Creating /etc/profile.d/hps.sh..." >&2
  
  # Ensure profile.d directory exists
  mkdir -p /etc/profile.d
  
  # Create the profile drop-in (simple - delegates to n_safe_function_runner)
  cat > /etc/profile.d/hps.sh << 'EOF'
#!/bin/bash
# HPS Node Functions - Auto-loaded on login

# Source the functions cache (contains n_safe_function_runner)
[ -f /srv/hps/lib/hps-functions-cache.sh ] && . /srv/hps/lib/hps-functions-cache.sh 2>/dev/null

# Display rescue mode help and configuration on login
if [ -n "$PS1" ]; then
  # Use safe runner to execute rescue functions (assumes it exists)
  n_safe_function_runner n_rescue_show_help || true
  echo "" # Blank line for separation
  n_safe_function_runner n_rescue_display_config || true
fi
EOF
  
  local create_rc=$?
  
  if [[ $create_rc -ne 0 ]]; then
    echo "    ✗ Failed to create profile drop-in" >&2
    n_remote_log "[ERROR] Failed to create /etc/profile.d/hps.sh"
    return 2
  fi
  
  # Set permissions
  if chmod 755 /etc/profile.d/hps.sh 2>/dev/null; then
    echo "    ✓ Created and set permissions (755)" >&2
    n_remote_log "[INFO] Created /etc/profile.d/hps.sh"
  else
    echo "    ✗ Created but failed to set permissions" >&2
    n_remote_log "[WARNING] Created /etc/profile.d/hps.sh but chmod failed"
    return 2
  fi
  
  # Verify file exists and is readable
  if [[ -r /etc/profile.d/hps.sh ]]; then
    local line_count
    line_count=$(wc -l < /etc/profile.d/hps.sh)
    echo "    Verified: File exists ($line_count lines)" >&2
  else
    echo "    WARNING: File not readable" >&2
    n_remote_log "[WARNING] /etc/profile.d/hps.sh not readable"
  fi
  
  echo "" >&2
  echo "✓ Shell configuration complete" >&2
  echo "  Changes take effect on next login" >&2
  
  n_remote_log "[INFO] Bash shell configuration complete"
  return 0
}
