__guard_source || return

# Purpose: functions to find any external dependencies and add them to the resources folder

fetch_and_register_source_file() {
  local url="$1"
  local handler="$2"
  local filename="${3:-$(basename "$url")}"

  fetch_source_file "$url" "$filename" && \
  register_source_file "$filename" "$handler"
}

register_source_file() {
  local filename="$1"
  local handler="$2"
  local dest_dir="${HPS_PACKAGES_DIR:-/srv/hps-resources/packages}/src"
  local index_file="${dest_dir}/index"

  mkdir -p "$dest_dir"

  # Avoid duplicate entries
  if grep -Fxq "${filename} ${handler}" "$index_file" 2>/dev/null; then
    echo "[=] Already registered: ${filename} → ${handler}"
    return 0
  fi

  echo "[+] Registering: ${filename} → ${handler}"
  echo "${filename} ${handler}" >> "$index_file"
}


fetch_source_file() {
  local url="$1"
  local filename="${2:-}"
  local dest_dir="${HPS_PACKAGES_DIR:-/srv/hps-resources/packages}/src"

  mkdir -p "$dest_dir"

  # If filename not provided, infer from URL
  if [[ -z "$filename" ]]; then
    filename="$(basename "$url")"
  fi

  local dest_file="${dest_dir}/${filename}"

  if [[ -f "$dest_file" ]]; then
    echo "[=] File already exists: $dest_file"
    return 0
  fi

  echo "[+] Downloading: $url"
  echo "    → $dest_file"

  if curl -fL -o "$dest_file" "$url"; then
    echo "[✓] Downloaded: $dest_file"
    return 0
  else
    echo "[!] Failed to download $url" >&2
    return 1
  fi
}


