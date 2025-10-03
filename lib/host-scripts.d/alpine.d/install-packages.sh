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
    
    # Match and download requested packages
    local -a packages_to_install=()
    local missing_packages=()
    
    for pkg_name in "${package_names[@]}"; do
        # Find matching package file (matches pkg_name-*.apk)
        local pkg_file=$(echo "$available_packages" | grep "^${pkg_name}-[0-9]" | head -1)
        
        if [[ -z "$pkg_file" ]]; then
            missing_packages+=("$pkg_name")
            n_remote_log "Package not found: ${pkg_name}"
            continue
        fi
        
        echo "Downloading: ${pkg_file}"
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


n_queue_add n_install_apk_packages_from_ips opensvc-server opensvc-client


