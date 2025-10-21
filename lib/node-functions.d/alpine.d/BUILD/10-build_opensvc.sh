

#===============================================================================
# n_build_opensvc_package
# -----------------------
# Main wrapper to build OpenSVC Alpine APK packages from source.
#
# Parameters:
#   --alpine-version <version>  : Target Alpine version (default: auto-detect)
#   --om3-version <tag>         : Specific opensvc git tag (default: latest compatible)
#   --keep-build                : Don't clean up build directory after completion
#
# Behaviour:
#   - Checks network connectivity to proxy.golang.org
#   - Verifies build dependencies
#   - Clones/updates opensvc source
#   - Selects version (auto-selects latest compatible with installed Go)
#   - Checks Go version compatibility
#   - Prepares build directory
#   - Builds binaries
#   - Creates and builds APK packages
#   - Cleans up build directory unless --keep-build specified
#
# Output:
#   Progress through each build stage
#   Final package locations
#
# Returns:
#   0 on complete success
#   1 on any failure
#===============================================================================
n_build_opensvc_package() {
    local alpine_version=""
    local om3_version=""
    local keep_build=0
    local source_dir="$(get_src_dir)"
    
    # Parse command line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --alpine-version)
                alpine_version="$2"
                shift 2
                ;;
            --om3-version)
                om3_version="$2"
                shift 2
                ;;
            --keep-build)
                keep_build=1
                shift
                ;;
            --help)
                echo "Usage: n_build_opensvc_package [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --alpine-version <version>  Target Alpine version (default: auto-detect)"
                echo "  --om3-version <tag>         Specific opensvc git tag (default: latest compatible)"
                echo "  --keep-build                Don't clean up build directory"
                echo "  --help                      Show this help message"
                return 0
                ;;
            *)
                echo "Error: Unknown option: $1"
                echo "Use --help for usage information"
                return 1
                ;;
        esac
    done
    
    echo "========================================"
    echo "OpenSVC Alpine APK Package Builder"
    echo "========================================"
    echo ""

    
    # Step 1: Check network connectivity
    echo "Step 1: Checking network connectivity..."
    if ! timeout 5 nc -zw 2 proxy.golang.org 443 2>/dev/null; then
        echo "Error: Cannot reach proxy.golang.org"
        echo "Internet access is required to download Go dependencies"
        echo "Please ensure network connectivity and try again"
        n_remote_log "OpenSVC build failed: No internet access"
        return 1
    fi
    echo "  Network connectivity: OK"
    echo ""
    
    # Step 2: Check build dependencies
    echo "Step 2: Checking build dependencies..."
    if ! n_check_build_dependencies; then
        echo "Build dependencies check failed"
        return 1
    fi
    echo ""
    
    # Step 3: Clone or update source
    echo "Step 3: Managing source repository..."
    if ! n_clone_or_update_opensvc_source; then
        echo "Source repository management failed"
        return 1
    fi
    echo ""
    
    # Step 4: Select version
    echo "Step 4: Selecting opensvc version..."
    if [ -n "$om3_version" ]; then
        # User specified a version
        echo "Using specified version: $om3_version"
        if ! n_select_opensvc_version "$om3_version"; then
            echo "Version selection failed"
            return 1
        fi
    else
        # Auto-select latest compatible version
        echo "Auto-selecting latest compatible version..."
        
        # Get installed Go version
        local installed_go=$(go version | awk '{print $3}' | sed 's/go//')
        local go_major=$(echo "$installed_go" | cut -d. -f1)
        local go_minor=$(echo "$installed_go" | cut -d. -f2)
        
        echo "Installed Go version: $installed_go"
        echo "Searching for compatible opensvc versions..."
        
        # Get all version tags and check compatibility
        local compatible_version=""
        for tag in $(git -C "$source_dir" tag -l 'v*.*.*' | sort -Vr); do
            local required=$(git -C "$source_dir" show "$tag:go.mod" 2>/dev/null | grep "^go " | awk '{print $2}')
            if [ -n "$required" ]; then
                local req_major=$(echo "$required" | cut -d. -f1)
                local req_minor=$(echo "$required" | cut -d. -f2)
                
                if [ "$go_major" -gt "$req_major" ] || \
                   ([ "$go_major" -eq "$req_major" ] && [ "$go_minor" -ge "$req_minor" ]); then
                    compatible_version="$tag"
                    echo "Found compatible version: $tag (requires Go $required)"
                    break
                fi
            fi
        done
        
        if [ -z "$compatible_version" ]; then
            echo "Error: No compatible opensvc version found for Go $installed_go"
            echo "Consider upgrading Go or specify a version with --om3-version"
            return 1
        fi
        
        if ! n_select_opensvc_version "$compatible_version"; then
            echo "Version selection failed"
            return 1
        fi
    fi
    echo ""
    
    # Step 5: Check Go version compatibility
    echo "Step 5: Checking Go version compatibility..."
    if ! n_check_go_version_compatibility "$OPENSVC_GIT_TAG"; then
        echo "Go version compatibility check failed"
        return 1
    fi
    echo ""
    
    # Step 6: Prepare build directory
    echo "Step 6: Preparing build directory..."
    if ! n_prepare_build_directory; then
        echo "Build directory preparation failed"
        return 1
    fi
    echo ""
    
    # Step 7: Build binaries
    echo "Step 7: Building opensvc binaries..."
    if ! n_build_opensvc_binaries; then
        echo "Binary build failed"
        return 1
    fi
    echo ""
    
    # Step 8: Create APK package structure
    echo "Step 8: Creating APK package structure..."
    if ! n_create_apk_package_structure; then
        echo "APK package structure creation failed"
        return 1
    fi
    echo ""
    
    # Step 9: Build APK packages
    echo "Step 9: Building APK packages..."
    if ! n_build_apk_packages; then
        echo "APK package build failed"
        return 1
    fi
    echo ""
    
    # Step 10: Cleanup
    if [ $keep_build -eq 0 ]; then
        echo "Step 9: Cleaning up build directory..."
        if [ -n "$OPENSVC_BUILD_DIR" ] && [ -d "$OPENSVC_BUILD_DIR" ]; then
            echo "Removing: $OPENSVC_BUILD_DIR"
            rm -rf "$OPENSVC_BUILD_DIR"
            echo "  Cleanup complete"
        fi
    else
        echo "Step 9: Skipping cleanup (--keep-build specified)"
        echo "  Build directory: $OPENSVC_BUILD_DIR"
    fi
    echo ""
    
    echo "========================================"
    echo "Build Process Summary"
    echo "========================================"
    echo "Version: $OPENSVC_VERSION"
    echo "Git Tag: $OPENSVC_GIT_TAG"
    if [ $keep_build -eq 1 ]; then
        echo "Binaries:"
        echo "  om: $OPENSVC_BUILD_DIR/bin/om"
        echo "  ox: $OPENSVC_BUILD_DIR/bin/ox"
    fi
    echo ""
    echo "Build completed successfully!"
    
    n_remote_log "Successfully built opensvc $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_build_opensvc_package "$@"
