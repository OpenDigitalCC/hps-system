# TCH Build Functions
# Functions for building and managing Alpine-based TCH images

__guard_source || return




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


