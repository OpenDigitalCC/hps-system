


n_start_modloop () {
  rc-service modloop status || rc-service modloop start
}


#===============================================================================
# n_setup_ntp
# -----------
# Configure NTP time synchronization using busybox.
#
# Usage:
#   n_setup_ntp
#
# Behaviour:
#   - Retrieves TIME_SERVER from cluster configuration
#   - Configures /etc/conf.d/ntpd with the specified NTP server
#   - Falls back to pool.ntp.org if TIME_SERVER is not set
#
# Dependencies:
#   - n_remote_cluster_variable function
#   - ntpd package installed
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   n_setup_ntp
#
#===============================================================================
n_setup_ntp() {
  local ntp_server
  local ntpd_conf="/etc/conf.d/ntpd"
  
  n_remote_log "Configuring NTP time synchronization..."
  
  # Get NTP server from cluster config
  ntp_server=$(n_remote_cluster_variable NTP_SERVER)
  
  # Fall back to default if not set
  if [[ -z "${ntp_server}" ]]; then
    ntp_server="pool.ntp.org"
    n_remote_log "TIME_SERVER not set, using default: ${ntp_server}"
  else
    n_remote_log "Using TIME_SERVER: ${ntp_server}"
  fi
  
  # Create ntpd configuration
  cat > "${ntpd_conf}" <<EOF
# By default ntpd runs as a client. Add -l to run as a server on port 123.
NTPD_OPTS="-N -p ${ntp_server}"
EOF
  
  if [[ ! -f "${ntpd_conf}" ]]; then
    n_remote_log "ERROR: Failed to create ${ntpd_conf}"
    return 1
  fi
  
  n_remote_log "NTP configured successfully with server: ${ntp_server}"
  return 0
}


