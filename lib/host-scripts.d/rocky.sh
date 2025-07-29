
build_zfs_source() {
  remote_log "Starting build_zfs_source for Rocky"

  local gateway src_base_url index_url src_file index_file src_url src_archive build_dir

  gateway="$(get_provisioning_node)"
  src_base_url="http://${gateway}/packages/src"
  index_url="${src_base_url}/index"
  build_dir="/tmp/zfs-build"

  index_file="$(mktemp)"
  remote_log "Fetching source index from $index_url"
  if ! curl -fsSL "$index_url" -o "$index_file"; then
    remote_log "Failed to download source index"
    rm -f "$index_file"
    return 1
  fi

  src_file="$(awk '$2 == "build_zfs_source" { print $1 }' "$index_file" | head -n1)"
  rm -f "$index_file"

  if [[ -z "$src_file" ]]; then
    remote_log "No matching source file for build_zfs_source in index"
    return 1
  fi

  src_url="${src_base_url}/${src_file}"
  src_archive="/tmp/${src_file}"
  remote_log "Downloading $src_file from $src_url"

  rm -f "$src_archive"
  if ! curl -fsSL "$src_url" -o "$src_archive"; then
    remote_log "curl failed to download $src_file, trying wget..."
    if ! wget -q -O "$src_archive" "$src_url"; then
      remote_log "wget also failed to download $src_file"
      return 1
    fi
  fi

  remote_log "Installing ZFS build dependencies"
  if ! dnf install -y \
      autoconf automake libtool \
      libuuid-devel libblkid-devel libudev-devel libselinux-devel \
      libtirpc-devel libattr-devel elfutils-libelf-devel \
      kernel-devel kernel-headers \
      make gcc dkms python3 python3-setuptools; then
    remote_log "Failed to install ZFS dependencies"
    return 1
  fi

  remote_log "Extracting and building ZFS from $src_archive"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  if ! tar -xf "$src_archive" -C "$build_dir" --strip-components=1; then
    remote_log "Failed to extract archive"
    return 1
  fi

  pushd "$build_dir" >/dev/null || return 1
  if ! ./configure; then
    remote_log "Configure failed"
    return 1
  fi

  if ! make -j"$(nproc)"; then
    remote_log "Build failed"
    return 1
  fi

  if ! make install; then
    remote_log "Install failed"
    return 1
  fi
  popd >/dev/null || true

  if ! modinfo zfs &>/dev/null; then
    remote_log "ZFS module not found after install"
    return 1
  fi

  remote_log "ZFS successfully built and installed"
  return 0
}





