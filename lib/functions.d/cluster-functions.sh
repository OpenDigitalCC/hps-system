__guard_source || return


#===============================================================================
# get_active_cluster_name
# -----------------------
# Convenience: returns the basename of the active cluster directory.
#
# Returns:
#   Cluster name via stdout, or non-zero on error.
#===============================================================================
get_active_cluster_name() {
  local dir
  dir="$(get_active_cluster_dir)" || return 1
  basename -- "$dir"
}

#===============================================================================
# get_active_cluster_link
# -----------------------
# Return the path to the "active-cluster" symlink under the cluster config base.
# Verifies that the symlink exists. This avoids hardcoding the path elsewhere.
#
# Returns:
#   Symlink path via stdout, or non-zero with error to stderr if not found.
#===============================================================================
get_active_cluster_link() {
  local link="$(get_active_cluster_link_path)"

  if [[ ! -L "$link" ]]; then
    echo "[ERROR] No active cluster symlink at: $link" >&2
    return 1
  fi

  echo "$link"
}


#===============================================================================
# get_cluster_dir
# ----------------
# Return the absolute path to a cluster directory given its name.
#
# Arguments:
#   $1 - Cluster name
#
# Returns:
#   Path via stdout, or non-zero if the name is empty.
#===============================================================================
get_cluster_dir() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[ERROR] Usage: get_cluster_dir <cluster-name>" >&2
    return 1
  }
  echo "${HPS_CLUSTER_CONFIG_BASE_DIR}/${cluster_name}"
}



#===============================================================================
# get_active_cluster_dir
# ----------------------
# Resolve the absolute path to the *active* cluster directory, via the symlink
# returned by get_active_cluster_link.
#
# Reuses:
#   - get_active_cluster_link
#   - get_cluster_dir
#
# Returns:
#   Path via stdout, or non-zero with error message on stderr.
#===============================================================================
get_active_cluster_dir() {
  local link
  link="$(get_active_cluster_link)" || return 1

  local target
  if ! target="$(readlink -f -- "$link")"; then
    echo "[ERROR] Failed to resolve active cluster symlink: $link" >&2
    return 1
  fi

  # Derive the name (last path component) and recompose with get_cluster_dir
  local name
  name="$(basename -- "$target")"
  local dir
  dir="$(get_cluster_dir "$name")" || return 1

  if [[ ! -d "$dir" ]]; then
    echo "[ERROR] Active cluster target is not a directory: $dir" >&2
    return 1
  fi

  echo "$dir"
}

#===============================================================================
# get_active_cluster_link_path
# ----------------------------
# Return the absolute path to where the active-cluster symlink should live.
# (No validation is done here.)
#
# Returns:
#   Path via stdout.
#===============================================================================
get_active_cluster_link_path() {
  echo "${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
}


#===============================================================================
# get_cluster_conf_file
# ---------------------
# Return the absolute path to the cluster.conf file for a given cluster.
#
# Arguments:
#   $1 - Cluster name
#
# Reuses:
#   - get_cluster_dir
#
# Returns:
#   Path via stdout, or non-zero on error.
#===============================================================================
get_cluster_conf_file() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[ERROR] Usage: get_cluster_conf_file <cluster-name>" >&2
    return 1
  }

  local cluster_dir
  cluster_dir="$(get_cluster_dir "$cluster_name")" || return 1
  echo "${cluster_dir}/cluster.conf"
}


#===============================================================================
# get_active_cluster_filename
# ---------------------------
# Return the absolute path to the active cluster.conf file.
#
# Dependencies:
#   - get_active_cluster_dir
#   - get_cluster_conf_file
#
# Returns:
#   Path via stdout, or non-zero with error to stderr.
#===============================================================================
get_active_cluster_filename() {
  local cluster_dir
  cluster_dir="$(get_active_cluster_dir)" || return 1

  local cluster_name
  cluster_name="$(basename -- "$cluster_dir")"

  local file
  file="$(get_cluster_conf_file "$cluster_name")" || return 1

  if [[ ! -f "$file" ]]; then
    echo "[ERROR] Active cluster missing cluster.conf: $file" >&2
    return 1
  fi

  echo "$file"
}


