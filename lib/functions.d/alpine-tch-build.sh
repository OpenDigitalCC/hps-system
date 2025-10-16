# TCH Build Functions
# Functions for building and managing Alpine-based TCH images

__guard_source || return


# WARNING: changes to the build requires tch_apkovol_create to run, to recreate the apkvol
# so if any functions changed here, move the file (probably /srv/hps-resources/distros/alpine-3.20.2/tch-base.apkovl.tar.gz) so it gets recreeated
# or run tch_apkovol_create /srv/hps-resources/distros/alpine-3.20.2/tch-base.apkovl.tar.gz

#===============================================================================
# tch_apkovol_create
# ------------------
# Generate Alpine apkovl tarball containing TCH bootstrap configuration
#
# WARNING: Known cosmetic issue - Alpine netboot modprobe warnings
# "can't change directory to '6.6.41-0-lts'"
# Cause: modloop loads modules from HTTP, /lib/modules irrelevant
# Impact: None - modules load successfully from modloop
# Status: Accepted as Alpine netboot standard behavior
#
# Arguments:
#   $1 - output_file : Path where tarball should be written
#
# Behaviour:
#   - Retrieves configuration from cluster config
#   - Creates temporary directory structure
#   - Generates resolv.conf, modloop setup script, bootstrap script, runlevel config
#   - Creates tar.gz archive at specified output path
#   - Cleans up temporary files
#
# Module Loading:
#   Modloop is downloaded via HTTP and mounted at /.modloop/
#   Modules are loaded directly using insmod from /.modloop/modules/
#   This bypasses modprobe's directory detection issues
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
tch_apkovol_create() {
  local output_file="${1:?Usage: tch_apkovol_create <output_file>}"
  
  hps_log info "Creating Alpine apkovl: $output_file"
  
  # Get configuration
  local gateway_ip=$(cluster_config get DHCP_IP)
  if [[ -z "$gateway_ip" ]]; then
    hps_log error "Failed to get gateway IP from cluster config"
    return 1
  fi
  
  local alpine_version=$(get_latest_alpine_version)
  if [[ -z "$alpine_version" ]]; then
    hps_log error "Failed to determine Alpine version"
    return 1
  fi
  
  local nameserver=$(cluster_config get NAME_SERVER)
  if [[ -z "$nameserver" ]]; then
    hps_log warn "NAME_SERVER not configured, using gateway IP for DNS"
    nameserver="$gateway_ip"
  fi
  
  hps_log debug "Apkovl config: Alpine=${alpine_version}, Gateway=${gateway_ip}, DNS=${nameserver}"
  
  # Create temporary workspace
  local tmp_dir=$(mktemp -d)
  if [[ ! -d "$tmp_dir" ]]; then
    hps_log error "Failed to create temporary directory"
    return 1
  fi
  
  # Build apkovl components
  if ! _apkovl_create_structure "$tmp_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  
  if ! _apkovl_create_resolv_conf "$tmp_dir" "$nameserver"; then
    rm -rf "$tmp_dir"
    return 1
  fi
  
  if ! _apkovl_create_modloop_setup "$tmp_dir" "$gateway_ip" "$alpine_version"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  # Create HPS bootstrap library
  if ! _apkovl_create_lib "$tmp_dir"; then
    hps_log error "Failed to create bootstrap library"
    rm -rf "$tmp_dir"
    return 1
  fi
  
  # Create bootstrap script
  if ! _apkovl_create_bootstrap_script "$tmp_dir" "$gateway_ip" "$alpine_version"; then
    hps_log error "Failed to create bootstrap script"
    rm -rf "$tmp_dir"
    return 1
  fi
  
  if ! _apkovl_create_runlevel_config "$tmp_dir"; then
    rm -rf "$tmp_dir"
    return 1
  fi


  # Create tarball
  if ! tar czf "$output_file" -C "$tmp_dir" . 2>/dev/null; then
    hps_log error "Failed to create tar archive"
    rm -rf "$tmp_dir"
    return 1
  fi
  
  # Cleanup
  rm -rf "$tmp_dir"
  hps_log info "Successfully created apkovl: $output_file"
  
  return 0
}