#===============================================================================
# n_configure_ips_profile
# -----------------------
# Create profile.d script to set up HPS environment for login shells.
#
# Usage:
#   n_configure_ips_profile
#
# Behaviour:
#   - Creates /etc/profile.d/hps-env.sh
#   - Sets TERM to xterm
#   - Sources HPS bootstrap library
#   - Loads node functions
#
# Dependencies:
#   - /usr/local/lib/hps-bootstrap-lib.sh must exist
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_configure_ips_profile() {
  local profile_script="/etc/profile.d/hps-env.sh"
  
  n_remote_log "Creating HPS profile script: ${profile_script}"
  
  # Create profile.d directory if it doesn't exist
  mkdir -p /etc/profile.d
  
  cat > "${profile_script}" <<'EOF'
#!/bin/bash
# HPS environment setup for login shells

# Set terminal type
export TERM=xterm

# Source HPS functions if available
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    . /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions
fi
EOF
  
  # Make executable
  chmod +x "${profile_script}"
  
  if [[ ! -x "${profile_script}" ]]; then
    n_remote_log "ERROR: Failed to create profile script"
    return 1
  fi
  
  n_remote_log "Profile script created successfully"
  return 0
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
# n_create_cgroups
# ----------------
# Mount and configure cgroups v2 filesystem.
#
# Usage:
#   n_create_cgroups
#
# Behaviour:
#   - Checks if cgroup2 is already mounted on /sys/fs/cgroup
#   - Mounts cgroup2 filesystem if not present
#   - Verifies successful mount
#   - Adds fstab entry for persistence across reboots
#
# Dependencies:
#   - cgroup2 support in kernel
#   - mount command available
#
# Returns:
#   0 on success
#   1 on mount failure
#   2 on fstab update failure
#
# Example usage:
#   n_create_cgroups
#
#===============================================================================
n_create_cgroups() {
  n_remote_log "Configuring cgroups v2..."
  
  # Check if cgroup2 is already mounted
  if ! mount | grep -q "cgroup2 on /sys/fs/cgroup"; then
    n_remote_log "Mounting cgroup2 filesystem on /sys/fs/cgroup"
    
    if ! mount -t cgroup2 none /sys/fs/cgroup; then
      n_remote_log "ERROR: Failed to mount cgroup2"
      return 1
    fi
  else
    n_remote_log "cgroup2 already mounted"
  fi
  
  # Verify mount succeeded
  if ! mount | grep -q cgroup; then
    n_remote_log "ERROR: cgroup2 mount verification failed"
    return 1
  fi
  
  n_remote_log "cgroup2 mounted successfully"
  
  # Add to fstab for persistence if not already present
  if ! grep -q "cgroup2" /etc/fstab; then
    n_remote_log "Adding cgroup2 to /etc/fstab for persistence"
    
    if ! echo "none /sys/fs/cgroup cgroup2 defaults 0 0" >> /etc/fstab; then
      n_remote_log "ERROR: Failed to update /etc/fstab"
      return 2
    fi
    
    n_remote_log "fstab updated successfully"
  else
    n_remote_log "cgroup2 already present in /etc/fstab"
  fi
  
  return 0
}

#===============================================================================
# n_load_kernel_modules
# ---------------------
# Load multiple kernel modules.
#
# Usage:
#   n_load_kernel_modules <module1> [module2] [module3] ...
#
# Behaviour:
#   - Calls n_load_kernel_module for each module
#   - Continues on failure (best-effort)
#   - Returns count of failed modules
#
# Arguments:
#   $@ - module names to load
#
# Returns:
#   0 if all modules loaded successfully
#   N (1-255) number of modules that failed to load
#
# Example usage:
#   n_load_kernel_modules ext4 mbcache jbd2
#   n_load_kernel_modules raid1 raid456 md_mod
#
#===============================================================================
n_load_kernel_modules() {
  local failed=0
  
  for module in "$@"; do
    if ! n_load_kernel_module "${module}"; then
      ((failed++))
    fi
  done
  
  return ${failed}
}

#===============================================================================
# n_load_kernel_module
# --------------------
# Load a kernel module with automatic fallback.
#
# Usage:
#   n_load_kernel_module <module_name>
#
# Behaviour:
#   - Checks if module is already loaded
#   - Attempts modprobe first (handles dependencies)
#   - Falls back to insmod from modloop if modprobe fails
#   - Handles both .ko and .ko.gz files
#
# Arguments:
#   $1 - module_name : Name of module to load (without .ko extension)
#
# Returns:
#   0 if module loaded successfully or already loaded
#   1 if module not found
#   2 if load failed
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
    n_remote_log "[MOD] Module already loaded: ${module_name}"
    return 0
  fi
  
  # Try modprobe first
  if modprobe "${module_name}" 2>/dev/null; then
    n_remote_log "[MOD] Loaded via modprobe: ${module_name}"
    return 0
  fi
  
  n_remote_log "[MOD] modprobe failed for ${module_name}, trying insmod fallback"
  
  # Fallback to insmod from modloop
  local modloop_mount="/.modloop"
  if ! mountpoint -q "${modloop_mount}" 2>/dev/null; then
    n_remote_log "[MOD] ERROR: modprobe failed and modloop not mounted"
    return 1
  fi
  
  local kver=$(uname -r)
  local module_dir="${modloop_mount}/modules/${kver}"
  
  if [[ ! -d "${module_dir}" ]]; then
    n_remote_log "[MOD] ERROR: Module directory not found: ${module_dir}"
    return 1
  fi
  
  # Find module file
  local module_file=$(find "${module_dir}" -name "${module_name}.ko*" 2>/dev/null | head -n1)
  
  if [[ -z "${module_file}" ]]; then
    n_remote_log "[MOD] ERROR: Module not found: ${module_name}"
    return 1
  fi
  
  if insmod "${module_file}" 2>/dev/null; then
    n_remote_log "[MOD] Loaded via insmod: ${module_name}"
    return 0
  fi
  
  n_remote_log "[MOD] ERROR: Failed to load module: ${module_name}"
  return 2
}


#===============================================================================
# n_add_persistent_module
# -----------------------
# Add a module to /etc/modules for persistence across reboots.
#
# Usage:
#   n_add_persistent_module <module_name>
#
# Behaviour:
#   - Checks if module already in /etc/modules
#   - Appends if not present
#
# Arguments:
#   $1 - module_name : Name of module
#
# Returns:
#   0 on success
#
# Example usage:
#   n_add_persistent_module e1000e
#
#===============================================================================
n_add_persistent_module() {
  local module_name="${1:?Usage: n_add_persistent_module <module_name>}"
  
  if ! grep -q "^${module_name}$" /etc/modules 2>/dev/null; then
    echo "${module_name}" >> /etc/modules
    n_remote_log "[MOD] Added ${module_name} to /etc/modules"
  fi
  
  return 0
}



