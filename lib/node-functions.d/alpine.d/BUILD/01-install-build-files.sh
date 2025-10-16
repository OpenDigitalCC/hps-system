


#===============================================================================
# n_check_build_dependencies
# --------------------------
# Verify required build tools are present for building OpenSVC Alpine APK packages.
#
# Behaviour:
#   - Checks for presence of required commands from package array
#   - Reports status of each dependency
#   - Uses n_remote_log for material events (missing dependencies)
#   - Provides installation command for missing packages
#
# Output:
#   Prints status for each dependency
#   Lists missing dependencies with apk install command
#
# Returns:
#   0 if all dependencies present
#   1 if any dependency missing
#===============================================================================
n_check_build_dependencies() {
    # Array format: "command:package"
    # When command and package name differ, specify both
    # When same, just use command name
    local deps=(
        "git"
        "go"
        "make"
        "abuild"
        "abuild-keygen:abuild"
    )
    
    local missing_packages=()
    local check_failed=0
    
    echo "Checking build dependencies..."
    
    for dep in "${deps[@]}"; do
        local cmd="${dep%%:*}"
        local pkg="${dep#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "  [✓] $cmd"
        else
            echo "  [✗] $cmd not found"
            # Add package to missing list if not already there
            if [[ ! " ${missing_packages[@]} " =~ " ${pkg} " ]]; then
                missing_packages+=("$pkg")
            fi
            check_failed=1
        fi
    done
    
    echo ""
    
    if [ $check_failed -eq 1 ]; then
        local install_cmd="apk add ${missing_packages[*]}"
        echo "Missing dependencies: ${missing_packages[*]}"
        echo "Install with: $install_cmd"
        n_remote_log "Build dependencies missing: ${missing_packages[*]}"
        echo ""
        echo "Build environment check: FAILED"
        return 1
    else
        echo "Build environment check: PASSED"
        return 0
    fi
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_check_build_dependencies
fi

#===============================================================================
# n_setup_build_user
# ------------------
# Create and configure a non-root user for building Alpine packages.
#
# Behaviour:
#   - Creates 'builder' user if it doesn't exist
#   - Adds builder to 'abuild' group
#   - Generates abuild signing key for builder user
#   - Configures abuild environment
#   - Sets up proper ownership of package directories
#
# Output:
#   Status of user creation and configuration
#
# Returns:
#   0 on success (user created or already exists and configured)
#   1 on failure
#===============================================================================
n_setup_build_user() {
    local build_user="builder"
    local packages_dir="/srv/hps-resources/packages"
    
    echo "Setting up build user for APK package creation..."
    echo ""
    
    # Check if user already exists
    if id "$build_user" >/dev/null 2>&1; then
        echo "Build user '$build_user' already exists"
    else
        echo "Creating build user '$build_user'..."
        if ! adduser -D "$build_user" 2>&1; then
            echo "Error: Failed to create user '$build_user'"
            return 1
        fi
        echo "  User created successfully"
    fi
    
    # Ensure home directory exists with proper permissions
    local builder_home=$(eval echo ~$build_user)
    if [ ! -d "$builder_home" ]; then
        echo "Creating home directory: $builder_home"
        mkdir -p "$builder_home"
        chown "$build_user:$build_user" "$builder_home"
        chmod 700 "$builder_home"
    fi
    
    # Ensure abuild group exists and add user to it
    echo "Configuring abuild group membership..."
    if ! getent group abuild >/dev/null 2>&1; then
        echo "  Creating abuild group..."
        addgroup abuild
    fi
    
    if ! id -nG "$build_user" | grep -qw abuild; then
        echo "  Adding $build_user to abuild group..."
        addgroup "$build_user" abuild
    else
        echo "  User already in abuild group"
    fi
    
    # Generate signing key if it doesn't exist
    echo "Checking for abuild signing key..."
    local builder_home=$(eval echo ~$build_user)
    
    if [ ! -f "$builder_home/.abuild/abuild.conf" ]; then
        echo "  Generating signing key for $build_user..."
        su - "$build_user" -c "abuild-keygen -a -i -n" || {
            echo "Error: Failed to generate signing key"
            return 1
        }
        echo "  Signing key generated successfully"
    else
        echo "  Signing key already exists"
    fi
    
    # Set up package directory ownership
    echo "Configuring package directory permissions..."
    
    # Create base packages directory if it doesn't exist
    if [ ! -d "$packages_dir" ]; then
        echo "  Creating packages directory: $packages_dir"
        mkdir -p "$packages_dir"
    fi
    
    # Give builder ownership of packages directory and subdirectories
    echo "  Setting ownership of $packages_dir to $build_user..."
    chown -R "$build_user:$build_user" "$packages_dir"
    
    # Ensure builder can write to home packages directory
    local builder_packages="$builder_home/packages"
    if [ ! -d "$builder_packages" ]; then
        su - "$build_user" -c "mkdir -p ~/packages"
    fi
    
    echo ""
    echo "Build user setup completed successfully:"
    echo "  User: $build_user"
    echo "  Home: $builder_home"
    echo "  Groups: $(id -nG $build_user)"
    echo "  Packages directory: $packages_dir"
    
    n_remote_log "Configured build user '$build_user' for APK packaging"
    
    return 0
}

# Allow function to be called directly if script is executed
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    n_setup_build_user
fi


