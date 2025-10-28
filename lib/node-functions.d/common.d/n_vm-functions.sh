#===============================================================================
# n_vm_create
# -----------
# Create and start a VM on local TCH node using virt-install.
#
# Usage:
#   n_vm_create <vm_identifier> [title] [description]
#
# Parameters:
#   vm_identifier - Unique VM identifier/GUID (required)
#   title - Human-readable VM title (optional, overrides config)
#   description - VM description (optional, overrides config)
#
# Behavior:
#   - Fetches VM configuration from IPS via n_ips_command
#   - Parses key=value response into variables
#   - Validates required fields (name, cpu_count, ram_mb, provision_method)
#   - Verifies provision_method is "virt-install" (only supported method in v1)
#   - Builds virt-install command with all disks and networks
#   - Executes virt-install to create and start VM
#   - Logs all operations via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure
#   2 on configuration fetch failure
#   3 on required field missing
#   4 on unsupported provision method
#   5 on virt-install execution failure
#
# Example usage:
#   n_vm_create "550e8400-e29b-41d4-a716-446655440000"
#   n_vm_create "550e8400-e29b-41d4-a716-446655440000" "Web Server" "Production web app"
#
#===============================================================================
n_vm_create() {
  local vm_identifier="$1"
  local override_title="$2"
  local override_description="$3"
  
  # Configuration variables
  local vm_name=""
  local cpu_count=""
  local ram_mb=""
  local provision_method=""
  local title=""
  local description=""
  
  # Arrays for disks and networks
  local -a disks_a=()
  local -a disks_b=()
  local -a networks=()
  
  # virt-install command components
  local virt_install_cmd=""
  local config_output=""
  
  # Step 1: Parameter validation
  if [ $# -lt 1 ]; then
    n_remote_log "ERROR: n_vm_create: Missing vm_identifier parameter"
    return 1
  fi
  
  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_create: vm_identifier cannot be empty"
    return 1
  fi
  
  n_remote_log "INFO: n_vm_create: Starting VM creation for ${vm_identifier}"
  
  # Step 2: Fetch VM configuration from IPS
  n_remote_log "INFO: n_vm_create: Fetching configuration from IPS"
  config_output=$(n_ips_command vm get_config vm_id="${vm_identifier}" 2>&1)
  
  if [ $? -ne 0 ]; then
    n_remote_log "ERROR: n_vm_create: Failed to fetch configuration: ${config_output}"
    return 2
  fi
  
  if [ -z "$config_output" ]; then
    n_remote_log "ERROR: n_vm_create: Empty configuration returned from IPS"
    return 2
  fi
  
  # Step 3: Parse configuration
  n_remote_log "INFO: n_vm_create: Parsing configuration"
  
  while IFS='=' read -r key value; do
    # Skip empty lines and comments
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    
    # Trim whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    
    case "$key" in
      name)
        vm_name="$value"
        ;;
      cpu_count)
        cpu_count="$value"
        ;;
      ram_mb)
        ram_mb="$value"
        ;;
      provision_method)
        provision_method="$value"
        ;;
      title)
        title="$value"
        ;;
      description)
        description="$value"
        ;;
      disk_*_a)
        disks_a+=("$value")
        ;;
      disk_*_b)
        disks_b+=("$value")
        ;;
      vxlan_*)
        networks+=("$value")
        ;;
      error)
        n_remote_log "ERROR: n_vm_create: IPS returned error: ${value}"
        return 2
        ;;
    esac
  done <<< "$config_output"
  
  # Apply overrides from parameters
  [ -n "$override_title" ] && title="$override_title"
  [ -n "$override_description" ] && description="$override_description"
  
  # Step 4: Validate required fields
  if [ -z "$vm_name" ]; then
    n_remote_log "ERROR: n_vm_create: Missing required field: name"
    return 3
  fi
  
  if [ -z "$cpu_count" ]; then
    n_remote_log "ERROR: n_vm_create: Missing required field: cpu_count"
    return 3
  fi
  
  if [ -z "$ram_mb" ]; then
    n_remote_log "ERROR: n_vm_create: Missing required field: ram_mb"
    return 3
  fi
  
  if [ -z "$provision_method" ]; then
    n_remote_log "ERROR: n_vm_create: Missing required field: provision_method"
    return 3
  fi
  
  # Step 5: Verify provision method
  if [ "$provision_method" != "virt-install" ]; then
    n_remote_log "ERROR: n_vm_create: Unsupported provision_method: ${provision_method}"
    return 4
  fi
  
  n_remote_log "INFO: n_vm_create: Configuration validated - Name: ${vm_name}, CPUs: ${cpu_count}, RAM: ${ram_mb}MB"
  
  # Step 6: Build virt-install command
  virt_install_cmd="virt-install"
  virt_install_cmd="${virt_install_cmd} --connect qemu:///system"
  virt_install_cmd="${virt_install_cmd} --name ${vm_name}"
  virt_install_cmd="${virt_install_cmd} --memory ${ram_mb}"
  virt_install_cmd="${virt_install_cmd} --vcpus ${cpu_count}"
  
  # Add disks - primary paths (disk_*_a)
  if [ ${#disks_a[@]} -eq 0 ] && [ ${#disks_b[@]} -eq 0 ]; then
    # No disks - explicitly specify diskless VM
    virt_install_cmd="${virt_install_cmd} --disk none"
  else
    for disk in "${disks_a[@]}"; do
      # For existing block devices, don't specify size
      virt_install_cmd="${virt_install_cmd} --disk ${disk},bus=virtio"
    done
    
    # Add disks - secondary paths (disk_*_b) for independent mirroring
    for disk in "${disks_b[@]}"; do
      virt_install_cmd="${virt_install_cmd} --disk ${disk},bus=virtio"
    done
  fi
  
  # Add networks
  if [ ${#networks[@]} -eq 0 ]; then
    # No networks specified - no network interface
    n_remote_log "INFO: n_vm_create: No networks specified, VM will have no network interfaces"
  else
    for bridge in "${networks[@]}"; do
      virt_install_cmd="${virt_install_cmd} --network bridge=${bridge}"
    done
    n_remote_log "INFO: n_vm_create: Configured ${#networks[@]} network interface(s)"
  fi
  
  # Add graphics and boot options
  virt_install_cmd="${virt_install_cmd} --graphics vnc,listen=0.0.0.0"
  virt_install_cmd="${virt_install_cmd} --boot network,hd"
  virt_install_cmd="${virt_install_cmd} --import"
  virt_install_cmd="${virt_install_cmd} --noautoconsole"
  
  # Add OS variant (Alpine Linux)
  virt_install_cmd="${virt_install_cmd} --os-variant alpinelinux3.20"
  
  # Add metadata if provided (quote values with spaces)
  if [ -n "$title" ] && [ -n "$description" ]; then
    virt_install_cmd="${virt_install_cmd} --metadata title=\"${title}\",description=\"${description}\""
  elif [ -n "$title" ]; then
    virt_install_cmd="${virt_install_cmd} --metadata title=\"${title}\""
  elif [ -n "$description" ]; then
    virt_install_cmd="${virt_install_cmd} --metadata description=\"${description}\""
  fi
  
  # Log disk configuration
  if [ ${#disks_a[@]} -eq 0 ]; then
    n_remote_log "INFO: n_vm_create: Diskless VM configuration"
  else
    n_remote_log "INFO: n_vm_create: Configured ${#disks_a[@]} primary disk(s)"
    [ ${#disks_b[@]} -gt 0 ] && n_remote_log "INFO: n_vm_create: Configured ${#disks_b[@]} secondary disk(s) (independent targets for OS-level mirroring)"
  fi
  
  # Step 7: Execute virt-install
  n_remote_log "INFO: n_vm_create: Executing virt-install for ${vm_name}"
  n_remote_log "DEBUG: n_vm_create: Command: ${virt_install_cmd}"
  
  local virt_output
  virt_output=$(eval "$virt_install_cmd" 2>&1)
  local virt_result=$?
  
  if [ $virt_result -eq 0 ]; then
    n_remote_log "INFO: n_vm_create: Successfully created VM ${vm_name}"
    return 0
  else
    n_remote_log "ERROR: n_vm_create: virt-install failed with exit code ${virt_result}"
    n_remote_log "ERROR: n_vm_create: Output: ${virt_output}"
    return 5
  fi
}



#===============================================================================
# n_vm_start
# ----------
# Start an existing stopped VM.
#
# Usage:
#   n_vm_start <vm_identifier>
#
# Parameters:
#   vm_identifier - VM name/identifier (required)
#
# Behavior:
#   - Validates vm_identifier parameter
#   - Executes virsh start command
#   - Logs success/failure via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure or virsh failure
#
# Example usage:
#   n_vm_start "550e8400-e29b-41d4-a716-446655440000"
#
#===============================================================================
n_vm_start() {
  local vm_identifier="$1"

  # Validate parameter
  if [ $# -ne 1 ]; then
    n_remote_log "ERROR: n_vm_start: Missing vm_identifier parameter"
    return 1
  fi

  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_start: vm_identifier cannot be empty"
    return 1
  fi

  # Log operation
  n_remote_log "INFO: n_vm_start: Starting VM ${vm_identifier}"

  # Execute virsh start
  local output
  output=$(virsh --connect qemu:///system start "${vm_identifier}" 2>&1)
  local result=$?

  if [ $result -eq 0 ]; then
    n_remote_log "INFO: n_vm_start: Successfully started VM ${vm_identifier}"
    return 0
  else
    n_remote_log "ERROR: n_vm_start: Failed to start VM ${vm_identifier}"
    n_remote_log "ERROR: n_vm_start: ${output}"
    return 1
  fi
}

#===============================================================================
# n_vm_stop
# ---------
# Stop a running VM.
#
# Usage:
#   n_vm_stop <vm_identifier> [force]
#
# Parameters:
#   vm_identifier - VM name/identifier (required)
#   force - If "force", use immediate shutdown (optional)
#
# Behavior:
#   - Validates vm_identifier parameter
#   - If force="force": executes virsh destroy (immediate)
#   - Otherwise: executes virsh shutdown (graceful)
#   - Logs success/failure via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure or virsh failure
#
# Example usage:
#   n_vm_stop "550e8400-e29b-41d4-a716-446655440000"
#   n_vm_stop "550e8400-e29b-41d4-a716-446655440000" "force"
#
#===============================================================================
n_vm_stop() {
  local vm_identifier="$1"
  local force="$2"

  # Validate parameter
  if [ $# -lt 1 ]; then
    n_remote_log "ERROR: n_vm_stop: Missing vm_identifier parameter"
    return 1
  fi

  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_stop: vm_identifier cannot be empty"
    return 1
  fi

  # Determine stop method
  local stop_command
  local stop_method
  if [ "$force" = "force" ]; then
    stop_command="destroy"
    stop_method="force"
  else
    stop_command="shutdown"
    stop_method="graceful"
  fi

  # Log operation
  n_remote_log "INFO: n_vm_stop: Stopping VM ${vm_identifier} (${stop_method})"

  # Execute virsh stop
  local output
  output=$(virsh --connect qemu:///system "${stop_command}" "${vm_identifier}" 2>&1)
  local result=$?

  if [ $result -eq 0 ]; then
    n_remote_log "INFO: n_vm_stop: Successfully stopped VM ${vm_identifier}"
    return 0
  else
    n_remote_log "ERROR: n_vm_stop: Failed to stop VM ${vm_identifier}"
    n_remote_log "ERROR: n_vm_stop: ${output}"
    return 1
  fi
}

#===============================================================================
# n_vm_pause
# ----------
# Pause (suspend) a running VM.
#
# Usage:
#   n_vm_pause <vm_identifier>
#
# Parameters:
#   vm_identifier - VM name/identifier (required)
#
# Behavior:
#   - Validates vm_identifier parameter
#   - Executes virsh suspend command
#   - Logs success/failure via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure or virsh failure
#
# Example usage:
#   n_vm_pause "550e8400-e29b-41d4-a716-446655440000"
#
#===============================================================================
n_vm_pause() {
  local vm_identifier="$1"

  # Validate parameter
  if [ $# -ne 1 ]; then
    n_remote_log "ERROR: n_vm_pause: Missing vm_identifier parameter"
    return 1
  fi

  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_pause: vm_identifier cannot be empty"
    return 1
  fi

  # Log operation
  n_remote_log "INFO: n_vm_pause: Pausing VM ${vm_identifier}"

  # Execute virsh suspend
  local output
  output=$(virsh --connect qemu:///system suspend "${vm_identifier}" 2>&1)
  local result=$?

  if [ $result -eq 0 ]; then
    n_remote_log "INFO: n_vm_pause: Successfully paused VM ${vm_identifier}"
    return 0
  else
    n_remote_log "ERROR: n_vm_pause: Failed to pause VM ${vm_identifier}"
    n_remote_log "ERROR: n_vm_pause: ${output}"
    return 1
  fi
}

#===============================================================================
# n_vm_unpause
# ------------
# Unpause (resume) a paused VM.
#
# Usage:
#   n_vm_unpause <vm_identifier>
#
# Parameters:
#   vm_identifier - VM name/identifier (required)
#
# Behavior:
#   - Validates vm_identifier parameter
#   - Executes virsh resume command
#   - Logs success/failure via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure or virsh failure
#
# Example usage:
#   n_vm_unpause "550e8400-e29b-41d4-a716-446655440000"
#
#===============================================================================
n_vm_unpause() {
  local vm_identifier="$1"

  # Validate parameter
  if [ $# -ne 1 ]; then
    n_remote_log "ERROR: n_vm_unpause: Missing vm_identifier parameter"
    return 1
  fi

  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_unpause: vm_identifier cannot be empty"
    return 1
  fi

  # Log operation
  n_remote_log "INFO: n_vm_unpause: Unpausing VM ${vm_identifier}"

  # Execute virsh resume
  local output
  output=$(virsh --connect qemu:///system resume "${vm_identifier}" 2>&1)
  local result=$?

  if [ $result -eq 0 ]; then
    n_remote_log "INFO: n_vm_unpause: Successfully unpaused VM ${vm_identifier}"
    return 0
  else
    n_remote_log "ERROR: n_vm_unpause: Failed to unpause VM ${vm_identifier}"
    n_remote_log "ERROR: n_vm_unpause: ${output}"
    return 1
  fi
}

#===============================================================================
# n_vm_destroy
# ------------
# Stop and completely remove a VM.
#
# Usage:
#   n_vm_destroy <vm_identifier>
#
# Parameters:
#   vm_identifier - VM name/identifier (required)
#
# Behavior:
#   - Validates vm_identifier parameter
#   - Force stops VM (ignores if already stopped)
#   - Undefines VM and removes all storage
#   - Logs all steps via n_remote_log
#
# Returns:
#   0 on success
#   1 on parameter validation failure or undefine failure
#
# Example usage:
#   n_vm_destroy "550e8400-e29b-41d4-a716-446655440000"
#
#===============================================================================
n_vm_destroy() {
  local vm_identifier="$1"

  # Validate parameter
  if [ $# -ne 1 ]; then
    n_remote_log "ERROR: n_vm_destroy: Missing vm_identifier parameter"
    return 1
  fi

  if [ -z "$vm_identifier" ]; then
    n_remote_log "ERROR: n_vm_destroy: vm_identifier cannot be empty"
    return 1
  fi

  # Log operation
  n_remote_log "INFO: n_vm_destroy: Destroying VM ${vm_identifier}"

  # Force stop VM (ignore errors if already stopped)
  n_remote_log "INFO: n_vm_destroy: Force stopping VM ${vm_identifier}"
  virsh --connect qemu:///system destroy "${vm_identifier}" 2>/dev/null || true

  # Undefine VM
  n_remote_log "INFO: n_vm_destroy: Undefining VM ${vm_identifier}"
  local output
  output=$(virsh --connect qemu:///system undefine "${vm_identifier}" --remove-all-storage 2>&1)
  local result=$?

  if [ $result -eq 0 ]; then
    n_remote_log "INFO: n_vm_destroy: Successfully destroyed VM ${vm_identifier}"
    return 0
  else
    n_remote_log "ERROR: n_vm_destroy: Failed to undefine VM ${vm_identifier}"
    n_remote_log "ERROR: n_vm_destroy: ${output}"
    return 1
  fi
}


