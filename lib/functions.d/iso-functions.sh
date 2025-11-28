__guard_source || return


_get_iso_path() {
  echo "$(_get_distro_dir)/iso"
}



list_local_iso() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="${4:-}"  # Optional

  local 

  local iso_dir="$(_get_iso_path)"
  local pattern="${cpu}-${mfr}-${osname}"
  [[ -n "$osver" ]] && pattern="${pattern}-${osver}"

  echo "[*] Searching for local ISOs: ${pattern}.iso in ${iso_dir}"

  shopt -s nullglob
  local files=("${iso_dir}/${pattern}.iso")
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "[!] No matching ISO files found."
    return 1
  fi

  for iso in "${files[@]}"; do
    echo " - $(basename "$iso")"
  done
}



check_latest_version() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"

  case "$osname" in
    rockylinux)
      local base_url="https://download.rockylinux.org/pub/rocky/"
      local html versions

      echo "[*] Checking latest version of $osname from $base_url"

      if ! html=$(curl -fsSL "$base_url"); then
        echo "[x] Failed to fetch $base_url" >&2
        return 1
      fi

      versions=($(echo "$html" | grep -oE '[0-9]+\.[0-9]+/' | sed 's|/||' | sort -Vr))
      if [[ ${#versions[@]} -eq 0 ]]; then
        echo "[x] No versions found for $osname" >&2
        return 1
      fi

      echo "[OK] Latest $osname version: ${versions[0]}"
      return 0
      ;;

    *)
      echo "[x] Unknown OS variant: $osname" >&2
      return 1
      ;;
  esac
}



#===============================================================================
# mount_distro_iso
# ----------------
# Mount distribution ISO using OS registry configuration.
#
# Behaviour:
#   - Handles new colon-delimited OS IDs (arch:name:version)
#   - Looks up ISO filename from os_config
#   - Falls back to constructed filename if not specified
#   - Mounts ISO if not already mounted
#   - Handles various error conditions gracefully
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0") or legacy DISTRO_STRING
#
# Returns:
#   0 on success
#   1 if ISO not found or mount fails
#
# Example usage:
#   mount_distro_iso "x86_64:rocky:10.0"
#   mount_distro_iso "x86_64-linux-rockylinux-10"  # legacy support
#
#===============================================================================
mount_distro_iso() {
  local os_id="$1"
  local iso_filename=""
  local mount_point=""
  
  # Validate input
  if [[ -z "$os_id" ]]; then
    hps_log error "No OS identifier provided"
    return 1
  fi

  if ! os_config "$os_id" exists ; then
    hps_log error "O/S $os_id is not valid or does not exist"
    return 1
  fi
  
  # Get ISO filename from os_config
  iso_filename=$(os_registry "$os_id" get "iso_filename" 2>/dev/null)

  # Mount point uses the OS ID with colons replaced by underscores
  # to avoid filesystem issues
  mount_point="$(get_distro_base_path "$os_id")"
  local iso_path="$(_get_iso_path)/${iso_filename}"
  
  # Check if ISO exists
  if [[ ! -f "$iso_path" ]]; then
    hps_log error "ISO not found: $iso_path"
    return 1
  fi
  
  # Verify ISO file is readable
  if [[ ! -r "$iso_path" ]]; then
    hps_log error "ISO not readable: $iso_path"
    return 1
  fi
  
  # Check if already mounted
  if mountpoint -q "$mount_point" 2>/dev/null; then
    hps_log info "Already mounted: $mount_point"
    return 0
  fi
  
  # Create mount point if it doesn't exist
  if [[ ! -d "$mount_point" ]]; then
    hps_log debug "Creating mount point: $mount_point"
    mkdir -p "$mount_point"
    if [[ ! -d "$mount_point" ]]; then
      hps_log error "Failed to create mount point: $mount_point"
      return 1
    fi
  fi
  
  # Check if mount point is empty (required for mounting)
  if [[ -d "$mount_point" ]] && [[ -n "$(ls -A "$mount_point" 2>/dev/null)" ]]; then
    hps_log warning "Mount point not empty: $mount_point"
    # Check if it's a broken mount
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
      hps_log info "Cleaning non-mounted directory"
      # Create backup just in case
      local backup_dir="${mount_point}.backup.$(date +%s)"
      mv "$mount_point" "$backup_dir"
      mkdir -p "$mount_point"
    fi
  fi
  
  hps_log info "Mounting $iso_path to $mount_point"
  
  # Create loop devices if they don't exist
  if [ ! -b /dev/loop0 ]; then
    hps_log warn "No loop devices available"
    for i in {0..7}; do
      mknod -m 0660 /dev/loop$i b 7 $i 2>/dev/null || true
      chown root:disk /dev/loop$i 2>/dev/null || true
    done
  fi


  # Try mounting with explicit options
  local mount_output
  mount_output=$(mount -t iso9660 -o loop,ro "$iso_path" "$mount_point" 2>&1)
  local mount_result=$?
  
  if [[ $mount_result -ne 0 ]]; then
    # Try without specifying filesystem type
    mount_output=$(mount -o loop,ro "$iso_path" "$mount_point" 2>&1)
    mount_result=$?
  fi
  
  if [[ $mount_result -ne 0 ]]; then
    hps_log error "Mount failed: $mount_output"
    # Clean up empty directory
    rmdir "$mount_point" 2>/dev/null
    return 1
  fi
  
  # Verify mount succeeded
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    hps_log error "Mount verification failed for $mount_point"
    return 1
  fi
  
  # Quick content verification
  local content_check=$(ls "$mount_point" 2>/dev/null | wc -l)
  if [[ $content_check -eq 0 ]]; then
    hps_log error "Mounted but no content visible in $mount_point"
    umount "$mount_point" 2>/dev/null
    return 1
  fi
  
  hps_log info "Successfully mounted $iso_path (contains $content_check items)"
  return 0
}

#===============================================================================
# unmount_distro_iso
# ------------------
# Unmount distribution ISO.
#
# Behaviour:
#   - Handles new colon-delimited OS IDs (arch:name:version)
#   - Unmounts the ISO if currently mounted
#   - Handles busy mount points gracefully
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0") or mount path
#
# Returns:
#   0 on success or if not mounted
#   1 on unmount failure
#
# Example usage:
#   unmount_distro_iso "x86_64:rocky:10.0"
#
#===============================================================================
unmount_distro_iso() {
  local os_id_or_path="$1"
  local mount_point=""
  
  # Determine mount point
  if [[ "$os_id_or_path" =~ ^/ ]]; then
    # Absolute path provided
    mount_point="$os_id_or_path"
  elif os_config "$os_id_or_path" "exists"; then
    # OS identifier provided - convert colons to underscores for filesystem
    mount_point="$(_get_distro_dir)/${os_id_or_path//:/_}"
  else
    # Legacy DISTRO_STRING
    mount_point="$(_get_distro_dir)/${os_id_or_path}"
  fi
  
  # Check if mounted
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    hps_log debug "Not mounted: $mount_point"
    return 0
  fi
  
  hps_log info "Unmounting $mount_point"
  
  # Try normal unmount
  if umount "$mount_point" 2>/dev/null; then
    hps_log info "Successfully unmounted $mount_point"
    rmdir "$mount_point" 2>/dev/null  # Remove if empty
    return 0
  fi
  
  # Try lazy unmount if normal fails
  hps_log warning "Normal unmount failed, trying lazy unmount"
  if umount -l "$mount_point" 2>/dev/null; then
    hps_log info "Lazy unmount successful"
    return 0
  fi
  
  hps_log error "Failed to unmount $mount_point"
  return 1
}

#===============================================================================
# get_mount_point_for_os
# -----------------------
# Get the mount point path for a given OS identifier.
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#
# Returns:
#   Mount point path
#
# Example:
#   mount_point=$(get_mount_point_for_os "x86_64:rocky:10.0")
#
#===============================================================================
get_mount_point_for_os() {
  local os_id="$1"
  # Convert colons to underscores for filesystem compatibility
  echo "$(_get_distro_dir)/${os_id//:/_}"
}



update_distro_iso() {
  local DISTRO_STRING="$1"
  local iso_path="$(_get_distro_dir)/iso/${DISTRO_STRING}.iso"
  local mount_point="$(_get_distro_dir)/${DISTRO_STRING}"

  if [[ -z "$DISTRO_STRING" ]]; then
    echo "Usage: update_distro_iso <CPU>-<MFR>-<OSNAME>-<OSVER>"
    return 1
  fi

  unmount_distro_iso "$DISTRO_STRING" || {
    echo "❌ Failed to unmount $mount_point"
    return 1
  }

  if mountpoint -q "$mount_point"; then
    echo "❌ Still mounted after unmount attempt. Aborting."
    return 1
  fi

  echo
  echo "🛠️  Please update the ISO file now:"
  echo "    → $iso_path"
  echo "Press ENTER when ready to re-mount..."
  read -r

  if [[ ! -f "$iso_path" ]]; then
    echo "❌ ISO file not found: $iso_path"
    return 1
  fi

  if ! mount_distro_iso "$DISTRO_STRING"; then
    echo "❌ Failed to re-mount ISO."
    return 1
  fi

  echo "✅ ISO re-mounted: $mount_point"
}





download_iso() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="$4"
  local iso_dir="$(_get_iso_path)"
  local base_url=""
  local filename=""
  local iso_url=""
  local iso_file=""

  mkdir -p "$iso_dir"

  case "$osname" in
    rockylinux)
      filename="Rocky-${osver}-${cpu}-minimal.iso"
      # https://download.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10.0-x86_64-minimal.iso
      base_url="https://download.rockylinux.org/pub/rocky/${osver}/isos/${cpu}"
      iso_url="${base_url}/${filename}"
      iso_file="${iso_dir}/${cpu}-${mfr}-${osname}-${osver}.iso"
      ;;
    *)
      echo "[x] Unsupported OS variant: $osname" >&2
      return 1
      ;;
  esac

  if [[ -f "$iso_file" ]]; then
    echo "[OK] ISO already exists: $iso_file"
    return 0
  fi

  echo "[*] Downloading ISO from $iso_url to $iso_file"
  if ! curl -fSL "$iso_url" -o "$iso_file"; then
    echo "[x] Failed to download ISO: $iso_url" >&2
    rm -f "$iso_file"
    return 1
  fi

  echo "[OK] ISO saved to $iso_file"
}