#===============================================================================
# n_configure_reboot_logging
# --------------------------
# Configure reboot logging on node to track all reboot attempts.
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
    n_remote_log "Configuring reboot logging on node"
    
    # Ensure bash is available
    if ! command -v bash >/dev/null 2>&1; then
        echo "[HPS] ERROR: bash not found, required for reboot logging"
        n_remote_log "ERROR: bash not found on node"
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
# HPS Reboot Logger for ${cmd}

# Source HPS node functions
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    source /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions >/dev/null 2>&1
fi

TIMESTAMP="\$(date '+%Y-%m-%d %H:%M:%S')"

# Log to IPS if available
if command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "REBOOT: ${cmd} \$@ initiated on node at \${TIMESTAMP}"
    
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
# HPS Reboot Logger for shutdown

# Source HPS node functions
if [ -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
    source /usr/local/lib/hps-bootstrap-lib.sh
    hps_load_node_functions >/dev/null 2>&1
fi

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Log to IPS if available
if command -v n_remote_log >/dev/null 2>&1; then
    n_remote_log "REBOOT: shutdown $@ initiated on node at ${TIMESTAMP}"
    
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
    n_remote_log "Node shutting down via init system"
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
# n_install_packages
# ------------------
# Install APK packages with automatic fallback to direct HTTP download.
#
# Usage:
#   n_install_packages <package1> [package2] [package3] ...
#
# Behaviour:
#   - Attempts apk add first (uses configured repositories)
#   - Falls back to direct HTTP download from IPS if apk fails
#   - Direct mode searches three repositories:
#     - Main: /distros/<repo_path>/apks/main/x86_64/
#     - Community: /distros/<repo_path>/apks/community/x86_64/
#     - Custom: /packages/alpine-repo/x86_64/
#   - Selects latest version when package exists in multiple repos
#   - Caches repo listings for efficiency
#
# Arguments:
#   $@ - package names to install
#
# Returns:
#   0 on success
#   1 on invalid parameters
#   2 on installation failure
#
# Example usage:
#   n_install_packages zfs-lts zfs-openrc
#   n_install_packages opensvc-server
#
#===============================================================================
n_install_packages() {
  local packages=("$@")
  
  if [[ ${#packages[@]} -eq 0 ]]; then
    n_remote_log "[PKG] ERROR: No packages specified"
    return 1
  fi
  
  n_remote_log "[PKG] Installing packages: ${packages[*]}"
  
  # Try apk add first
  if apk add --no-progress "${packages[@]}" 2>/dev/null; then
    n_remote_log "[PKG] Installed via apk: ${packages[*]}"
    return 0
  fi
  
  n_remote_log "[PKG] apk add failed, falling back to direct HTTP"
  
  # Fall back to direct HTTP installation
  _n_install_packages_direct "${packages[@]}"
}

#===============================================================================
# _n_install_packages_direct
# --------------------------
# Internal: Install packages via direct HTTP download from IPS.
#
# Usage:
#   _n_install_packages_direct <package1> [package2] ...
#
# Behaviour:
#   - Gets os_id and repo_path from IPS
#   - Fetches and caches package listings from all repos
#   - Finds latest version of each package across all repos
#   - Downloads and installs with apk add --allow-untrusted
#
# Returns:
#   0 on success
#   1 on setup failure
#   2 on installation failure
#
#===============================================================================
_n_install_packages_direct() {
  local packages=("$@")
  local ips_host="ips"
  local cache_dir="/tmp/apk-cache-$$"
  local download_dir="/tmp/apk-download-$$"
  
  # Get os_id from host config
  local os_id
  os_id=$(n_remote_host_variable os_id)
  if [[ -z "${os_id}" ]]; then
    n_remote_log "[PKG] ERROR: Could not determine os_id"
    return 1
  fi
  
  # Get repo_path from IPS
  local repo_path
  repo_path=$(n_ips_command os_variable os_id="${os_id}" name=repo_path)
  if [[ -z "${repo_path}" ]]; then
    n_remote_log "[PKG] ERROR: Could not determine repo_path for ${os_id}"
    return 1
  fi
  
  n_remote_log "[PKG] Using os_id=${os_id} repo_path=${repo_path}"
  
  # Define repository URLs
  local repos=(
    "http://${ips_host}/distros/${repo_path}/apks/main/x86_64"
    "http://${ips_host}/distros/${repo_path}/apks/community/x86_64"
    "http://${ips_host}/packages/alpine-repo/x86_64"
  )
  
  mkdir -p "${cache_dir}" "${download_dir}"
  
  # Fetch and cache listings from all repos
  local repo_index=0
  for repo_url in "${repos[@]}"; do
    local listing_file="${cache_dir}/repo_${repo_index}.list"
    
    if curl -sf "${repo_url}/" | grep -o 'href="[^"]*\.apk"' | cut -d'"' -f2 > "${listing_file}" 2>/dev/null; then
      local pkg_count=$(wc -l < "${listing_file}")
      n_remote_log "[PKG] Repo ${repo_index}: ${pkg_count} packages from ${repo_url}"
    else
      n_remote_log "[PKG] Repo ${repo_index}: unavailable (${repo_url})"
      : > "${listing_file}"
    fi
    
    ((repo_index++))
  done
  
  # Find and download each package
  local packages_to_install=()
  local missing_packages=()
  
  for pkg_name in "${packages[@]}"; do
    local best_file=""
    local best_version=""
    local best_repo_url=""
    
    # Search all repos for this package
    repo_index=0
    for repo_url in "${repos[@]}"; do
      local listing_file="${cache_dir}/repo_${repo_index}.list"
      
      # Find matching packages (name-version.apk pattern)
      while IFS= read -r apk_file; do
        if [[ "${apk_file}" =~ ^${pkg_name}-([0-9][^/]*)\.apk$ ]]; then
          local version="${BASH_REMATCH[1]}"
          
          # Compare versions, keep latest
          if [[ -z "${best_version}" ]] || _version_gt "${version}" "${best_version}"; then
            best_file="${apk_file}"
            best_version="${version}"
            best_repo_url="${repo_url}"
          fi
        fi
      done < "${listing_file}"
      
      ((repo_index++))
    done
    
    if [[ -n "${best_file}" ]]; then
      n_remote_log "[PKG] Found ${pkg_name}: ${best_file} (${best_version})"
      
      # Download package
      if curl -sf -o "${download_dir}/${best_file}" "${best_repo_url}/${best_file}"; then
        packages_to_install+=("${download_dir}/${best_file}")
      else
        n_remote_log "[PKG] ERROR: Failed to download ${best_file}"
        missing_packages+=("${pkg_name}")
      fi
    else
      n_remote_log "[PKG] WARNING: Package not found: ${pkg_name}"
      missing_packages+=("${pkg_name}")
    fi
  done
  
  # Report missing packages
  if [[ ${#missing_packages[@]} -gt 0 ]]; then
    n_remote_log "[PKG] Missing packages: ${missing_packages[*]}"
  fi
  
  # Install downloaded packages
  if [[ ${#packages_to_install[@]} -eq 0 ]]; then
    n_remote_log "[PKG] ERROR: No packages to install"
    rm -rf "${cache_dir}" "${download_dir}"
    return 2
  fi
  
  n_remote_log "[PKG] Installing ${#packages_to_install[@]} packages"
  if apk add --allow-untrusted --force-non-repository "${packages_to_install[@]}" 2>&1 | while IFS= read -r line; do
    n_remote_log "[PKG] ${line}"
  done; then
    n_remote_log "[PKG] Installation successful"
    rm -rf "${cache_dir}" "${download_dir}"
    return 0
  else
    n_remote_log "[PKG] ERROR: Installation failed"
    rm -rf "${cache_dir}" "${download_dir}"
    return 2
  fi
}

#===============================================================================
# _version_gt
# -----------
# Internal: Compare two version strings.
#
# Arguments:
#   $1 - version a
#   $2 - version b
#
# Returns:
#   0 if a > b
#   1 otherwise
#
#===============================================================================
_version_gt() {
  local a="$1"
  local b="$2"
  
  local highest
  highest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
  
  [[ "${highest}" == "$a" && "$a" != "$b" ]]
}

#===============================================================================
# n_install_apk_packages_from_ips
# -------------------------------
# DEPRECATED: Use n_install_packages instead.
#
# This function is maintained for backward compatibility and will be
# removed in a future release.
#
# Arguments:
#   $@ - package names to install
#
# Returns:
#   Same as n_install_packages
#
#===============================================================================
n_install_apk_packages_from_ips() {
  n_remote_log "[PKG] WARNING: n_install_apk_packages_from_ips is deprecated, use n_install_packages"
  n_install_packages "$@"
}



