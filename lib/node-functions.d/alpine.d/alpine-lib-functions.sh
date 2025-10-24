


n_start_modloop () {
  rc-service modloop status || rc-service modloop start
}



n_start_base_services() {
  n_remote_log "Starting base system services..."
  
  local services=(
    "hwdrivers"    # Hardware drivers
    "modloop"      # Kernel modules
    "fsck"         # Filesystem check
    "root"         # Root filesystem
    "localmount"   # Local filesystems
    "hostname"     # System hostname
  )
  
  for service in "${services[@]}"; do
    if ! rc-service "$service" status >/dev/null 2>&1; then
      n_remote_log "Starting $service..."
      rc-service "$service" start || n_remote_log "WARNING: Failed to start $service"
    fi
  done
  
  return 0
}

#===============================================================================
# n_load_kernel_module
# --------------------
# Load a kernel module from mounted modloop
#
# Behaviour:
#   - Searches for module in /.modloop/modules/$(uname -r)/
#   - Loads module using insmod
#   - Handles both .ko and .ko.gz files
#   - Checks if module is already loaded before attempting load
#
# Arguments:
#   $1 - module_name : Name of module to load (without .ko extension)
#
# Returns:
#   0 if module loaded successfully or already loaded
#   1 if modloop not mounted
#   2 if module file not found
#   3 if insmod failed
#
# Example usage:
#   n_load_kernel_module 8021q
#   n_load_kernel_module bonding
#
#===============================================================================
n_load_kernel_module() {
  local module_name="${1:?Usage: n_load_kernel_module <module_name>}"
  
  # Check if already loaded
  if lsmod | grep -q "^${module_name} "; then
    echo "Module already loaded: $module_name"
    return 0
  fi
  
  # Verify modloop is mounted
  local modloop_mount="/.modloop"
  if ! mountpoint -q "$modloop_mount" 2>/dev/null; then
    echo "ERROR: Modloop not mounted at $modloop_mount" >&2
    return 1
  fi
  
  # Detect kernel version
  local kver=$(uname -r)
  local module_dir="$modloop_mount/modules/$kver"
  
  if [[ ! -d "$module_dir" ]]; then
    echo "ERROR: Module directory not found: $module_dir" >&2
    return 1
  fi
  
  # Find module file (handles .ko or .ko.gz)
  local module_file=$(find "$module_dir" -name "${module_name}.ko*" | head -n1)
  
  if [[ -z "$module_file" ]]; then
    echo "ERROR: Module not found: $module_name" >&2
    return 2
  fi
  
  # Load module
  echo "Loading module: $module_name from $module_file"
  if ! insmod "$module_file" 2>/dev/null; then
    echo "ERROR: Failed to load module: $module_name" >&2
    return 3
  fi
  
  echo "Successfully loaded module: $module_name"
  return 0
}