fi




#===============================================================================
# n_build_apk_packages
# --------------------
# Build APK packages from prepared package structures using abuild.
#
# Environment Variables Required:
#   OPENSVC_SERVER_PKG_DIR     - server package directory
#   OPENSVC_CLIENT_PKG_DIR     - client package directory
#   OPENSVC_PACKAGE_BASE_DIR   - base output directory
#   OPENSVC_VERSION            - package version
#
# Behaviour:
#   - Changes to each package directory
#   - Runs abuild checksum to generate checksums
#   - Runs abuild -r to build the package
#   - Moves resulting .apk files to output directory
#   - Reports package locations and sizes
#
# Output:
#   Build progress and final package information
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_build_apk_packages() {
  
    local packages_dir="$(get_dst_dir)"
    mkdir -p $packages_dir


    # Check required environment variables
    if [ -z "$OPENSVC_SERVER_PKG_DIR" ]; then
        echo "Error: OPENSVC_SERVER_PKG_DIR not set"
        return 1
    fi
    
    if [ -z "$OPENSVC_CLIENT_PKG_DIR" ]; then
        echo "Error: OPENSVC_CLIENT_PKG_DIR not set"
        return 1
    fi
    
    if [ -z "$OPENSVC_PACKAGE_BASE_DIR" ]; then
        echo "Error: OPENSVC_PACKAGE_BASE_DIR not set"
        return 1
    fi
    
    if [ -z "$OPENSVC_VERSION" ]; then
        echo "Error: OPENSVC_VERSION not set"
        return 1
    fi
    
    # Verify package directories exist
    if [ ! -d "$OPENSVC_SERVER_PKG_DIR" ]; then
        echo "Error: Server package directory does not exist: $OPENSVC_SERVER_PKG_DIR"
        return 1
    fi
    
    if [ ! -d "$OPENSVC_CLIENT_PKG_DIR" ]; then
        echo "Error: Client package directory does not exist: $OPENSVC_CLIENT_PKG_DIR"
        return 1
    fi
    
    echo "Building APK packages..."
    echo ""
    
    # Build opensvc-server package
    echo "Building opensvc-server package..."
    cd "$OPENSVC_SERVER_PKG_DIR" || {
        echo "Error: Failed to change to server package directory"
        return 1
    }
    
    echo "  Generating checksums..."
    # abuild checksum also has root check, run with checksum generation
    abuild -P ${packages_dir} -F checksum 2>&1 || echo "  (checksum generation skipped or failed, continuing...)"
    
    echo "  Generating keys"
    abuild-keygen -a -n
    
    
    echo "  Building package..."
    # Run abuild, ignore exit code since index creation may fail but package is built
    abuild -P ${packages_dir} -F -d -K -r 2>&1 || true
    
    echo "  opensvc-server package built successfully"
    echo ""
    
    # Build opensvc-client package
    echo "Building opensvc-client package..."
    cd "$OPENSVC_CLIENT_PKG_DIR" || {
        echo "Error: Failed to change to client package directory"
        return 1
    }
    
    echo "  Generating checksums..."
    # abuild checksum also has root check, run with checksum generation
    abuild -P ${packages_dir} -F checksum 2>&1 || echo "  (checksum generation skipped or failed, continuing...)"
    
    echo "  Building package..."
    # Run abuild, ignore exit code since index creation may fail but package is built
    abuild  -P ${packages_dir}  -F -d -K -r 2>&1 || true
    
    echo "  opensvc-client package built successfully"
    echo ""
    
    # Find and report built packages
    echo "Locating built packages..."
    
    if [ ! -d "$packages_dir" ]; then
        echo "Error: Package directory not found: $packages_dir"
        return 1
    fi
    
    # Transform version for package filename (underscore format)
    local apk_version="${OPENSVC_VERSION/-/_}"
    
    local server_pkg="$packages_dir/workdir/x86_64/opensvc-server-${apk_version}-r0.apk"
    local client_pkg="$packages_dir/workdir/x86_64/opensvc-client-${apk_version}-r0.apk"
       
    # Verify packages were created
    if [ ! -f "$server_pkg" ]; then
        echo "Error: Server package not found at: $server_pkg"
        return 1
    fi
    
    if [ ! -f "$client_pkg" ]; then
        echo "Error: Client package not found at: $client_pkg"
        return 1
    fi
    
    # Report package information
    local server_size=$(ls -lh "$server_pkg" | awk '{print $5}')
    local client_size=$(ls -lh "$client_pkg" | awk '{print $5}')
    
    echo "  opensvc-server-${apk_version}-r0.apk ($server_size)"
    echo "  opensvc-client-${apk_version}-r0.apk ($client_size)"
    
    # Copy packages to HPS packages directory
    echo ""
    echo "Copying packages to: $OPENSVC_PACKAGE_BASE_DIR"
    
    cp "$server_pkg" "$OPENSVC_PACKAGE_BASE_DIR/" || {
        echo "Error: Failed to copy server package"
        return 1
    }
    
    cp "$client_pkg" "$OPENSVC_PACKAGE_BASE_DIR/" || {
        echo "Error: Failed to copy client package"
        return 1
    }
    
    echo "  Packages copied successfully to $OPENSVC_PACKAGE_BASE_DIR"
    
    echo ""
    echo "APK package build completed successfully"
    
    n_remote_log "Built opensvc APK packages version $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_build_apk_packages
fi


#===============================================================================
# n_create_apk_package_structure
# -------------------------------
# Create Alpine APKBUILD files and package directory structure for OpenSVC.
#
# Environment Variables Required:
#   OPENSVC_VERSION   - version being packaged (e.g., "3.0.0-alpha67")
#   OPENSVC_BUILD_DIR - build directory containing binaries
#
# Behaviour:
#   - Creates package working directories for opensvc-server and opensvc-client
#   - Generates APKBUILD files with proper metadata
#   - Creates FHS-compliant directory structure
#   - Generates OpenRC init script for opensvc-server
#   - Copies binaries to package directories
#   - Sets proper permissions
#
# Output:
#   Package directories ready for abuild
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_create_apk_package_structure() {
    
    # Check required environment variables
    if [ -z "$OPENSVC_VERSION" ]; then
        echo "Error: OPENSVC_VERSION not set"
        return 1
    fi
    
    # Transform version to Alpine format (replace hyphens with underscores after major.minor.patch)
    # e.g., 3.0.0-alpha67 -> 3.0.0_alpha67
    local apk_version="${OPENSVC_VERSION/-/_}"
    
    if [ -z "$OPENSVC_BUILD_DIR" ]; then
        echo "Error: OPENSVC_BUILD_DIR not set"
        return 1
    fi
    
    if [ ! -d "$OPENSVC_BUILD_DIR" ]; then
        echo "Error: Build directory does not exist: $OPENSVC_BUILD_DIR"
        return 1
    fi
    
    # Verify binaries exist
    if [ ! -f "$OPENSVC_BUILD_DIR/bin/om" ]; then
        echo "Error: om binary not found at: $OPENSVC_BUILD_DIR/bin/om"
        return 1
    fi
    
    if [ ! -f "$OPENSVC_BUILD_DIR/bin/ox" ]; then
        echo "Error: ox binary not found at: $OPENSVC_BUILD_DIR/bin/ox"
        return 1
    fi
    
    # Detect Alpine version
    local alpine_version=""
    if [ -f /etc/alpine-release ]; then
        alpine_version=$(cat /etc/alpine-release | cut -d. -f1,2)
    else
        echo "Warning: Cannot detect Alpine version, using 3.20"
        alpine_version="3.20"
    fi
    
    local package_base_dir="$(get_dst_dir)/x86_64-alpine-linux-${alpine_version}"
    local work_dir="$(get_dst_dir)/workdir"
    
    echo "Creating APK package structure..."
    echo "  Version: $OPENSVC_VERSION"
    echo "  APK Version: $apk_version"
    echo "  Alpine: $alpine_version"
    echo "  Package dir: $package_base_dir"
    echo ""
    
    # Create base directories
    mkdir -p "$package_base_dir"
    mkdir -p "$work_dir"
    
    # Create opensvc-server package structure
    local server_pkg_dir="$work_dir/opensvc-server"
    echo "Creating opensvc-server package structure..."
    
    mkdir -p "$server_pkg_dir"
    mkdir -p "$server_pkg_dir/usr/bin"
    mkdir -p "$server_pkg_dir/etc/init.d"
    mkdir -p "$server_pkg_dir/var/lib/opensvc"
    
    # Copy om binary
    cp "$OPENSVC_BUILD_DIR/bin/om" "$server_pkg_dir/usr/bin/om"
    chmod 755 "$server_pkg_dir/usr/bin/om"
    
    # Create OpenRC init script
    cat > "$server_pkg_dir/etc/init.d/opensvc-server" << 'EOF'
#!/sbin/openrc-run
# /etc/init.d/opensvc-server
# OpenRC init script for the OpenSVC server.

description="OpenSVC server"
command="/usr/bin/om"
command_args="daemon start"
pidfile="/var/lib/opensvc/osvcd.pid"

depend() {
    need net
    use docker libvirtd libvirt-guests blk-availability drbd
    after time-sync
}

start_pre() {
    if [ -w /proc/self/oom_score_adj ]; then
        echo -1000 > /proc/self/oom_score_adj
    fi
    
    # Ensure data directory exists
    if [ ! -d /var/lib/opensvc ]; then
        mkdir -p /var/lib/opensvc
    fi
}
EOF
    chmod 755 "$server_pkg_dir/etc/init.d/opensvc-server"
    
    # Create APKBUILD for opensvc-server
    cat > "$work_dir/opensvc-server/APKBUILD" << EOF
# Maintainer: HPS System <support@hps-system.org>
pkgname=opensvc-server
pkgver=$apk_version
pkgrel=0
pkgdesc="OpenSVC cluster orchestrator - server daemon"
url="https://www.opensvc.com"
arch="x86_64"
license="Apache-2.0"
depends=""
makedepends=""
install="\$pkgname.post-install"
subpackages=""
source=""
builddir="\$srcdir"
options="!check"

build() {
    return 0
}

package() {
    mkdir -p "\$pkgdir"
    cp -a "\$startdir"/usr "\$pkgdir"/
    cp -a "\$startdir"/etc "\$pkgdir"/
    cp -a "\$startdir"/var "\$pkgdir"/
}
EOF
    
    # Create post-install script for opensvc-server
    cat > "$work_dir/opensvc-server/opensvc-server.post-install" << 'EOF'
#!/bin/sh
# Ensure data directory has correct permissions
mkdir -p /var/lib/opensvc
chmod 755 /var/lib/opensvc

# Add to default runlevel if not already there
if command -v rc-update >/dev/null 2>&1; then
    rc-update add opensvc-server default 2>/dev/null || true
fi

echo "OpenSVC server installed successfully"
echo "To start the service: rc-service opensvc-server start"
EOF
    chmod 755 "$work_dir/opensvc-server/opensvc-server.post-install"
    
    echo "  opensvc-server structure created"
    
    # Create opensvc-client package structure
    local client_pkg_dir="$work_dir/opensvc-client"
    echo "Creating opensvc-client package structure..."
    
    mkdir -p "$client_pkg_dir"
    mkdir -p "$client_pkg_dir/usr/bin"
    
    # Copy ox binary
    cp "$OPENSVC_BUILD_DIR/bin/ox" "$client_pkg_dir/usr/bin/ox"
    chmod 755 "$client_pkg_dir/usr/bin/ox"
    
    # Create APKBUILD for opensvc-client
    cat > "$work_dir/opensvc-client/APKBUILD" << EOF
# Maintainer: HPS System <support@hps-system.org>
pkgname=opensvc-client
pkgver=$apk_version
pkgrel=0
pkgdesc="OpenSVC cluster orchestrator - API client and TUI"
url="https://www.opensvc.com"
arch="x86_64"
license="Apache-2.0"
depends=""
makedepends=""
subpackages=""
source=""
builddir="\$srcdir"
options="!check"

build() {
    return 0
}

package() {
    mkdir -p "\$pkgdir"
    cp -a "\$startdir"/usr "\$pkgdir"/
}
EOF
    
    echo "  opensvc-client structure created"
    echo ""
    
    echo "Package structure creation completed successfully:"
    echo "  Server package: $server_pkg_dir"
    echo "  Client package: $client_pkg_dir"
    
    # Export for next function
    export OPENSVC_SERVER_PKG_DIR="$server_pkg_dir"
    export OPENSVC_CLIENT_PKG_DIR="$client_pkg_dir"
    export OPENSVC_PACKAGE_BASE_DIR="$package_base_dir"
    
    n_remote_log "Created APK package structure for opensvc $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_create_apk_package_structure
fi


#===============================================================================
# n_clone_or_update_opensvc_source
# ---------------------------------
# Clone or update the opensvc/om3 source repository.
#
# Behaviour:
#   - Target directory: $(get_src_dir)/
#   - If directory exists and is valid git repo: fetch updates and tags
#   - If directory doesn't exist: attempt to clone from GitHub
#   - If clone fails (air-gapped): create directory and instruct user
#   - Uses n_remote_log for material operations
#
# Output:
#   Status messages about clone/update progress
#   Instructions for manual source placement if network unavailable
#   Current HEAD information after operation
#
# Returns:
#   0 on success (cloned or updated)
#   1 on failure (requires manual intervention)
#===============================================================================
n_clone_or_update_opensvc_source() {
    local source_dir="$(get_src_dir)"
    local repo_url="https://github.com/opensvc/om3"
    
    echo "Managing opensvc/om3 source repository..."
    
    if [ -d "$source_dir" ]; then
        echo "Source directory exists: $source_dir"
        
        # Check if it's a valid git repository
        if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
            # Check if it's an ownership issue
            if git -C "$source_dir" rev-parse --git-dir 2>&1 | grep -q "dubious ownership"; then
                echo "Configuring git safe.directory for: $source_dir"
                git config --global --add safe.directory "$source_dir"
                # Try again after adding safe.directory
                if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
                    echo "Error: Directory exists but is not a valid git repository"
                    n_remote_log "opensvc-om3 source directory invalid: $source_dir"
                    return 1
                fi
            else
                echo "Error: Directory exists but is not a valid git repository"
                n_remote_log "opensvc-om3 source directory invalid: $source_dir"
                return 1
            fi
        fi
        
        echo "Attempting to fetch updates from remote..."
        if git -C "$source_dir" fetch --all --tags >/dev/null 2>&1; then
            n_remote_log "Updated opensvc-om3 source from remote"
            echo "Repository updated successfully"
        else
            echo "Warning: Could not fetch updates (network unavailable or air-gapped system)"
            echo "Using existing local repository"
        fi
        
    else
        echo "Source directory does not exist"
        
        # Create parent directory if needed
        local parent_dir=$(dirname "$source_dir")
        if [ ! -d "$parent_dir" ]; then
            echo "Creating parent directory: $parent_dir"
            mkdir -p "$parent_dir" || {
                echo "Error: Failed to create parent directory"
                return 1
            }
        fi
        
        # Attempt to clone
        echo "Attempting to clone from: $repo_url"
        if git clone "$repo_url" "$source_dir" >/dev/null 2>&1; then
            echo "Repository cloned successfully"
            git -C "$source_dir" fetch --tags >/dev/null 2>&1
            n_remote_log "Cloned opensvc-om3 source from GitHub"
        else
            echo ""
            echo "=========================================="
            echo "ERROR: Cannot clone repository (air-gapped system or network unavailable)"
            echo ""
            echo "Manual action required:"
            echo "  1. On a system with internet access, run:"
            echo "     git clone $repo_url"
            echo ""
            echo "  2. Copy the entire 'om3' directory to this system"
            echo ""
            echo "  3. Place it at: $source_dir"
            echo ""
            echo "  4. Ensure the .git directory is included"
            echo "=========================================="
            echo ""
            n_remote_log "opensvc-om3 clone failed - manual source placement required at $source_dir"
            
            # Create placeholder directory
            mkdir -p "$source_dir"
            
            return 1
        fi
    fi
    
    # Show current state
    echo ""
    echo "Current repository state:"
    local current_branch=$(git -C "$source_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local current_commit=$(git -C "$source_dir" rev-parse --short HEAD 2>/dev/null)
    echo "  Branch: $current_branch"
    echo "  Commit: $current_commit"
    
    local tag_count=$(git -C "$source_dir" tag | wc -l)
    echo "  Tags available: $tag_count"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_clone_or_update_opensvc_source
fi



#===============================================================================
# n_select_opensvc_version
# ------------------------
# Select and checkout a specific version of opensvc/om3 source.
#
# Parameters:
#   $1 (optional): Specific git tag to use (e.g., "v3.2.1")
#                  If not provided, automatically selects latest semantic version
#
# Behaviour:
#   - If version parameter provided: checkout that specific tag
#   - If no parameter: find latest semantic version tag and checkout
#   - Verifies checkout succeeded
#   - Exports version variables for package building
#
# Environment Variables Set:
#   OPENSVC_VERSION    - version without 'v' prefix (e.g., "3.2.1")
#   OPENSVC_GIT_TAG    - full git tag (e.g., "v3.2.1")
#
# Output:
#   Selected version and checkout confirmation
#
# Returns:
#   0 on success
#   1 if tag doesn't exist or checkout fails
#===============================================================================
n_select_opensvc_version() {
    local source_dir="$(get_src_dir)"
    local requested_tag="$1"
    local selected_tag=""
    
    # Verify source directory exists and is valid git repo
    if [ ! -d "$source_dir" ]; then
        echo "Error: Source directory does not exist: $source_dir"
        echo "Run n_clone_or_update_opensvc_source first"
        return 1
    fi
    
    if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Error: Not a valid git repository: $source_dir"
        return 1
    fi
    
    echo "Selecting opensvc version..."
    
    if [ -n "$requested_tag" ]; then
        # Use specified tag
        selected_tag="$requested_tag"
        echo "Using requested version: $selected_tag"
        
        # Verify tag exists
        if ! git -C "$source_dir" rev-parse "$selected_tag" >/dev/null 2>&1; then
            echo "Error: Tag '$selected_tag' does not exist"
            echo "Available tags:"
            git -C "$source_dir" tag | tail -10
            return 1
        fi
    else
        # Find latest semantic version tag
        echo "Finding latest semantic version tag..."
        
        # Get all tags matching v*.*.* pattern and sort
        selected_tag=$(git -C "$source_dir" tag -l 'v*.*.*' | \
            sort -V | \
            tail -1)
        
        if [ -z "$selected_tag" ]; then
            echo "Error: No semantic version tags found (v*.*.*)"
            echo "Available tags:"
            git -C "$source_dir" tag | head -20
            return 1
        fi
        
        echo "Latest version found: $selected_tag"
    fi
    
    # Checkout the selected tag
    echo "Checking out: $selected_tag"
    if ! git -C "$source_dir" checkout "$selected_tag" >/dev/null 2>&1; then
        echo "Error: Failed to checkout tag: $selected_tag"
        return 1
    fi
    
    # Export version variables
    export OPENSVC_GIT_TAG="$selected_tag"
    export OPENSVC_VERSION="${selected_tag#v}"  # Remove leading 'v'
    
    echo ""
    echo "Version selected successfully:"
    echo "  Git Tag: $OPENSVC_GIT_TAG"
    echo "  Version: $OPENSVC_VERSION"
    
    n_remote_log "Selected opensvc version: $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_select_opensvc_version "$@"
fi


#===============================================================================
# n_prepare_build_directory
# --------------------------
# Create and prepare a temporary build directory with opensvc source code.
#
# Environment Variables Required:
#   OPENSVC_VERSION - version being built (set by n_select_opensvc_version)
#
# Behaviour:
#   - Creates temporary build directory: /tmp/opensvc-build-$$
#   - Copies source tree from $(get_src_dir)/
#   - Sets up Go build environment for static compilation
#   - Exports build directory path for other functions
#
# Environment Variables Set:
#   OPENSVC_BUILD_DIR - path to temporary build directory
#   CGO_ENABLED=0     - for static binary compilation
#
# Output:
#   Build directory path and copy progress
#
# Returns:
#   0 on success
#   1 if source directory missing, copy fails, or OPENSVC_VERSION not set
#===============================================================================
n_prepare_build_directory() {
    local source_dir="$(get_src_dir)"
    
    # Check that version is set
    if [ -z "$OPENSVC_VERSION" ]; then
        echo "Error: OPENSVC_VERSION not set"
        echo "Run n_select_opensvc_version first"
        return 1
    fi
    
    # Verify source directory exists
    if [ ! -d "$source_dir" ]; then
        echo "Error: Source directory does not exist: $source_dir"
        echo "Run n_clone_or_update_opensvc_source first"
        return 1
    fi
    
    echo "Preparing build directory for opensvc $OPENSVC_VERSION..."
    
    # Create temporary build directory
    export OPENSVC_BUILD_DIR="/tmp/opensvc-build-$$"
    
    if [ -d "$OPENSVC_BUILD_DIR" ]; then
        echo "Warning: Build directory already exists, removing..."
        rm -rf "$OPENSVC_BUILD_DIR"
    fi
    
    echo "Creating build directory: $OPENSVC_BUILD_DIR"
    if ! mkdir -p "$OPENSVC_BUILD_DIR"; then
        echo "Error: Failed to create build directory"
        return 1
    fi
    
    # Copy source tree to build directory
    echo "Copying source tree..."
    if ! cp -a "$source_dir/." "$OPENSVC_BUILD_DIR/"; then
        echo "Error: Failed to copy source tree"
        rm -rf "$OPENSVC_BUILD_DIR"
        return 1
    fi
    
    # Set up Go build environment for static compilation
    export CGO_ENABLED=0
    
    echo ""
    echo "Build directory prepared successfully:"
    echo "  Build directory: $OPENSVC_BUILD_DIR"
    echo "  CGO_ENABLED: $CGO_ENABLED"
    echo "  Version: $OPENSVC_VERSION"
    
    n_remote_log "Prepared opensvc build directory for version $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_prepare_build_directory
fi


#===============================================================================
# n_build_opensvc_binaries
# -------------------------
# Compile the opensvc om and ox binaries.
#
# Environment Variables Required:
#   OPENSVC_BUILD_DIR - build directory path (set by n_prepare_build_directory)
#   OPENSVC_VERSION   - version being built
#   CGO_ENABLED=0     - for static compilation
#
# Behaviour:
#   - Changes to build directory
#   - Runs make om ox to build both binaries
#   - Verifies binaries were created
#   - Reports binary information
#
# Output:
#   Build progress messages
#   Binary information (location, size)
#
# Returns:
#   0 on success (both binaries built)
#   1 if make fails or binaries not created
#===============================================================================
n_build_opensvc_binaries() {
    
    # Check required environment variables
    if [ -z "$OPENSVC_BUILD_DIR" ]; then
        echo "Error: OPENSVC_BUILD_DIR not set"
        echo "Run n_prepare_build_directory first"
        return 1
    fi
    
    if [ -z "$OPENSVC_VERSION" ]; then
        echo "Error: OPENSVC_VERSION not set"
        echo "Run n_select_opensvc_version first"
        return 1
    fi
    
    if [ ! -d "$OPENSVC_BUILD_DIR" ]; then
        echo "Error: Build directory does not exist: $OPENSVC_BUILD_DIR"
        return 1
    fi
    
    echo "Building opensvc binaries..."
    echo "  Version: $OPENSVC_VERSION"
    echo "  Build directory: $OPENSVC_BUILD_DIR"
    echo ""
    
    # Change to build directory
    cd "$OPENSVC_BUILD_DIR" || {
        echo "Error: Failed to change to build directory"
        return 1
    }
    
    # Handle git safe.directory for build directory
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        if git rev-parse --git-dir 2>&1 | grep -q "dubious ownership"; then
            echo "Configuring git safe.directory for build directory"
            git config --global --add safe.directory "$OPENSVC_BUILD_DIR"
        fi
    fi
    
    # Build the binaries
    echo "Running: make om ox"
    if ! make om ox; then
        echo "Error: Build failed"
        n_remote_log "opensvc build failed for version $OPENSVC_VERSION"
        return 1
    fi
    
    echo ""
    echo "Verifying binaries..."
    
    # Check that binaries were created
    local om_binary="$OPENSVC_BUILD_DIR/bin/om"
    local ox_binary="$OPENSVC_BUILD_DIR/bin/ox"
    
    if [ ! -f "$om_binary" ]; then
        echo "Error: om binary not found at: $om_binary"
        return 1
    fi
    
    if [ ! -f "$ox_binary" ]; then
        echo "Error: ox binary not found at: $ox_binary"
        return 1
    fi
    
    # Make binaries executable
    chmod +x "$om_binary" "$ox_binary"
    
    # Report binary information
    echo ""
    echo "Build completed successfully:"
    echo "  om binary: $om_binary"
    echo "    Size: $(ls -lh "$om_binary" | awk '{print $5}')"
    echo "  ox binary: $ox_binary"
    echo "    Size: $(ls -lh "$ox_binary" | awk '{print $5}')"
    
    n_remote_log "Built opensvc binaries for version $OPENSVC_VERSION"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_build_opensvc_binaries
fi


#===============================================================================
# n_check_go_version_compatibility
# ---------------------------------
# Check if installed Go version is compatible with opensvc source requirements.
#
# Parameters:
#   $1: opensvc git tag (e.g., "v3.0.0-alpha67")
#
# Behaviour:
#   - Reads go.mod from specified git tag
#   - Extracts required Go version from go.mod
#   - Compares with installed Go version
#   - Reports compatibility status
#
# Output:
#   Compatibility status and version information
#
# Returns:
#   0 if compatible or if version requirement cannot be determined
#   1 if incompatible
#===============================================================================
n_check_go_version_compatibility() {
    local git_tag="$1"
    local source_dir="$(get_src_dir)"
    
    if [ -z "$git_tag" ]; then
        echo "Error: No git tag specified"
        return 1
    fi
    
    # Check if source directory exists
    if [ ! -d "$source_dir" ]; then
        echo "Error: Source directory does not exist: $source_dir"
        return 1
    fi
    
    # Get installed Go version
    if ! command -v go >/dev/null 2>&1; then
        echo "Error: Go not installed"
        return 1
    fi
    
    local installed_version=$(go version | awk '{print $3}' | sed 's/go//')
    local installed_major=$(echo "$installed_version" | cut -d. -f1)
    local installed_minor=$(echo "$installed_version" | cut -d. -f2)
    
    # Get required Go version from go.mod
    local required_version=$(git -C "$source_dir" show "$git_tag:go.mod" 2>/dev/null | grep "^go " | awk '{print $2}')
    
    if [ -z "$required_version" ]; then
        echo "Warning: Could not determine required Go version from $git_tag"
        echo "Installed Go version: $installed_version"
        return 0
    fi
    
    local required_major=$(echo "$required_version" | cut -d. -f1)
    local required_minor=$(echo "$required_version" | cut -d. -f2)
    
    echo "Go version compatibility check:"
    echo "  Required: $required_version"
    echo "  Installed: $installed_version"
    
    # Compare versions
    if [ "$installed_major" -gt "$required_major" ] || \
       ([ "$installed_major" -eq "$required_major" ] && [ "$installed_minor" -ge "$required_minor" ]); then
        echo "  Status: Compatible"
        return 0
    else
        echo "  Status: Incompatible"
        echo ""
        echo "Error: Go version $installed_version is below required $required_version"
        return 1
    fi
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_check_go_version_compatibility "$@"
fi


