# TCH Build Functions
# Functions for building and managing Alpine-based TCH images

__guard_source || return


#!/usr/bin/env bash
#===============================================================================
# tch_apkovol_create
# ------------------
# Generate and stream Alpine apkovl tarball for TCH bootstrap.
#
# Behaviour:
#   - Retrieves IPS gateway IP from cluster configuration
#   - Creates temporary directory structure matching Alpine root filesystem
#   - Generates bootstrap script in /etc/local.d/hps-bootstrap.start
#   - Substitutes gateway IP into bootstrap script
#   - Creates tar.gz archive and streams to stdout
#   - Cleans up temporary files
#   - Logs all operations via hps_log
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
  
  hps_log debug "Using gateway IP: $gateway_ip"
  
  # Create temp structure
  local tmp_dir=$(mktemp -d)
  if [[ ! -d "$tmp_dir" ]]; then
    hps_log error "Failed to create temporary directory"
    cgi_fail "Internal error: cannot create temp directory"
  fi
  
  hps_log debug "Created temp directory: $tmp_dir"
  
  if ! mkdir -p "$tmp_dir/etc/local.d"; then
    hps_log error "Failed to create directory structure in $tmp_dir"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot create directory structure"
  fi
  
  # Write bootstrap script with gateway IP substituted
  cat > "$tmp_dir/etc/local.d/hps-bootstrap.start" <<'EOF'
echo "[HPS] TCH Bootstrap starting..."

# Required packages for HPS bootstrap
PACKAGES="bash curl"

# Configure repositories: local main repo + CDN community for bootstrap packages
echo "[HPS] Configuring package repositories..."
cat > /etc/apk/repositories <<REPOS
http://GATEWAY_IP/distros/alpine-3.20.2/apks/main
http://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPOS

echo "[HPS] Updating package index..."
if ! apk update 2>&1; then
    echo "[HPS] ERROR: Failed to update package index"
    echo "[HPS] Rebooting in 30 seconds..."
    sleep 30
    reboot
fi

echo "[HPS] Installing required packages: ${PACKAGES}..."
if ! apk add --no-cache ${PACKAGES} 2>&1; then
    echo "[HPS] ERROR: Failed to install packages"
    echo "[HPS] Rebooting in 30 seconds..."
    sleep 30
    reboot
fi

echo "[HPS] Sourcing functions from IPS at GATEWAY_IP..."

# Execute in bash context (HPS functions require bash)
/bin/bash <<'BASH_BLOCK'
if ! curl -fsSL "http://GATEWAY_IP/cgi-bin/boot_manager.sh?cmd=node_bootstrap_functions" | bash; then
    echo "[HPS] ERROR: Failed to source functions from IPS"
    echo "[HPS] Rebooting in 30 seconds..."
    sleep 30
    reboot
fi

echo "[HPS] Functions loaded successfully"
echo "[HPS] Starting TCH configuration..."
if ! tch_configure_alpine; then
    echo "[HPS] ERROR: TCH configuration failed"
    echo "[HPS] Rebooting in 30 seconds..."
    sleep 30
    reboot
fi
echo "[HPS] TCH Bootstrap complete"
BASH_BLOCK
EOF
  
  # Substitute gateway IP
  sed -i "s|GATEWAY_IP|${gateway_ip}|g" "$tmp_dir/etc/local.d/hps-bootstrap.start"
  
  if [[ $? -ne 0 ]]; then
    hps_log error "Failed to write bootstrap script"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot write bootstrap script"
  fi
  
  if ! chmod +x "$tmp_dir/etc/local.d/hps-bootstrap.start"; then
    hps_log error "Failed to set execute permission on bootstrap script"
    rm -rf "$tmp_dir"
    cgi_fail "Internal error: cannot set permissions"
  fi
  
  hps_log debug "Bootstrap script created successfully"
  
  # HTTP headers
  echo "Content-Type: application/octet-stream"
  echo "Content-Disposition: attachment; filename=\"tch-bootstrap.apkovl.tar.gz\""
  echo ""
  
  # Stream tar to stdout
  if ! tar czf - -C "$tmp_dir" . 2>/dev/null; then
    hps_log error "Failed to create tar archive"
    rm -rf "$tmp_dir"
    # Can't use cgi_fail here - headers already sent
    exit 1
  fi
  
  hps_log info "Successfully generated and streamed apkovl tarball"
  
  # Cleanup
  rm -rf "$tmp_dir"
  hps_log debug "Cleaned up temp directory: $tmp_dir"
}