#===============================================================================
# _apkovl_create_modloop_setup
# -----------------------------
# Create modloop download and module loading script
#
# Arguments:
#   $1 - base_dir        : Root directory of apkovl structure
#   $2 - gateway_ip      : Gateway IP for downloading modloop
#   $3 - alpine_version  : Alpine version (e.g., 3.20.2)
#
# Behaviour:
#   - Creates /etc/local.d/modloop-setup.start
#   - Downloads modloop-lts via wget from gateway
#   - Mounts modloop at /.modloop/
#   - Loads required kernel modules via insmod
#   - Makes script executable
#   - Runs during OpenRC boot via local.d service
#
# Module List:
#   8021q - VLAN (802.1Q) support for virtual interfaces
#
# Returns:
#   0 on success
#   1 on error
#
# Example usage:
#   _apkovl_create_modloop_setup "/tmp/apkovl" "10.99.1.1" "3.20.2"
#
#===============================================================================
_apkovl_create_modloop_setup() {
  local base_dir="${1:?Usage: _apkovl_create_modloop_setup <base_dir> <gateway_ip> <alpine_version>}"
  local gateway_ip="${2:?Usage: _apkovl_create_modloop_setup <base_dir> <gateway_ip> <alpine_version>}"
  local alpine_version="${3:?Usage: _apkovl_create_modloop_setup <base_dir> <gateway_ip> <alpine_version>}"
  
  local locald_dir="$base_dir/etc/local.d"
  
  if ! mkdir -p "$locald_dir"; then
    hps_log error "Failed to create local.d directory"
    return 1
  fi
  
  local setup_script="$locald_dir/modloop-setup.start"
  
  # Define modules to load - add more as needed
  local modules=(
    "mrp"    # Multiple Registration Protocol (dependency for 8021q)
    "8021q"      # VLAN support
    "bonding"   # NIC bonding
    "dummy"     # Dummy interfaces
  )
  
  hps_log debug "Creating modloop setup script for ${#modules[@]} module(s): ${modules[*]}"
  
  # Create the modloop setup script directly
  cat > "$setup_script" <<EOF
#!/bin/sh
# TCH Modloop Setup - Download and mount kernel modules
# Generated by hps-system tch_apkovol_create

GATEWAY_IP="${gateway_ip}"
ALPINE_VERSION="${alpine_version}"
MODLOOP_URL="http://\${GATEWAY_IP}/distros/alpine-\${ALPINE_VERSION}/boot/modloop-lts"
MODLOOP_FILE="/tmp/modloop-lts"
MODLOOP_MOUNT="/.modloop"

# Download modloop if not already present
if [ ! -f "\$MODLOOP_FILE" ]; then
  echo "Downloading modloop from \$MODLOOP_URL..."
  if ! wget -q -O "\$MODLOOP_FILE" "\$MODLOOP_URL"; then
    echo "ERROR: Failed to download modloop" >&2
    exit 1
  fi
  echo "Downloaded modloop: \$(du -h \$MODLOOP_FILE | cut -f1)"
fi

# Create mount point
mkdir -p "\$MODLOOP_MOUNT"

# Mount modloop
if ! grep -q "\$MODLOOP_MOUNT" /proc/mounts; then
  echo "Mounting modloop at \$MODLOOP_MOUNT..."
  if ! mount -t squashfs -o loop,ro "\$MODLOOP_FILE" "\$MODLOOP_MOUNT"; then
    echo "ERROR: Failed to mount modloop" >&2
    exit 1
  fi
  echo "Modloop mounted successfully"
fi

# Detect kernel version
KVER=\$(uname -r)
MODULE_DIR="\$MODLOOP_MOUNT/modules/\$KVER"

if [ ! -d "\$MODULE_DIR" ]; then
  echo "ERROR: Module directory not found: \$MODULE_DIR" >&2
  exit 1
fi

# create a symlink to make modprobe etc happy
ln -s $MODULE_DIR /lib/modules/

# Load modules
EOF

  # Add module loading commands
  for module in "${modules[@]}"; do
    cat >> "$setup_script" <<EOF
echo "Loading module: ${module}..."
MODULE_FILE=\$(find "\$MODULE_DIR" -name "${module}.ko*" | head -n1)
if [ -n "\$MODULE_FILE" ]; then
  if insmod "\$MODULE_FILE" 2>/dev/null; then
    echo "Successfully loaded module: ${module}"
    sleep 0.2
  else
    echo "WARNING: Failed to load module: ${module}" >&2
  fi
else
  echo "WARNING: Module not found: ${module}" >&2
fi

EOF
  done

  # Add completion message
  cat >> "$setup_script" <<'EOF'
echo "Modloop setup complete"
exit 0
EOF

  # Make executable
  chmod +x "$setup_script"
  
  if [[ ! -x "$setup_script" ]]; then
    hps_log error "Failed to make modloop setup script executable"
    return 1
  fi
  
  hps_log debug "Created modloop setup script with ${#modules[@]} module(s)"
  
  return 0
}


