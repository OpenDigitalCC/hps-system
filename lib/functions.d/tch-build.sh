# TCH Build Functions
# Functions for building and managing Alpine-based TCH images

__guard_source || return


# Note: changes to the build requires tch_apkovol_create to run, to recreate the apkvol


#===============================================================================
# tch_apkovol_create
# ------------------
# Generate Alpine apkovl tarball containing TCH bootstrap script
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
#   - Generates resolv.conf, bootstrap script, runlevel config
#   - Creates tar.gz archive at specified output path
#   - Cleans up temporary files
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
  
  if ! _apkovol_create_bootstrap_script "$tmp_dir" "$gateway_ip" "$alpine_version"; then
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

#===============================================================================
# _apkovol_create_bootstrap_script
# ---------------------------------
# Create TCH bootstrap script in etc/local.d/
#
# Arguments:
#   $1 - tmp_dir        : Temporary directory path
#   $2 - gateway_ip     : IPS gateway IP address
#   $3 - alpine_version : Alpine Linux version
#
# Returns:
#   0 on success, 1 on failure
#===============================================================================
_apkovol_create_bootstrap_script() {
  local tmp_dir="$1"
  local gateway_ip="$2"
  local alpine_version="$3"
  
  hps_log debug "Creating bootstrap script"
  
  # Create bootstrap script with placeholders
  if ! cat > "$tmp_dir/etc/local.d/hps-bootstrap.start" <<'EOF'
#!/bin/sh
echo "[HPS] TCH Bootstrap starting..."

# Configure Alpine repositories
echo "[HPS] Configuring package repositories..."
cat > /etc/apk/repositories <<REPOS
http://ips/distros/alpine-ALPINE_VERSION/apks/main
http://ips/distros/alpine-ALPINE_VERSION/apks/community
REPOS

# Update package index with retry logic
echo "[HPS] Updating package index..."
for attempt in 1 2 3; do
    if apk update; then
        break
    fi
    if [ $attempt -lt 3 ]; then
        echo "[HPS] Retry $attempt/3..."
        sleep 2
    else
        echo "[HPS] ERROR: Failed to update package index after 3 attempts"
        exit 1
    fi
done

# Install required packages
echo "[HPS] Installing bash and curl..."
if ! apk add --no-cache bash curl; then
    echo "[HPS] ERROR: Failed to install packages"
    exit 1
fi

# Source HPS functions and configure TCH
echo "[HPS] Sourcing HPS functions from IPS..."
if ! /bin/bash -c 'eval "$(curl -fsSL http://GATEWAY_IP/cgi-bin/boot_manager.sh?cmd=node_bootstrap_functions)"'; then
    echo "[HPS] ERROR: TCH configuration failed"
    exit 1
fi

echo "[HPS] TCH Bootstrap complete"

EOF
  then
    hps_log error "Failed to write bootstrap script"
    return 1
  fi
  
  # Substitute placeholders
  sed -i "s|GATEWAY_IP|${gateway_ip}|g" "$tmp_dir/etc/local.d/hps-bootstrap.start"
  sed -i "s|ALPINE_VERSION|${alpine_version}|g" "$tmp_dir/etc/local.d/hps-bootstrap.start"
  
  # Make executable
  if ! chmod +x "$tmp_dir/etc/local.d/hps-bootstrap.start"; then
    hps_log error "Failed to set execute permission on bootstrap script"
    return 1
  fi
  
  hps_log debug "Bootstrap script created successfully"
  return 0
}






get_alpine_bootstrap() {
  local stage="${1:-initramfs}"
  
  local gateway_ip=$(cluster_config get DHCP_IP)
  if [[ -z "$gateway_ip" ]]; then
    hps_log error "Failed to get gateway IP from cluster config"
    cgi_fail "Unable to determine IPS gateway IP"
  fi
  
  hps_log debug "Generating bootstrap script for stage: ${stage}, gateway IP: ${gateway_ip}"
  
  if [[ "$stage" != "initramfs" && "$stage" != "rc" ]]; then
    hps_log error "Invalid bootstrap stage: ${stage}"
    cgi_fail "Invalid stage parameter: ${stage}"
    return 1
  fi
  
  if [[ "$stage" == "initramfs" ]]; then
    generate_initramfs_script "$gateway_ip"
  else
    generate_rc_script "$gateway_ip"
  fi
}

generate_initramfs_script() {
  local gateway_ip="$1"
  cat <<'EOF'
#!/bin/sh
echo "[HPS] Installing post-boot bootstrap script..."
if [ ! -d /sysroot ]; then
    echo "[HPS] ERROR: /sysroot not available"
    exit 1
fi
mkdir -p /sysroot/etc/local.d
EOF
  
  # Write the RC script content dynamically
  echo "cat > /sysroot/etc/local.d/hps-bootstrap.start <<'RCSCRIPT'"
  generate_rc_script "$gateway_ip"
  echo "RCSCRIPT"
  
  cat <<'EOF'
chmod +x /sysroot/etc/local.d/hps-bootstrap.start
echo "[HPS] Bootstrap script installed to /sysroot/etc/local.d/"
EOF
}

generate_rc_script() {
  local gateway_ip="$1"
  cat <<EOF
#!/bin/sh
echo "[HPS] TCH Bootstrap starting..."
cat > /etc/apk/repositories <<REPOS
http://${gateway_ip}/distros/alpine-3.20.2/apks/main
REPOS
apk update
apk add --no-cache bash curl
/bin/sh -c 'eval "\$(curl -fsSL http://${gateway_ip}/cgi-bin/boot_manager.sh?cmd=node_bootstrap_functions)"'
#rm -f /etc/local.d/hps-bootstrap.start
EOF
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