extract_iso_for_pxe() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="$4"
  local iso_dir="$(_get_iso_path)"
  local iso_file="${iso_dir}/${cpu}-${mfr}-${osname}-${osver}.iso"
  local extract_dir="$(_get_distro_dir)/${cpu}-${mfr}-${osname}-${osver}"

  if [[ ! -f "$iso_file" ]]; then
    echo "[x] ISO not found: $iso_file" >&2
    return 1
  fi

  if [[ -d "$extract_dir/LiveOS" && -f "$extract_dir/.treeinfo" ]]; then
    echo "[OK] ISO already extracted to: $extract_dir"
    return 0
  fi

  echo "[*] Extracting ISO to: $extract_dir"

  mkdir -p "$extract_dir"
  if ! bsdtar -C "$extract_dir" -xf "$iso_file"; then
    echo "[x] Failed to extract ISO with bsdtar: $iso_file" >&2
    return 1
  fi

  echo "[OK] Extracted to $extract_dir"
}

verify_checksum_signature() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="$4"
  local iso_dir="$(_get_distro_dir)"
  local iso_file="${iso_dir}/${cpu}-${mfr}-${osname}-${osver}.iso"

  if [[ ! -f "$iso_file" ]]; then
    echo "[x] ISO not found: $iso_file" >&2
    return 1
  fi

  case "$osname" in
    rockylinux)
      local base_url="https://download.rockylinux.org/pub/rocky/${osver}/isos/${cpu}"
      local checksums_url="${base_url}/CHECKSUM"
      local sig_url="${base_url}/CHECKSUM.sig"
      local gpg_key_url="https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9"
      local temp_dir
      temp_dir="$(mktemp -d)"
      local checksum_file="${temp_dir}/CHECKSUM"
      local sig_file="${temp_dir}/CHECKSUM.sig"

      echo "[*] Fetching CHECKSUM and .sig..."
      curl -fsSL "$checksums_url" -o "$checksum_file" || {
        echo "[x] Failed to download CHECKSUM file." >&2
        return 1
      }

      curl -fsSL "$sig_url" -o "$sig_file" || {
        echo "[x] Failed to download CHECKSUM.sig file." >&2
        return 1
      }

      echo "[*] Importing Rocky Linux GPG key..."
      curl -fsSL "$gpg_key_url" | gpg --import || {
        echo "[x] Failed to import Rocky Linux GPG key." >&2
        return 1
      }

      echo "[*] Verifying GPG signature on CHECKSUM..."
      gpg --verify "$sig_file" "$checksum_file" || {
        echo "[x] Signature verification failed." >&2
        return 1
      }

      echo "[*] Verifying ISO checksum..."
      local actual_checksum
      actual_checksum=$(sha256sum "$iso_file" | awk '{print $1}')

      if grep -q "$actual_checksum" "$checksum_file"; then
        echo "[OK] ISO checksum verified."
        rm -rf "$temp_dir"
        return 0
      else
        echo "[x] Checksum mismatch!" >&2
        return 1
      fi
      ;;

    *)
      echo "[x] Checksum verification not implemented for OS: $osname" >&2
      return 1
      ;;
  esac
}