#===============================================================================
# _apkovl_create_runlevel_config
# -------------------------------
# Configure OpenRC runlevels and services
#
# Arguments:
#   $1 - base_dir : Root directory of apkovl structure
#
# Behaviour:
#   - Creates /etc/runlevels/default/local symlink
#   - Ensures local service runs at boot to execute modloop-setup.start
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
_apkovl_create_runlevel_config() {
  local base_dir="${1:?Usage: _apkovl_create_runlevel_config <base_dir>}"
  
  local runlevel_dir="$base_dir/etc/runlevels/default"
  
  if ! mkdir -p "$runlevel_dir"; then
    hps_log error "Failed to create runlevels directory"
    return 1
  fi
  
  # Enable local service in default runlevel
  ln -sf /etc/init.d/local "$runlevel_dir/local"
  
  if [[ ! -L "$runlevel_dir/local" ]]; then
    hps_log error "Failed to create local service symlink"
    return 1
  fi
  
  hps_log debug "Enabled local service in default runlevel"
  
  return 0
}


#===============================================================================
# _apkovl_create_structure
# -------------------------
# Create directory structure for apkovl
#
# Arguments:
#   $1 - tmp_dir : Temporary directory path
#
# Returns:
#   0 on success, 1 on failure
#===============================================================================
_apkovl_create_structure() {
  local tmp_dir="$1"
  
  hps_log debug "Creating apkovl directory structure"
  
  if ! mkdir -p "$tmp_dir/etc/local.d" "$tmp_dir/etc/runlevels/default"; then
    hps_log error "Failed to create directory structure"
    return 1
  fi
  
  # Enable local service at boot
  if ! ln -s /etc/init.d/local "$tmp_dir/etc/runlevels/default/local"; then
    hps_log error "Failed to create local service symlink"
    return 1
  fi
  
  return 0
}

#===============================================================================
# _apkovl_create_resolv_conf
# ---------------------------
# Create resolv.conf for DNS resolution
#
# Arguments:
#   $1 - tmp_dir    : Temporary directory path
#   $2 - nameserver : DNS nameserver IP address
#
# Returns:
#   0 on success, 1 on failure
#===============================================================================
_apkovl_create_resolv_conf() {
  local tmp_dir="$1"
  local nameserver="$2"
  
  hps_log debug "Creating resolv.conf with nameserver: $nameserver"
  
  if ! echo "nameserver $nameserver" > "$tmp_dir/etc/resolv.conf"; then
    hps_log error "Failed to create resolv.conf"
    return 1
  fi
  
  return 0
}



#:name: _apkovl_create_lib
#:group: alpine
#:synopsis: Deploy HPS bootstrap library to Alpine apkovl.
#:usage: _apkovl_create_lib <tmp_dir>
#:description:
#  Creates the HPS bootstrap library in the Alpine apkovl temporary directory.
#  Handles Alpine-specific paths and persistence configuration.
#:parameters:
#  tmp_dir - Temporary directory for apkovl construction
#:returns:
#  0 on success
#  1 on failure
_apkovl_create_lib() {
  local tmp_dir="$1"
  
  # Validate tmp_dir is provided
  if [[ -z "$tmp_dir" ]]; then
    hps_log error "_apkovl_create_lib: tmp_dir not provided"
    return 1
  fi
  
  hps_log debug "Creating HPS bootstrap library for Alpine"
  
  # Alpine-specific library path
  local lib_dir="$tmp_dir/usr/local/lib"
  local lib_file="$lib_dir/hps-bootstrap-lib.sh"
  
  # Ensure directory exists
  if ! mkdir -p "$lib_dir"; then
    hps_log error "Failed to create library directory: $lib_dir"
    return 1
  fi
  
  # Create the library file using core function
  if ! create_bootstrap_core_lib > "$lib_file"; then
    hps_log error "Failed to create bootstrap library"
    return 1
  fi
  
  # Make it executable
  if ! chmod +x "$lib_file"; then
    hps_log error "Failed to set execute permission on library"
    return 1
  fi
  
  # Alpine-specific: Add to LBU protected paths for persistence
  local lbu_dir="$tmp_dir/etc/apk/protected_paths.d"
  if ! mkdir -p "$lbu_dir"; then
    hps_log error "Failed to create LBU directory: $lbu_dir"
    return 1
  fi
  
  # Add to protected paths
  echo "/usr/local/lib/hps-bootstrap-lib.sh" >> "$lbu_dir/lbu.list"
  
  hps_log debug "HPS bootstrap library created successfully for Alpine"
  return 0
}







