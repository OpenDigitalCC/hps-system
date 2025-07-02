__guard_source || return

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