# ------------------- below are old functions ---------------


rocky_latest_version() {
  local base_url="https://download.rockylinux.org/pub/rocky/"
  local html versions

  html=$(curl -fsSL "${base_url}") || return 1

  versions=($(echo "$html" | grep -oE '[0-9]+\.[0-9]+/' | sed 's|/||' | sort -Vr))
  [[ ${#versions[@]} -eq 0 ]] && return 1

  echo "${versions[0]}"
}


check_and_download_latest_rocky() {
  local base_url="https://download.rockylinux.org/pub/rocky"
  local arch="x86_64"
  local iso_pattern="minimal"

  local target_base="$(_get_distro_dir)/iso"
  mkdir -p "$target_base"

  echo "[*] Checking for latest Rocky Linux ${arch} ISO..."



  local latest_version
  latest_version="$(rocky_latest_version)"
#  latest_version=$(curl -sL "$base_url/" | grep -oE '[0-9]+\.[0-9]+/' | sort -V | tail -n1 | tr -d '/')
  hps_log debug  "Latest: $latest_version"
#
#  [[ -z "$latest_version" ]] && echo "[x] Could not detect version." >&2 && return 1


  local version_url="${base_url}/${latest_version}/isos/${arch}/"
  local iso_name="Rocky-${latest_version}-${arch}-${iso_pattern}.iso"
  local iso_url="${version_url}${iso_name}"
  local iso_path="${target_base}/${iso_name}"
  local checksum_path="${target_base}/CHECKSUM"
  local sig_path="${checksum_path}.sig"

  # Download ISO if missing
  if [[ ! -f "$iso_path" ]]; then
    echo "[*] Downloading ISO: $iso_url"
    curl --fail --show-error --location -o "$iso_path" "$iso_url"
  else
    echo "[OK] ISO already exists: $iso_path"
  fi

#  verify_rocky_checksum_signature $latest_version
  major_version="${latest_version%%.*}"
  # Extract ISO to PXE directory
  extract_rocky_iso_for_pxe "$iso_path" "$major_version" "$arch"
}


extract_rocky_iso_for_pxe() {
  local iso_path="$1"
  local version="$2"
  local CPU="$3"
  local MFR="linux"
  local OSNAME=rockylinux
  local OSVER="$version"
  local extract_dir="$(_get_distro_dir)/${CPU}-${MFR}-${OSNAME}/${OSVER}"

  echo "[*] Extracting Rocky Linux ISO for PXE to: $extract_dir"
  mkdir -p "$extract_dir"

  # Mount and copy contents using fuseiso or bsdtar
  if command -v bsdtar >/dev/null; then
    bsdtar -C "$extract_dir" -xf "$iso_path"
  elif command -v fuseiso >/dev/null; then
    temp_mount=$(mktemp -d)
    fuseiso "$iso_path" "$temp_mount"
    cp -a "$temp_mount/." "$extract_dir/"
    fusermount -u "$temp_mount"
    rmdir "$temp_mount"
  else
    echo "[x] Neither bsdtar nor fuseiso found. Cannot extract ISO." >&2
    return 1
  fi

  echo "[OK] Rocky Linux PXE tree ready at: $extract_dir"
}

verify_rocky_checksum_signature() {
  local version="$1"
  local arch="x86_64"
  local base_url="https://download.rockylinux.org/pub/rocky/${version}/${arch}/iso/"
  local target_dir="$(_get_distro_dir)/rocky"
  local checksum_path="${target_dir}/CHECKSUM"
  local sig_path="${checksum_path}.sig"

  # Download checksum and signature
  echo "[*] Downloading CHECKSUM and signature..."
#  curl --fail --show-error --location -sL -o "$checksum_path" "${base_url}CHECKSUM"
#  curl --fail --show-error --location -sL -o "$sig_path" "${base_url}CHECKSUM.sig"
#  echo "[*] Fetching CHECKSUM and .sig..."
  curl --fail --show-error --location -sL -o "$checksum_path" "${version_url}CHECKSUM"
  curl --fail --show-error --location -sL -o "$sig_path" "${version_url}CHECKSUM.sig"

  # Import Rocky GPG key
  echo "[*] Importing Rocky Linux GPG key..."
  curl --fail --show-error --location -sL https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9 | gpg --import || {
    echo "[x] Failed to import Rocky Linux GPG key." >&2
    return 1
  }

  # Verify GPG signature
  echo "[*] Verifying CHECKSUM signature..."
  if gpg --verify "$sig_path" "$checksum_path" 2>/dev/null; then
    echo "[OK] GPG signature verified for CHECKSUM"
    return 0
  else
    echo "[x] GPG signature verification failed!" >&2
    return 2
  fi

  # Extract expected checksum
  local expected_checksum
  expected_checksum=$(awk "/$iso_name/ {print \$1}" "$checksum_path" | head -n1)
  [[ -z "$expected_checksum" ]] && {
    echo "[x] Could not find matching checksum for $iso_name." >&2
    return 3
  }

  # Verify file hash
  local actual_checksum
  actual_checksum=$(sha256sum "$iso_path" | awk '{print $1}')
  if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    echo "[x] Checksum mismatch for $iso_name"
    echo "Expected: $expected_checksum"
    echo "Actual:   $actual_checksum"
    return 4
  fi
  echo "[OK] ISO checksum verified."


}