#===============================================================================
# extract_alpine_iso
# ------------------
# Extract Alpine ISO contents to distros directory
#
# Usage: extract_alpine_iso <iso_path> [alpine_version]
# Example: extract_alpine_iso "/srv/hps-resources/distros/iso/alpine-standard-3.20.2-x86_64.iso" "3.20.2"
#          extract_alpine_iso "/path/to/iso"  # Auto-detects version from filename
#
# Behaviour:
#   - Mounts ISO as loop device
#   - Extracts all contents to ${HPS_RESOURCES}/distros/alpine-{version}/
#   - Creates extraction directory if needed
#   - Preserves file permissions and timestamps
#   - Unmounts ISO when complete
#
# Returns:
#   0 on success, prints extraction path to stdout
#   1 if parameters missing or ISO file not found
#   2 if mount/extraction fails
#===============================================================================
extract_alpine_iso() {
    local iso_path="$1"
    local alpine_version="$2"
    
    if [[ -z "$iso_path" ]]; then
        hps_log "ERROR" "extract_alpine_iso: iso_path required"
        return 1
    fi
    
    if [[ ! -f "$iso_path" ]]; then
        hps_log "ERROR" "extract_alpine_iso: ISO file not found: $iso_path"
        return 1
    fi
    
    if [[ -z "$HPS_RESOURCES" ]]; then
        hps_log "ERROR" "extract_alpine_iso: HPS_RESOURCES not set"
        return 1
    fi
    
    # Auto-detect version from filename if not provided
    if [[ -z "$alpine_version" ]]; then
        alpine_version=$(basename "$iso_path" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        if [[ -z "$alpine_version" ]]; then
            hps_log "ERROR" "extract_alpine_iso: Could not detect Alpine version from filename"
            return 1
        fi
        hps_log "INFO" "Auto-detected Alpine version: $alpine_version"
    fi
    
    local extract_dir="${HPS_RESOURCES%/}/distros/alpine-${alpine_version}"
    local mount_point="/tmp/alpine_iso_mount_$$"
    
    # Check if already extracted
    if [[ -d "$extract_dir" && -n "$(ls -A "$extract_dir" 2>/dev/null)" ]]; then
        hps_log "INFO" "Alpine ${alpine_version} already extracted: $extract_dir"
        echo "$extract_dir"
        return 0
    fi
    
    hps_log "INFO" "Extracting Alpine ISO: $iso_path -> $extract_dir"
    
    # Create mount point and extraction directory
    if ! mkdir -p "$mount_point" "$extract_dir"; then
        hps_log "ERROR" "extract_alpine_iso: Failed to create directories"
        return 2
    fi
    
    # Mount ISO as loop device
    if ! mount -o loop,ro "$iso_path" "$mount_point"; then
        hps_log "ERROR" "extract_alpine_iso: Failed to mount ISO"
        rmdir "$mount_point" 2>/dev/null
        return 2
    fi
    
    # Copy all contents preserving permissions and timestamps
    if ! cp -a "$mount_point"/* "$extract_dir"/; then
        hps_log "ERROR" "extract_alpine_iso: Failed to copy ISO contents"
        umount "$mount_point" 2>/dev/null
        rmdir "$mount_point" 2>/dev/null
        return 2
    fi
    
    # Unmount and cleanup
    if ! umount "$mount_point"; then
        hps_log "WARN" "extract_alpine_iso: Failed to unmount $mount_point"
    fi
    rmdir "$mount_point" 2>/dev/null
    
    hps_log "INFO" "Alpine ISO extracted successfully: $extract_dir"
    echo "$extract_dir"
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


