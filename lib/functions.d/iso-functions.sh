__guard_source || return


check_and_download_latest_rocky() {
  local base_url="https://download.rockylinux.org/pub/rocky"
  local arch="x86_64"
  local iso_pattern="minimal"

  local target_base="${HPS_DISTROS_DIR}/rocky"
  mkdir -p "$target_base"

  echo "[*] Checking for latest Rocky Linux ${arch} ISO..."

  local latest_version
  latest_version=$(curl -sL "$base_url/" | grep -oE '[0-9]+\.[0-9]+/' | sort -V | tail -n1 | tr -d '/')
  [[ -z "$latest_version" ]] && echo "[✗] Could not detect version." >&2 && return 1

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
    echo "[✓] ISO already exists: $iso_path"
  fi

#  verify_rocky_checksum_signature $latest_version

  # Extract ISO to PXE directory
  extract_rocky_iso_for_pxe "$iso_path" "$latest_version"
}



extract_rocky_iso_for_pxe() {
  local iso_path="$1"
  local version="$2"
  local extract_dir="${HPS_DISTROS_DIR}/rocky/${version}"

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
    echo "[✗] Neither bsdtar nor fuseiso found. Cannot extract ISO." >&2
    return 1
  fi

  echo "[✓] Rocky Linux PXE tree ready at: $extract_dir"
}

verify_rocky_checksum_signature() {
  local version="$1"
  local arch="x86_64"
  local base_url="https://download.rockylinux.org/pub/rocky/${version}/${arch}/iso/"
  local target_dir="${HPS_DISTROS_DIR}/rocky"
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
    echo "[✗] Failed to import Rocky Linux GPG key." >&2
    return 1
  }

  # Verify GPG signature
  echo "[*] Verifying CHECKSUM signature..."
  if gpg --verify "$sig_path" "$checksum_path" 2>/dev/null; then
    echo "[✓] GPG signature verified for CHECKSUM"
    return 0
  else
    echo "[✗] GPG signature verification failed!" >&2
    return 2
  fi

  # Extract expected checksum
  local expected_checksum
  expected_checksum=$(awk "/$iso_name/ {print \$1}" "$checksum_path" | head -n1)
  [[ -z "$expected_checksum" ]] && {
    echo "[✗] Could not find matching checksum for $iso_name." >&2
    return 3
  }

  # Verify file hash
  local actual_checksum
  actual_checksum=$(sha256sum "$iso_path" | awk '{print $1}')
  if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    echo "[✗] Checksum mismatch for $iso_name"
    echo "Expected: $expected_checksum"
    echo "Actual:   $actual_checksum"
    return 4
  fi
  echo "[✓] ISO checksum verified."


}