#===============================================================================
# n_configure_reboot_logging
# --------------------------
# Configure reboot logging on TCH node to track all reboot attempts.
#
# Prerequisites:
#   - Alpine Linux base system with BusyBox
#   - bash installed
#   - Node functions available via hps-bootstrap-lib.sh
#
# Behaviour:
#   - Creates wrapper scripts that use bash and source HPS functions
#   - Logs all reboot attempts to IPS before reboot occurs
#   - Preserves original busybox symlinks in /sbin
#
# Returns:
#   0 on success
#===============================================================================
n_configure_reboot_logging() {
    echo "[HPS] Configuring reboot logging..."
    n_remote_log "Configuring reboot logging on TCH node"
    
    # Ensure bash is available
    if ! command -v bash >/dev/null 2>&1; then
        echo "[HPS] ERROR: bash not found, required for reboot logging"
        n_remote_log "ERROR: bash not found on TCH node"
        return 1
    fi
    
    # Ensure /usr/local/sbin exists
    mkdir -p /usr/local/sbin
    
    # 1. Ensure any broken symlinks are fixed first
    for cmd in reboot poweroff halt; do
        if [ -L "/sbin/${cmd}" ] && [ ! -e "/sbin/${cmd}" ]; then
            echo "[HPS] Fixing broken /sbin/${cmd} symlink..."
            rm -f "/sbin/${cmd}"
            ln -s /bin/busybox "/sbin/${cmd}"
        fi
    done
    
    # 2. Create wrapper scripts in /usr/local/sbin for each command
    for cmd in reboot poweroff halt; do
        cat > "/usr/local/sbin/${cmd}" <<EOF
#!/bin/bash
# HPS TCH Reboot Logger for ${cmd}

# Source HPS node functions
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    source /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions >/dev/null 2>&1
fi

TIMESTAMP="\$(date '+%Y-%m-%d %H:%M:%S')"

# Log to IPS if available
if command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "REBOOT: ${cmd} \$@ initiated on TCH node at \${TIMESTAMP}"
    
    if command -v n_remote_host_variable >/dev/null 2>&1; then
        n_remote_host_variable "last_reboot_command" "${cmd} \$@"
        n_remote_host_variable "last_reboot_time" "\${TIMESTAMP}"
        n_remote_host_variable "status" "rebooting"
    fi
else
    # Log locally as fallback
    echo "[HPS] Warning: n_remote_log not available" >&2
fi

# Log locally
logger -t hps-reboot "Executing ${cmd} \$@ at \${TIMESTAMP}"

# Call the real command from /sbin
exec /sbin/${cmd} "\$@"
EOF
        
        chmod +x "/usr/local/sbin/${cmd}"
        echo "[HPS] Created logging wrapper for ${cmd}"
    done
    
    # 3. Handle shutdown if it exists
    if /bin/busybox --list | grep -q "^shutdown$"; then
        cat > "/usr/local/sbin/shutdown" <<'EOF'
#!/bin/bash
# HPS TCH Reboot Logger for shutdown

# Source HPS node functions
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    source /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions >/dev/null 2>&1
fi

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Log to IPS if available
if command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "REBOOT: shutdown $@ initiated on TCH node at ${TIMESTAMP}"
    
    if command -v n_remote_host_variable >/dev/null 2>&1; then
        n_remote_host_variable "last_reboot_command" "shutdown $@"
        n_remote_host_variable "last_reboot_time" "${TIMESTAMP}"
        n_remote_host_variable "status" "shutting_down"
    fi
fi

# Log locally
logger -t hps-reboot "Executing shutdown $@ at ${TIMESTAMP}"

# Call the real command from /sbin
exec /sbin/shutdown "$@"
EOF
        chmod +x "/usr/local/sbin/shutdown"
        echo "[HPS] Created logging wrapper for shutdown"
    fi
    
    # 4. Ensure /usr/local/sbin is first in PATH
    if ! grep -q "PATH=\"/usr/local/sbin:" /etc/profile 2>/dev/null; then
        sed -i '1i export PATH="/usr/local/sbin:$PATH"' /etc/profile
    fi
    export PATH="/usr/local/sbin:$PATH"
    
    # 5. Add OpenRC shutdown hook (also using bash)
    mkdir -p /etc/local.d
    cat > /etc/local.d/hps-shutdown.stop <<'EOF'
#!/bin/bash
# HPS shutdown logging hook

# Source HPS node functions
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    source /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions >/dev/null 2>&1
fi

if command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "TCH node shutting down via init system"
fi
EOF
    chmod +x /etc/local.d/hps-shutdown.stop
    
    # Enable local service if not already
    rc-update add local default 2>/dev/null || true
    
    n_remote_log "Reboot logging configured successfully"
    n_remote_host_variable "reboot_logging" "enabled"
    
    echo "[HPS] Reboot logging configured. Wrappers installed in /usr/local/sbin/"
    
    return 0
}