_apkovl_create_bootstrap_script() {
  local tmp_dir="$1"
  local gateway_ip="$2"
  local alpine_version="$3"
  
  hps_log debug "Creating bootstrap script"
  
  # Create bootstrap script
  if ! cat > "$tmp_dir/etc/local.d/hps-bootstrap.start" <<'EOF'
#!/bin/sh
echo "[HPS] TCH Bootstrap starting..."

# Configure Alpine repositories
echo "[HPS] Configuring package repositories..."
cat > /etc/apk/repositories <<REPOS
http://ips/distros/alpine-ALPINE_VERSION/apks/main
http://ips/distros/alpine-ALPINE_VERSION/apks/community
REPOS

# Update and install packages
echo "[HPS] Installing required packages..."
apk update && apk add --no-cache bash curl || {
    echo "[HPS] ERROR: Failed to install packages"
    exit 1
}

# Source the library and initialize
echo "[HPS] Starting node initialization..."
/bin/bash -c 'source /usr/local/lib/hps-bootstrap-lib.sh && hps_node_init'

echo "[HPS] TCH Bootstrap complete"
EOF
  then
    hps_log error "Failed to write bootstrap script"
    return 1
  fi
  
  # Substitute placeholders
  sed -i "s|ALPINE_VERSION|${alpine_version}|g" "$tmp_dir/etc/local.d/hps-bootstrap.start"
  
  # Make executable
  chmod +x "$tmp_dir/etc/local.d/hps-bootstrap.start"
  
  return 0
}










#===============================================================================
# download_alpine_release
# -----------------------
# Download Alpine Linux ISO release to distros/iso directory
#
# Usage: download_alpine_release [alpine_version]
# Example: download_alpine_release "3.20.2"
#          download_alpine_release  # Downloads latest stable version
#
# Behaviour:
#   - If no version specified, uses get_latest_alpine_version
#   - Constructs Alpine download URL from version
#   - Downloads to ${HPS_RESOURCES}/distros/iso/
#   - Uses generic download_file function
#   - Stores downloaded filename for later use
#
# Returns:
#   0 on success, prints downloaded file path to stdout
#   1 if HPS_RESOURCES not set or version detection fails
#   2 if download fails
#===============================================================================
download_alpine_release() {
    local alpine_version="$1"
    
    if [[ -z "$HPS_RESOURCES" ]]; then
        hps_log "ERROR" "download_alpine_release: HPS_RESOURCES not set"
        return 1
    fi
    
    # Auto-detect Alpine version if not provided
    if [[ -z "$alpine_version" ]]; then
        alpine_version=$(get_latest_alpine_version)
        if [[ $? -ne 0 || -z "$alpine_version" ]]; then
            hps_log "ERROR" "download_alpine_release: Failed to detect Alpine version"
            return 1
        fi
        hps_log "INFO" "Auto-detected Alpine version: $alpine_version"
    fi
    
    # Extract major.minor version for URL (e.g., 3.20.2 -> 3.20)
    local major_minor_version
    major_minor_version=$(echo "$alpine_version" | grep -oE '^[0-9]+\.[0-9]+')
    
    # Construct download URL and filename
    local base_url="https://dl-cdn.alpinelinux.org/alpine/v${major_minor_version}/releases/x86_64"
    local filename="alpine-standard-${alpine_version}-x86_64.iso"
    local url="${base_url}/${filename}"
    local dest_path="${HPS_RESOURCES%/}/distros/iso/${filename}"
    
    hps_log "INFO" "Downloading Alpine ${alpine_version} from: $url"
    
    # Check if file already exists
    if [[ -f "$dest_path" ]]; then
        hps_log "INFO" "Alpine ISO already exists: $dest_path"
        echo "$dest_path"
        return 0
    fi
    
    # Download using generic download function
    if download_file "$url" "$dest_path"; then
        hps_log "INFO" "Alpine ${alpine_version} downloaded successfully"
        echo "$dest_path"
        return 0
    else
        hps_log "ERROR" "download_alpine_release: Download failed"
        return 2
    fi
}

#===============================================================================
# get_latest_alpine_version
# -------------------------
# Get the latest stable Alpine Linux version from alpinelinux.org
#
# Behaviour:
#   - Fetches latest stable version from Alpine releases page
#   - Returns version in format like "3.20.2"
#   - Falls back to hardcoded version if fetch fails
#
# Returns:
#   0 on success, prints version to stdout
#   1 if unable to determine version
#===============================================================================
get_latest_alpine_version() {
    local version
    
    # Try to fetch latest version from Alpine website
    if command -v curl >/dev/null 2>&1; then
        version=$(curl -s "https://www.alpinelinux.org/releases/" | \
                 grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | \
                 grep -v 'edge\|rc' | \
                 sort -V | tail -1)
    elif command -v wget >/dev/null 2>&1; then
        version=$(wget -qO- "https://www.alpinelinux.org/releases/" | \
                 grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | \
                 grep -v 'edge\|rc' | \
                 sort -V | tail -1)
    fi
    
    # Fallback to known stable version if fetch failed
    if [[ -z "$version" ]]; then
        version="3.20.2"
        hps_log "WARN" "get_latest_alpine_version: Could not fetch latest version, using fallback: $version"
    fi
    
    echo "$version"
    return 0
}


