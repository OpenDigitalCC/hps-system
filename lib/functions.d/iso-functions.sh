__guard_source || return

#TODO: this should be set at cluster-config time, selecting for each host type which is required, then use cluster_config to get the values
# ${CPU}-${MFR}-${OSNAME}-${OSVER}
# x86_64 linux rockylinux 9.3


get_iso_path() {
  if [[ -n "${HPS_DISTROS_DIR:-}" && -d "$HPS_DISTROS_DIR" ]]; then
    echo "$HPS_DISTROS_DIR/iso"
  else
    echo "[x] HPS_DISTROS_DIR is not set or not a directory." >&2
    return 1
  fi
}



list_local_iso() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="${4:-}"  # Optional

  local 

  local iso_dir="$(get_iso_path)"
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


download_iso() {
  local cpu="$1"
  local mfr="$2"
  local osname="$3"
  local osver="$4"
  local iso_dir="$(get_iso_path)"
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
  local iso_dir="$(get_iso_path)"
  local iso_file="${iso_dir}/${cpu}-${mfr}-${osname}-${osver}.iso"
  local extract_dir="${HPS_DISTROS_DIR}/${cpu}-${mfr}-${osname}-${osver}"

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
  local iso_dir="${HPS_DISTROS_DIR:-/srv/hps-resources/distros}"
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

  local target_base="${HPS_DISTROS_DIR}/iso"
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
  local extract_dir="${HPS_DISTROS_DIR}/${CPU}-${MFR}-${OSNAME}/${OSVER}"

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