#===============================================================================
# n_install_apk_packages_from_ips
# --------------------------------
# Install APK packages from IPS HTTP server on Alpine nodes.
#
# Arguments:
#   $@ - package_names : Package names to install (without version/extension)
#                        e.g., "opensvc-server opensvc-client"
#
# Behaviour:
#   - Determines IPS gateway address
#   - Fetches package list from IPS repository via HTTP
#   - Matches requested package names to available .apk files
#   - Selects latest version when multiple matches exist
#   - Downloads each package to /tmp
#   - Installs using apk add --allow-untrusted
#   - Cleans up downloaded packages after installation
#   - Logs progress and errors to IPS via n_remote_log
#
# Repository Location:
#   http://<ips>/packages/alpine-repo/x86_64/
#
# Output:
#   Installation progress and results (local and remote)
#
# Returns:
#   0 on success (all packages installed)
#   1 on invalid parameters or missing packages
#   2 on installation failure
#===============================================================================
n_install_apk_packages_from_ips() {
  local package_names=("$@")
  
  if [[ ${#package_names[@]} -eq 0 ]]; then
    echo "Error: No package names provided"
    echo "Usage: n_install_apk_packages_from_ips <package_name> [package_name...]"
    n_remote_log "APK install called without package names"
    return 1
  fi
  
  # Get IPS gateway address
  local ips_gateway
  ips_gateway=$(n_get_provisioning_node) || {
    echo "Error: Could not determine IPS gateway address"
    n_remote_log "Failed to determine IPS gateway for APK installation"
    return 1
  }
  
  local repo_url="http://${ips_gateway}/packages/alpine-repo/x86_64"
  local temp_dir="/tmp/apk-install-$$"
  
  echo "Installing APK packages from IPS..."
  echo "  IPS: ${ips_gateway}"
  echo "  Repository: ${repo_url}"
  echo "  Packages: ${package_names[*]}"
  echo ""
  
  n_remote_log "Starting APK installation: ${package_names[*]}"
  
  # Create temp directory
  mkdir -p "$temp_dir" || {
    echo "Error: Failed to create temporary directory"
    n_remote_log "Failed to create temp directory ${temp_dir}"
    return 2
  }
  
  # Fetch directory listing from IPS
  echo "Fetching package list from IPS..."
  local listing_file="${temp_dir}/listing.html"
  
  if ! curl -sf "${repo_url}/" > "$listing_file"; then
    echo "Error: Failed to fetch package list from ${repo_url}"
    n_remote_log "Failed to fetch package list from ${repo_url}"
    rm -rf "$temp_dir"
    return 2
  fi
  
  # Extract .apk filenames from HTML listing
  local available_packages
  available_packages=$(grep -o 'href="[^"]*\.apk"' "$listing_file" | cut -d'"' -f2)
  
  if [[ -z "$available_packages" ]]; then
    echo "Error: No packages found in repository"
    n_remote_log "No APK packages found in repository ${repo_url}"
    rm -rf "$temp_dir"
    return 1
  fi
  
  local pkg_count=$(echo "$available_packages" | wc -l)
  echo "Available packages: ${pkg_count}"
  echo ""
  n_remote_log "Found ${pkg_count} packages in repository"
  
  # Function to extract version from APK filename
  # Example: opensvc-server-3.0.8-r0.apk -> 3.0.8-r0
  _extract_apk_version() {
    local filename="$1"
    local pkg_name="$2"
    # Remove package name prefix and .apk suffix
    echo "${filename#${pkg_name}-}" | sed 's/\.apk$//'
  }
  
  # Function to find latest version of a package
  _find_latest_apk() {
    local pkg_name="$1"
    local candidates
    
    # Find all matching packages
    candidates=$(echo "$available_packages" | grep "^${pkg_name}-[0-9]")
    
    if [[ -z "$candidates" ]]; then
      return 1
    fi
    
    # Sort by version and get the latest
    # APK versions are typically: version-rN (e.g., 3.0.8-r0)
    local latest=""
    local latest_version=""
    
    while IFS= read -r candidate; do
      if [[ -n "$candidate" ]]; then
        local version
        version=$(_extract_apk_version "$candidate" "$pkg_name")
        
        if [[ -z "$latest" ]]; then
          latest="$candidate"
          latest_version="$version"
        else
          # Compare versions using apk's version comparison logic
          # Higher version sorts later with 'sort -V'
          if echo -e "${version}\n${latest_version}" | sort -V | tail -1 | grep -q "^${version}$"; then
            latest="$candidate"
            latest_version="$version"
          fi
        fi
      fi
    done <<< "$candidates"
    
    echo "$latest"
    return 0
  }
  
  # Match and download requested packages
  local -a packages_to_install=()
  local missing_packages=()
  
  for pkg_name in "${package_names[@]}"; do
    # Find latest version of package
    local pkg_file
    pkg_file=$(_find_latest_apk "$pkg_name")
    
    if [[ -z "$pkg_file" ]]; then
      missing_packages+=("$pkg_name")
      n_remote_log "Package not found: ${pkg_name}"
      continue
    fi
    
    echo "Downloading: ${pkg_file} (latest version)"
    if curl -sf -o "${temp_dir}/${pkg_file}" "${repo_url}/${pkg_file}"; then
      packages_to_install+=("${temp_dir}/${pkg_file}")
      n_remote_log "Downloaded: ${pkg_file}"
    else
      echo "Error: Failed to download ${pkg_file}"
      n_remote_log "Download failed: ${pkg_file}"
      missing_packages+=("$pkg_name")
    fi
  done
  
  # Check for missing packages
  if [[ ${#missing_packages[@]} -gt 0 ]]; then
    echo ""
    echo "Error: Some packages not found:"
    printf '  %s\n' "${missing_packages[@]}"
    n_remote_log "Missing packages: ${missing_packages[*]}"
    rm -rf "$temp_dir"
    return 1
  fi
  
  # Install packages
  echo ""
  echo "Installing ${#packages_to_install[@]} packages..."
  n_remote_log "Installing ${#packages_to_install[@]} APK packages"
  
  # Use --force-non-repository for diskless/data Alpine systems
  if ! apk add --allow-untrusted --force-non-repository "${packages_to_install[@]}"; then
    echo "Error: Package installation failed"
    n_remote_log "APK installation failed for packages: ${package_names[*]}"
    rm -rf "$temp_dir"
    return 2
  fi
  
  # Cleanup
  rm -rf "$temp_dir"
  
  echo ""
  echo "Successfully installed packages:"
  printf '  %s\n' "${package_names[@]}"
  
  n_remote_log "Successfully installed APK packages: ${package_names[*]}"
  
  return 0
}