#===============================================================================
# get_active_cluster_file
# -----------------------
# Output the contents of the active cluster.conf file to stdout.
#
# Dependencies:
#   - get_active_cluster_filename
#
# Returns:
#   File content via stdout, or non-zero with error to stderr.
#===============================================================================
get_active_cluster_file() {
  local file
  file="$(get_active_cluster_filename)" || return 1
  cat -- "$file"
}

#===============================================================================
# get_active_cluster_info
# -----------------------
# Print human-readable information about the current cluster context.
#
# Behaviour:
#   - If an active cluster is set, print its name, dir, and selected metadata.
#   - Else, if exactly one real cluster exists, print it as "(Only; not Active)".
#   - Else, print that no active cluster is set and list available clusters.
#
# Metadata fields (queried via helper, not by reading files):
#   DESCRIPTION, NETWORK_CIDR, DNS_DOMAIN
#
# Reuses:
#   - _collect_cluster_dirs
#   - get_active_cluster_dir
#   - get_active_cluster_name
#   - cluster_config get <KEY>        # must resolve against active cluster
#
# Returns:
#   0 on success, non-zero if no clusters exist or other error.
#===============================================================================
get_active_cluster_info() {
  local dirs=()
  _collect_cluster_dirs dirs

  if (( ${#dirs[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 1
  fi

  # Helper: print a key via cluster_config get (skip silently if empty)
  _print_meta() {
    local key="$1" label="$2" val=""
    if val="$(cluster_config get "$key" 2>/dev/null)"; then
      [[ -n "$val" ]] && echo "${label}: ${val}"
    fi
  }

  # Case 1: Active cluster exists
  local active_dir active_name
  if active_dir="$(get_active_cluster_dir 2>/dev/null)"; then
    active_name="$(basename -- "$active_dir")"
    echo "Cluster: ${active_name} (Active)"
    echo "Directory: ${active_dir}"
    _print_meta "DESCRIPTION"   "Description"
    _print_meta "NETWORK_CIDR"  "Network CIDR"
    _print_meta "DNS_DOMAIN"    "DNS Domain"
    return 0
  fi

  # Case 2: No active; if exactly one cluster, show it (metadata unavailable
  # without temporarily switching active; we only show name/dir here).
  if (( ${#dirs[@]} == 1 )); then
    local only_dir="${dirs[0]}"
    local only_name
    only_name="$(basename -- "$only_dir")"
    echo "Cluster: ${only_name} (Only; not Active)"
    echo "Config directory: ${only_dir}"
    echo "Description: (unknown; no active cluster)"
    echo "Network CIDR: (unknown; no active cluster)"
    echo "DNS Domain: (unknown; no active cluster)"
    return 0
  fi

  # Case 3: Multiple clusters, none active
  echo "[!] No active cluster set."
  echo "Available clusters:"
  local d n
  for d in "${dirs[@]}"; do
    n="$(basename -- "$d")"
    echo "  - ${n}  (${d})"
  done
  return 0
}





#===============================================================================
# _collect_cluster_dirs
# ---------------------
# Populate a nameref array with absolute paths of *real* cluster directories
# under ${HPS_CLUSTER_CONFIG_BASE_DIR}, excluding symlinks (e.g. active-cluster).
#
# Args:
#   $1  - nameref to an array variable to receive results
#
# Returns:
#   0 on success (array may be empty), non-zero on unexpected errors
#===============================================================================
_collect_cluster_dirs() {
  local -n __out="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"

  __out=()
  if [[ ! -d "$base_dir" ]]; then
    echo "[!] Cluster config base directory not found: $base_dir" >&2
    return 0
  fi

  local entry
  shopt -s nullglob
  for entry in "$base_dir"/*; do
    # NOTE: no trailing slash so we don't dereference symlinks
    if [[ -d "$entry" && ! -L "$entry" ]]; then
      __out+=("$entry")
    fi
  done
  shopt -u nullglob
}


#===============================================================================
# count_clusters
# --------------
# Count the number of *real* cluster directories (excluding symlinks).
#
# Returns:
#   Integer count via stdout. Emits warnings to stderr when base dir is missing
#   or when none are found.
#===============================================================================
count_clusters() {
  local clusters=()
  _collect_cluster_dirs clusters

  if (( ${#clusters[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    echo 0
    return 0
  fi

  echo "${#clusters[@]}"
}

#===============================================================================
# list_clusters
# -------------
# List all *real* cluster directories (no symlinks) under
# ${HPS_CLUSTER_CONFIG_BASE_DIR}. Appends " (Active)" to the active one.
#
# Dependencies:
#   - _collect_cluster_dirs (gathers non-symlink dirs)
#   - get_active_cluster_name (resolves active via symlink)
#
# Usage:
#   list_clusters
#===============================================================================
list_clusters() {
  local clusters=()
  _collect_cluster_dirs clusters

  # Determine active cluster name once; ignore errors if not set
  local active_name=""
  active_name="$(get_active_cluster_name 2>/dev/null)" || true

  if (( ${#clusters[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 0
  fi

  local c name
  for c in "${clusters[@]}"; do
    name="$(basename -- "$c")"
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      echo "${name} (Active)"
    else
      echo "${name}"
    fi
  done
}


#===============================================================================
# set_active_cluster
# ------------------
# Set the active cluster by updating the active-cluster symlink.
#
# Arguments:
#   $1  - Cluster name (must correspond to a real cluster dir with cluster.conf)
#
# Reuses:
#   - get_cluster_dir
#   - get_cluster_conf_file
#   - get_active_cluster_link_path
#
# Returns:
#   0 on success, non-zero on error.
#===============================================================================
set_active_cluster() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[x] Usage: set_active_cluster <cluster-name>" >&2
    return 1
  }

  local cluster_dir conf_file
  cluster_dir="$(get_cluster_dir "$cluster_name")" || return 1
  conf_file="$(get_cluster_conf_file "$cluster_name")" || return 1

  # Ensure directory exists
  if [[ ! -d "$cluster_dir" ]]; then
    echo "[x] Cluster directory not found: $cluster_dir" >&2
    return 1
  fi

  # Ensure cluster.conf exists
  if [[ ! -f "$conf_file" ]]; then
    echo "[x] cluster.conf not found: $conf_file" >&2
    return 2
  fi

  # Ensure symlink is updated
  local link
  link="$(get_active_cluster_link_path)"
  ln -sfn "$cluster_dir" "$link"

  echo "[OK] Active cluster set to: $cluster_name"
}






write_cluster_config() {
  local target_file="$1"
  shift
  local values=("$@")

  if [[ ${#values[@]} -eq 0 ]]; then
    echo "[x] Cannot write empty cluster config to $target_file" >&2
    return 1
  fi

  echo "Writing: ${values[*]}"
  printf "%s\n" "${values[@]}" > "$target_file"
  echo "[OK] Cluster configuration written to $target_file"
}



cluster_config() {
  local op="$1"
  local key="$2"
  local value="${3:-}"

  local cluster_file
  cluster_file=$(get_active_cluster_filename) || {
    echo "[x] No active cluster config found." >&2
    return 1
  }

  case "$op" in
    get)
      grep -E "^${key}=" "$cluster_file" | cut -d= -f2-
      ;;

    set)
      if grep -qE "^${key}=" "$cluster_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$cluster_file"
      else
        echo "${key}=${value}" >> "$cluster_file"
      fi
      ;;

    exists)
      grep -qE "^${key}=" "$cluster_file"
      ;;

    *)
      echo "[x] Unknown cluster_config operation: $op" >&2
      return 2
      ;;
  esac
}

initialise_cluster() {
  local cluster_name="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"
  local cluster_dir="${base_dir}/${cluster_name}"
  local cluster_file="${cluster_dir}/cluster.conf"

  if [[ -z "$cluster_name" ]]; then
    echo "[x] Cluster name must be provided." >&2
    return 1
  fi

  if [[ -d "$cluster_dir" ]]; then
    echo "[!] Cluster directory already exists: $cluster_dir" >&2
    return 2
  fi

  mkdir -p "${cluster_dir}/hosts"
  mkdir -p "${cluster_dir}/services"

  cat > "$cluster_file" <<EOF
# Cluster configuration
CLUSTER_NAME=${cluster_name}
EOF

  echo "[OK] Cluster initialised at: $cluster_dir"
  echo "[OK] Created config: $cluster_file"

  export_dynamic_paths "$cluster_name" || {
    echo "[x] Failed to export cluster paths for $cluster_name" >&2
    return 3
  }
}

print_cluster_variables() {
  local config_file="$(get_active_cluster_filename)"
  local k v

  if [[ ! -f "$config_file" ]]; then
    echo "[x] Cluster config not found: $config_file" >&2
    return 1
  fi

  while IFS='=' read -r k v; do
    # Skip blank lines and comments
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    v="${v%\"}"; v="${v#\"}"  # strip surrounding quotes
    echo "$k=$v"
  done < "$config_file"
}

get_host_type_param() {
  local type="$1"
  local key="$2"
  declare -n ref="$type"

  echo "${ref[$key]}"
}


cluster_has_installed_sch() {
  local config_dir="${HPS_HOST_CONFIG_DIR}"
  local config_file
  local type state

  for config_file in "$config_dir"/*.conf; do
    [[ -f "$config_file" ]] || continue

    type=""
    state=""

    while IFS='=' read -r key val; do
      key="${key//[$'\r\n']}"
      val="${val%\"}"; val="${val#\"}"
      case "$key" in
        TYPE) type="$val" ;;
        STATE) state="$val" ;;
      esac
    done < "$config_file"

    if [[ "$type" == "SCH" && "$state" == "INSTALLED" ]]; then
      return 0
    fi
  done

  return 1
}

## Interactive functions



#===============================================================================
# select_cluster
# --------------
# Interactive selector for cluster directories using Bash `select`.
# Reuses:
#   - _collect_cluster_dirs
#   - get_active_cluster_name
#
# Behaviour:
#   - Lists cluster names; appends " (Active)" to the current one.
#   - Echoes the selected cluster directory to stdout (default),
#     or just the name with --return=name.
#   - Non-interactive (no TTY): auto-selects active if available, else first.
#===============================================================================
select_cluster() {
  local return_mode="dir"  # "dir" or "name"
  if [[ "$1" == "--return=name" ]]; then
    return_mode="name"
    shift
  fi

  local dirs=()
  _collect_cluster_dirs dirs

  if (( ${#dirs[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 1
  fi

  local active_name=""
  active_name="$(get_active_cluster_name 2>/dev/null)" || true

  # Build parallel arrays: names[] (raw), display[] (with Active mark)
  local names=() display=() d name
  for d in "${dirs[@]}"; do
    name="$(basename -- "$d")"
    names+=("$name")
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      display+=("${name} (Active)")
    else
      display+=("$name")
    fi
  done

  # Non-interactive: prefer active; else first
  if [[ ! -t 0 ]]; then
    local pick_idx=0
    if [[ -n "$active_name" ]]; then
      local i
      for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == "$active_name" ]]; then
          pick_idx="$i"
          break
        fi
      done
    fi
    if [[ "$return_mode" == "name" ]]; then
      echo "${names[$pick_idx]}"
    else
      echo "${dirs[$pick_idx]}"
    fi
    return 0
  fi

  # Interactive select: use a separate variable for the chosen item
  local PS3="[?] Select a cluster: "
  local choice
  select choice in "${display[@]}"; do
    # $REPLY is the raw user input (number); validate it
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#display[@]} )); then
      local idx=$((REPLY - 1))
      if [[ "$return_mode" == "name" ]]; then
        echo "${names[$idx]}"
      else
        echo "${dirs[$idx]}"
      fi
      return 0
    else
      echo "[!] Invalid selection. Enter a number 1..${#display[@]}." >&2
    fi
  done
}






