# TCH Build Functions
# Functions for building and managing Alpine-based TCH images

__guard_source || return




#===============================================================================
# tch_apkovol_create
# ------------------
# Generate Alpine apkovl tarball containing TCH bootstrap script
#
# Behaviour:
#   - Retrieves IPS gateway IP from cluster configuration
#   - Creates temporary directory structure
#   - Generates bootstrap script in etc/local.d/hps-bootstrap.start
#   - Creates tar.gz archive
#   - Streams tarball to stdout with HTTP headers
#   - Cleans up temporary files
#
# CGI Output:
#   - HTTP headers (Content-Type, Content-Disposition)
#   - Binary tar.gz stream to stdout
#
# Returns:
#   Exits via cgi_fail on any error
#   Streams tar.gz on success
#===============================================================================
tch_apkovol_create() {
  hps_log info "CGI request: tch_apkovol_create"
  
  local gateway_ip=$(cluster_config get DHCP_IP)
  if [[ -z "$gateway_ip" ]]; then
    hps_log error "Failed to get gateway IP from cluster config"
    cgi_fail "Unable to determine IPS gateway IP"
  fi
  
  hps_log debug "Creating apkovl with gateway IP: $gateway_ip"
  
  # Create temp structure
  local tmp_dir=$(mktemp -d)
  if [[ ! -d "$tmp_dir" ]]; then
    hps_log error "Failed to create temporary directory"
    cgi_fail "Internal error: cannot create temp directory"
  fi
  
  hps_log debug "Created temp directory: $tmp_dir"
  
  if ! mkdir -p "$tmp_dir/etc/local.d" "$tmp_dir/etc/runlevels/default"; then
    hps_log error "Failed to create directory structure in $tmp_dir"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot create directory structure"
  fi
  
  # Create symlink to enable local service at boot
  ln -s /etc/init.d/local "$tmp_dir/etc/runlevels/default/local"
  
  # Write bootstrap script
  if ! cat > "$tmp_dir/etc/local.d/hps-bootstrap.start" <<'EOF'
#!/bin/sh
echo "[HPS] TCH Bootstrap starting..."

# Configure Alpine repositories
echo "[HPS] Configuring package repositories..."
cat > /etc/apk/repositories <<REPOS
http://GATEWAY_IP/distros/alpine-3.20.2/apks/main
REPOS

# Update package index
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
if ! /bin/bash -c 'eval "$(curl -fsSL http://GATEWAY_IP/cgi-bin/boot_manager.sh?cmd=node_bootstrap_functions)" && tch_configure_alpine'; then
    echo "[HPS] ERROR: TCH configuration failed"
    exit 1
fi

echo "[HPS] TCH Bootstrap complete"

# Don't remove the script - it needs to run every boot
# rm -f /etc/local.d/hps-bootstrap.start
EOF
  then
    hps_log error "Failed to write bootstrap script"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot write bootstrap script"
  fi
  
  # Substitute gateway IP
  sed -i "s|GATEWAY_IP|${gateway_ip}|g" "$tmp_dir/etc/local.d/hps-bootstrap.start"
  
  if ! chmod +x "$tmp_dir/etc/local.d/hps-bootstrap.start"; then
    hps_log error "Failed to set execute permission on bootstrap script"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot set permissions"
  fi
  
  hps_log debug "Bootstrap script created successfully"
  
  # HTTP headers - required for CGI
  echo "Content-Type: application/gzip"
  echo ""
  
  # Stream tar to stdout
  if ! tar czf - -C "$tmp_dir" . 2>/dev/null; then
    hps_log error "Failed to create tar archive"
    rm -rf "$tmp_dir"
    exit 1
  fi
  
  hps_log info "Successfully generated and streamed apkovl tarball"
  
  # Cleanup
  rm -rf "$tmp_dir"
  hps_log debug "Cleaned up temp directory: $tmp_dir"
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
/bin/sh -c 'eval "\$(curl -fsSL http://${gateway_ip}/cgi-bin/boot_manager.sh?cmd=node_bootstrap_functions)" && tch_configure_alpine'
rm -f /etc/local.d/hps-bootstrap.start
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


