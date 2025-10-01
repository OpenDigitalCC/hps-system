__guard_source || return


#===============================================================================
# Alpine Repository Management Functions
#===============================================================================


#===============================================================================
# validate_alpine_repository
# --------------------------
# Check if Alpine repository is complete and ready for TCH boot
#
# Arguments:
#   $1 - alpine_version : Alpine version (optional, auto-detects if not provided)
#   $2 - repo_name      : "main" or "community" (optional, defaults to "main")
#
# Behaviour:
#   - Auto-detects Alpine version from distros directory if not provided
#   - Checks if repository directory exists
#   - Validates APKINDEX.tar.gz exists and is readable
#   - Counts .apk packages in repository
#   - Compares package count against expected minimum
#   - Logs validation results
#
# Returns:
#   0 if repository is valid and complete
#   1 if repository missing or incomplete
#===============================================================================
validate_alpine_repository() {
  local alpine_version="${1:-}"
  local repo_name="${2:-main}"
  
  if [[ -z "$HPS_DISTROS_DIR" ]]; then
    hps_log error "validate_alpine_repository: HPS_DISTROS_DIR not set"
    return 1
  fi
  
  # Auto-detect Alpine version if not provided
  if [[ -z "$alpine_version" ]]; then
    alpine_version=$(get_latest_alpine_version)
    if [[ -z "$alpine_version" ]]; then
      hps_log error "Could not determine Alpine version"
      return 1
    fi
    hps_log debug "Auto-detected Alpine version: ${alpine_version}"
  fi
  
  local repo_dir="${HPS_DISTROS_DIR}/alpine-${alpine_version}/apks/${repo_name}/x86_64"
  
  hps_log debug "Validating Alpine repository: ${repo_dir}"
  
  # Check directory exists
  if [[ ! -d "$repo_dir" ]]; then
    hps_log error "Repository directory does not exist: ${repo_dir}"
    return 1
  fi
  
  # Check APKINDEX exists and is valid
  if ! validate_apkindex "$repo_dir"; then
    hps_log error "Repository APKINDEX validation failed: ${repo_dir}"
    return 1
  fi
  
  # Count packages
  local pkg_count=$(ls -1 "${repo_dir}"/*.apk 2>/dev/null | wc -l)
  
  # Expected minimum package counts
  local min_main=2000
  local min_community=3000
  local expected_min
  
  case "$repo_name" in
    main)
      expected_min=$min_main
      ;;
    community)
      expected_min=$min_community
      ;;
    *)
      expected_min=1
      ;;
  esac
  
  if (( pkg_count < expected_min )); then
    hps_log error "Repository incomplete: found ${pkg_count} packages, expected at least ${expected_min}"
    return 1
  fi
  
  hps_log info "Repository validated: ${repo_name} has ${pkg_count} packages"
  return 0
}


#===============================================================================
# sync_alpine_repository
# ----------------------
# Sync Alpine Linux package repositories from upstream mirror to local storage
#
# Arguments:
#   $1 - alpine_version : Alpine version (e.g., "3.20.2")
#   $2 - sync_mode      : "all" | "main" | "community" | "minimal" | "packages"
#   $3 - package_list   : (optional) Space-separated package names for "packages" mode
#
# Sync Modes:
#   all       - Sync both main and community repositories (parallel)
#   main      - Sync only main repository
#   community - Sync only community repository
#   minimal   - Sync only bootstrap essential packages
#   packages  - Sync specific packages and their dependencies
#
# Behaviour:
#   - Converts version to mirror path format (3.20.2 -> v3.20)
#   - Creates repository directory structure
#   - Uses rsync with fallback to wget
#   - For minimal/packages modes: parses APKINDEX and resolves dependencies
#   - Parallel download for "all" mode
#   - Keeps all downloaded packages (no deletion)
#   - Validates APKINDEX.tar.gz after sync
#
# Returns:
#   0 on success
#   1 on invalid parameters
#   2 on sync failure
#===============================================================================
sync_alpine_repository() {
  local alpine_version="$1"
  local sync_mode="$2"
  local package_list="$3"
  
  # Minimal packages for TCH bootstrap with their repositories
  declare -A MINIMAL_PACKAGES_REPO=(
    [bash]="main"
    [curl]="main"
  )
  
  if [[ -z "$alpine_version" || -z "$sync_mode" ]]; then
    hps_log error "sync_alpine_repository: alpine_version and sync_mode required"
    return 1
  fi
  
  if [[ -z "$HPS_DISTROS_DIR" ]]; then
    hps_log error "sync_alpine_repository: HPS_DISTROS_DIR not set"
    return 1
  fi
  
  # Validate sync_mode
  case "$sync_mode" in
    all|main|community|minimal|packages) ;;
    *)
      hps_log error "sync_alpine_repository: Invalid sync_mode: $sync_mode"
      return 1
      ;;
  esac
  
  # Convert version to mirror format (3.20.2 -> v3.20)
  local major_minor_version
  major_minor_version=$(echo "$alpine_version" | grep -oE '^[0-9]+\.[0-9]+')
  local mirror_version="v${major_minor_version}"
  
  hps_log info "Syncing Alpine ${alpine_version} repository: mode=${sync_mode}"
  
  # Execute based on sync mode
  case "$sync_mode" in
    all)
      sync_alpine_repo_arch "$alpine_version" "$mirror_version" "main" &
      local pid_main=$!
      sync_alpine_repo_arch "$alpine_version" "$mirror_version" "community" &
      local pid_community=$!
      
      wait $pid_main
      local result_main=$?
      wait $pid_community
      local result_community=$?
      
      if [[ $result_main -eq 0 && $result_community -eq 0 ]]; then
        hps_log info "Successfully synced all repositories"
        return 0
      else
        hps_log error "Failed to sync one or more repositories"
        return 2
      fi
      ;;
      
    main|community)
      sync_alpine_repo_arch "$alpine_version" "$mirror_version" "$sync_mode"
      return $?
      ;;
      
    minimal)
      # Sync packages from their respective repositories
      local result=0
      for pkg in "${!MINIMAL_PACKAGES_REPO[@]}"; do
        local repo="${MINIMAL_PACKAGES_REPO[$pkg]}"
        hps_log info "Syncing $pkg from $repo repository"
        if ! sync_alpine_packages "$alpine_version" "$mirror_version" "$repo" "$pkg"; then
          hps_log error "Failed to sync package: $pkg"
          result=2
        fi
      done
      return $result
      ;;
      
    packages)
      if [[ -z "$package_list" ]]; then
        hps_log error "sync_alpine_repository: package_list required for packages mode"
        return 1
      fi
      sync_alpine_packages "$alpine_version" "$mirror_version" "community" $package_list
      return $?
      ;;
  esac
}

#===============================================================================
# sync_alpine_repo_arch
# ---------------------
# Sync a single Alpine repository (main or community) for x86_64 architecture
#
# Arguments:
#   $1 - alpine_version  : Alpine version (e.g., "3.20.2")
#   $2 - mirror_version  : Mirror path version (e.g., "v3.20")
#   $3 - repo_name       : "main" or "community"
#
# Behaviour:
#   - Creates destination directory structure
#   - Uses rsync from Alpine mirror with appropriate filters
#   - Falls back to wget if rsync unavailable or fails
#   - Syncs only x86_64 architecture
#   - Includes APKINDEX.tar.gz and all .apk files
#   - Validates APKINDEX exists after sync
#
# Returns:
#   0 on success
#   2 on failure
#===============================================================================
sync_alpine_repo_arch() {
  local alpine_version="$1"
  local mirror_version="$2"
  local repo_name="$3"
  
  local dest_dir="${HPS_DISTROS_DIR}/alpine-${alpine_version}/apks/${repo_name}/x86_64"
  local http_mirror="http://dl-cdn.alpinelinux.org/alpine/${mirror_version}/${repo_name}/x86_64/"
  
  hps_log info "Syncing ${repo_name} repository to ${dest_dir}"
  
  # Create destination directory
  if ! mkdir -p "$dest_dir"; then
    hps_log error "Failed to create directory: $dest_dir"
    return 2
  fi
  
  # Create temporary file list
  local temp_list=$(mktemp)
  
  # Download with wget, capturing downloaded files
  hps_log debug "Downloading repository files from ${http_mirror}"
  
  # First, get the directory listing
  local temp_list=$(mktemp)
  local file_list=$(mktemp)
  
  # Get list of files from the mirror
  wget -q -O - "${http_mirror}" | \
    grep -o 'href="[^"]*\.apk"' | \
    cut -d'"' -f2 > "$file_list"
  
  # Also download APKINDEX.tar.gz
  echo "APKINDEX.tar.gz" >> "$file_list"
  
  local download_count=0
  local total_files=$(wc -l < "$file_list")
  
  hps_log info "Found ${total_files} files in repository"
  
  # Download each file with timestamping
  while IFS= read -r filename; do
    if wget -N -nv -P "$dest_dir" "${http_mirror}${filename}" 2>&1 | grep -q "saved"; then
      download_count=$((download_count + 1))
      echo "$filename" >> "$temp_list"
      
      # Log every 20 downloads
      if (( download_count % 20 == 0 )); then
        hps_log info "Downloaded ${download_count}/${total_files} files..."
      fi
    fi
  done < "$file_list"
  
  rm -f "$file_list"
  local total_downloaded=$(wc -l < "$temp_list" 2>/dev/null || echo 0)
  rm -f "$temp_list"
  
  hps_log info "Successfully synced ${repo_name} repository (${total_downloaded} new/updated, ${total_files} total)"
  validate_apkindex "$dest_dir"
  return $?
}

#===============================================================================
# sync_alpine_packages
# --------------------
# Sync specific Alpine packages and their dependencies
#
# Arguments:
#   $1 - alpine_version  : Alpine version (e.g., "3.20.2")
#   $2 - mirror_version  : Mirror path version (e.g., "v3.20")
#   $3 - repo_name       : "main" or "community"
#   $@ - package_names   : Space-separated package names
#
# Behaviour:
#   - Downloads APKINDEX.tar.gz from repository
#   - Parses APKINDEX to find requested packages
#   - Resolves all dependencies recursively
#   - Downloads only required .apk files
#   - Creates destination directory structure
#
# Returns:
#   0 on success
#   2 on failure
#===============================================================================
sync_alpine_packages() {
  local alpine_version="$1"
  local mirror_version="$2"
  local repo_name="$3"
  shift 3
  local package_names=("$@")
  
  local dest_dir="${HPS_DISTROS_DIR}/alpine-${alpine_version}/apks/${repo_name}/x86_64"
  local temp_dir=$(mktemp -d)
  
  hps_log info "Syncing packages: ${package_names[*]}"
  
  # Create destination directory
  if ! mkdir -p "$dest_dir"; then
    hps_log error "Failed to create directory: $dest_dir"
    rm -rf "$temp_dir"
    return 2
  fi
  
  # Download APKINDEX
  local index_url="http://dl-cdn.alpinelinux.org/alpine/${mirror_version}/${repo_name}/x86_64/APKINDEX.tar.gz"
  
  if ! wget -q -O "${temp_dir}/APKINDEX.tar.gz" "$index_url"; then
    hps_log error "Failed to download APKINDEX from ${index_url}"
    rm -rf "$temp_dir"
    return 2
  fi
  
  # Extract APKINDEX
  if ! tar -xzf "${temp_dir}/APKINDEX.tar.gz" -C "$temp_dir"; then
    hps_log error "Failed to extract APKINDEX"
    rm -rf "$temp_dir"
    return 2
  fi
  
  # Parse and resolve dependencies
  local all_packages=()
  for pkg in "${package_names[@]}"; do
    local deps
    deps=$(resolve_alpine_dependencies "${temp_dir}/APKINDEX" "$pkg")
    if [[ $? -ne 0 ]]; then
      hps_log error "Failed to resolve dependencies for: $pkg"
      rm -rf "$temp_dir"
      return 2
    fi
    all_packages+=($deps)
  done
  
  # Remove duplicates
  local unique_packages=($(printf '%s\n' "${all_packages[@]}" | sort -u))
  
  hps_log info "Total packages to download (including dependencies): ${#unique_packages[@]}"
  
  # Download each package
  local mirror_base="http://dl-cdn.alpinelinux.org/alpine/${mirror_version}/${repo_name}/x86_64"
  for pkg_file in "${unique_packages[@]}"; do
    hps_log debug "Downloading: $pkg_file"
    if ! wget -q -P "$dest_dir" "${mirror_base}/${pkg_file}"; then
      hps_log warn "Failed to download: $pkg_file"
    fi
  done
  
  # Copy APKINDEX to destination
  cp "${temp_dir}/APKINDEX.tar.gz" "$dest_dir/"
  
  rm -rf "$temp_dir"
  
  hps_log info "Successfully synced packages and dependencies"
  return 0
}

#===============================================================================
# resolve_alpine_dependencies
# ---------------------------
# Recursively resolve package dependencies from APKINDEX
#
# Arguments:
#   $1 - apkindex_file : Path to extracted APKINDEX file
#   $2 - package_name  : Package name to resolve
#
# Behaviour:
#   - Parses APKINDEX file format (newline-separated key:value stanzas)
#   - Finds package entry by name
#   - Extracts dependencies (D: field)
#   - Recursively resolves all dependency packages
#   - Returns list of .apk filenames to download
#
# Output:
#   Space-separated list of .apk filenames (stdout)
#
# Returns:
#   0 on success
#   1 if package not found
#===============================================================================
resolve_alpine_dependencies() {
  local apkindex_file="$1"
  local package_name="$2"
  
  if [[ ! -f "$apkindex_file" ]]; then
    hps_log error "APKINDEX file not found: $apkindex_file"
    return 1
  fi
  
  # Parse package info
  local pkg_info
  pkg_info=$(parse_apkindex_package "$apkindex_file" "$package_name")
  
  if [[ -z "$pkg_info" ]]; then
    hps_log error "Package not found in APKINDEX: $package_name"
    return 1
  fi
  
  # Extract filename and dependencies from APKINDEX format
  # Format: "P:pkgname V:version A:arch ... D:deps ... p:provides"
  
  local pkg_name ver
  
  # Extract P: field value
  pkg_name=$(echo "$pkg_info" | grep -o 'P:[^ ]*' | cut -d: -f2)
  
  # Extract V: field value
  ver=$(echo "$pkg_info" | grep -o 'V:[^ ]*' | cut -d: -f2)
  
  if [[ -z "$pkg_name" || -z "$ver" ]]; then
    hps_log error "Failed to extract package name or version from APKINDEX entry"
    return 1
  fi
  
  local filename="${pkg_name}-${ver}.apk"
  
  # Extract dependencies between D: and p: (or end of line)
  local deps=""
  if echo "$pkg_info" | grep -q ' D:'; then
    deps=$(echo "$pkg_info" | sed -n 's/.* D:\(.*\) p:.*/\1/p' | tr ' ' '\n')
  fi
  
  echo "$filename"
  
  # Recursively resolve dependencies (only actual packages, skip so: and / entries)
  if [[ -n "$deps" ]]; then
    for dep in $deps; do
      # Skip shared library dependencies (so:...) and file dependencies (/...)
      if [[ "$dep" =~ ^so: ]] || [[ "$dep" =~ ^/ ]]; then
        continue
      fi
      
      # Strip version constraints (bash>=5.0 -> bash)
      local dep_name=$(echo "$dep" | sed 's/[<>=].*$//')
      
      # Only recurse if it's an actual package name
      if [[ -n "$dep_name" ]]; then
        resolve_alpine_dependencies "$apkindex_file" "$dep_name" 2>/dev/null || true
      fi
    done
  fi
}

#===============================================================================
# parse_apkindex_package
# ----------------------
# Extract package stanza from APKINDEX file
#
# Arguments:
#   $1 - apkindex_file : Path to extracted APKINDEX file
#   $2 - package_name  : Package name to find
#
# Behaviour:
#   - APKINDEX format: package stanzas separated by blank lines
#   - Each stanza contains key:value pairs
#   - P: field contains package name
#   - Returns complete stanza for matching package as space-separated string
#
# Output:
#   Package stanza (stdout)
#
# Returns:
#   0 on success (package found)
#   1 if package not found
#===============================================================================
parse_apkindex_package() {
  local apkindex_file="$1"
  local package_name="$2"
  
  # Read APKINDEX paragraph by paragraph (blank line separated)
  local in_record=0
  local record=""
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      # Blank line - end of record
      if [[ $in_record -eq 1 ]]; then
        echo "$record"
        return 0
      fi
      record=""
      in_record=0
    else
      # Check if this record contains our package
      if [[ "$line" =~ ^P:${package_name}$ ]]; then
        in_record=1
      fi
      if [[ $in_record -eq 1 ]]; then
        record="${record}${line} "
      fi
    fi
  done < "$apkindex_file"
  
  # Check last record if file doesn't end with blank line
  if [[ $in_record -eq 1 ]]; then
    echo "$record"
    return 0
  fi
  
  return 1
}

#===============================================================================
# validate_apkindex
# -----------------
# Validate APKINDEX.tar.gz exists in repository directory
#
# Arguments:
#   $1 - repo_dir : Repository directory path
#
# Behaviour:
#   - Checks for APKINDEX.tar.gz file
#   - Validates it can be extracted
#   - Logs validation results
#
# Returns:
#   0 if valid
#   2 if invalid or missing
#===============================================================================
validate_apkindex() {
  local repo_dir="$1"
  local index_file="${repo_dir}/APKINDEX.tar.gz"
  
  if [[ ! -f "$index_file" ]]; then
    hps_log error "APKINDEX.tar.gz not found in: $repo_dir"
    return 2
  fi
  
  if ! tar -tzf "$index_file" >/dev/null 2>&1; then
    hps_log error "APKINDEX.tar.gz is corrupted: $index_file"
    return 2
  fi
  
  hps_log debug "APKINDEX validated: $index_file"
  return 0
}










## Rocky / RPM

# prepare_custom_repo_for_distro "x86_64-linux-rockylinux-10.0" "https://zfsonlinux.org/epel/zfs-release.el8.noarch.rpm" "/tmp/opensvc-2.2.3.rpm"

prepare_custom_repo_for_distro() {
  local dist_string="$1"
  shift
  local repo_dir="${HPS_PACKAGES_DIR}/${dist_string}/Repo"
  local -a sources=()
  local -a required_packages=()

  # Separate file sources and required package names
  for item in "$@"; do
    if [[ "$item" =~ ^https?:// || -f "$item" ]]; then
      sources+=("$item")
    else
      required_packages+=("$item")
    fi
  done

  mkdir -p "$repo_dir" || {
    hps_log error "Failed to create repo directory: $repo_dir"
    return 1
  }

  for src in "${sources[@]}"; do
    if [[ "$src" =~ ^https?:// ]]; then
      get_external_package_to_repo "$src" "$repo_dir" || {
        hps_log error "Failed to download $src"
        return 2
      }
    elif [[ -f "$src" ]]; then
      local filename
      filename="$(basename "$src")"
      hps_log info "Copying local file $filename to $repo_dir"
      cp -u "$src" "$repo_dir/" || {
        hps_log error "Failed to copy $src"
        return 3
      }
    else
      hps_log error "Invalid package source: $src"
      return 4
    fi
  done

  build_yum_repo "$repo_dir" || {
    hps_log error "Failed to create yum repo metadata"
    return 5
  }

  verify_required_repo_packages "$repo_dir" "${required_packages[@]}" || {
    hps_log error "Missing required packages in repo"
    return 6
  }

  hps_log info "Custom repo for $dist_string prepared successfully"
  return 0
}




build_yum_repo() {
# usage: build_yum_repo "${HPS_PACKAGES_DIR}/${DIST_STRING}/Repo"
  local repo_path="$1"
  local checksum_file="${repo_path}/.rpm-checksums"

  if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
    hps_log error "Repo path not provided or does not exist: $repo_path"
    return 1
  fi
  
  if ! command -v createrepo_c &>/dev/null; then
    hps_log error "createrepo_c not found. Please install 'createrepo_c' inside the container."
    return 2
  fi

  hps_log info "Checking RPM changes in $repo_path..."

  # Generate new checksums
  local new_checksums
  new_checksums=$(find "$repo_path" -maxdepth 1 -type f -name '*.rpm' -exec sha256sum {} + | sort)

  if [[ -f "$checksum_file" ]] && diff -q <(echo "$new_checksums") "$checksum_file" >/dev/null; then
    hps_log info "No changes in RPMs. Skipping createrepo_c."
    return 0
  fi

  hps_log info "Changes detected or no previous state. Running createrepo_c..."
  createrepo_c --update "$repo_path"

  # Save current state
  echo "$new_checksums" > "$checksum_file"
  hps_log info "Yum repo built successfully in $repo_path"
}


verify_required_repo_packages() {
# usage: verify_required_repo_packages "${HPS_PACKAGES_DIR}/${DIST_STRING}/Repo" zfs opensvc
  local repo_path="$1"
  shift
  local required_packages=("$@")

  if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
    hps_log error "Repo path not provided or does not exist: $repo_path"
    return 1
  fi

  local missing=()
  for pkg in "${required_packages[@]}"; do
    if ! find "$repo_path" -maxdepth 1 -type f -name "${pkg}-*.rpm" | grep -q .; then
      missing+=("$pkg")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    hps_log error "Missing required packages: ${missing[*]}"
    return 2
  fi

  hps_log info "All required packages are present in $repo_path"
  return 0
}

get_external_package_to_repo() {
  local url="$1"
  local repo_path="$2"

  if [[ -z "$url" || -z "$repo_path" ]]; then
    hps_log error "Usage: get_external_package_to_repo <url> <repo_path>"
    return 1
  fi

  if [[ ! -d "$repo_path" ]]; then
    hps_log error "Target repo directory does not exist: $repo_path"
    return 2
  fi

  local filename
  filename="$(basename "$url")"

  if [[ ! "$filename" =~ \.rpm$ ]]; then
    hps_log error "URL does not point to an RPM file: $filename"
    return 3
  fi

  hps_log info "Downloading $filename to $repo_path"
  curl -fL "$url" -o "${repo_path}/${filename}" || {
    hps_log error "Failed to download $url"
    return 4
  }

  hps_log info "Downloaded: $filename"
  return 0
}


