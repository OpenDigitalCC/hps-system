# shellcheck shell=bash
#===============================================================================
# NixOS netboot, driven by build manifests.
#
# The builder (nix/build.sh) writes, under ${resources}/nixos:
#   <pin>/<profile>/{bzImage,initrd,boot.json}      and   latest  (the pin)
# boot.json carries the kernel command line and init path; nothing about a
# NixOS boot is hard-coded here. nginx serves the tree at /nixos/.
#===============================================================================

# nixos_resolve_pin [mac]
# Pin to boot: the host's system_pin, else the cluster's nixos_default_pin,
# else the builder's "latest" file. Prints the pin; returns 1 if none.
nixos_resolve_pin() {
  local mac="${1:-}"
  local pin="" cluster root

  if [[ -n "$mac" ]]; then
    pin="$(host_registry "$mac" get system_pin 2>/dev/null)" || pin=""
  fi
  if [[ -z "$pin" ]]; then
    cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
    if [[ -n "$cluster" ]]; then
      pin="$(cluster_registry "$cluster" get nixos_default_pin 2>/dev/null)" || pin=""
    fi
  fi
  if [[ -z "$pin" ]]; then
    root="$(hps_get_config resources)" || return 1
    if [[ -r "${root}/nixos/latest" ]]; then
      pin="$(tr -d '[:space:]' < "${root}/nixos/latest")"
    fi
  fi
  [[ -n "$pin" ]] || return 1
  printf '%s\n' "$pin"
}

# nixos_manifest_path <profile> [pin]
# Path of boot.json for a profile. Without a pin, the cluster default or
# latest is used. Profile and pin are validated; they become path parts.
nixos_manifest_path() {
  local profile="${1:-}"
  local pin="${2:-}"
  local root

  if [[ ! "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    hps_log error "nixos_manifest_path: invalid profile '${profile}'"
    return 1
  fi
  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin)" || {
      hps_log error "nixos_manifest_path: no pin (no cluster nixos_default_pin, no latest)"
      return 1
    }
  fi
  if [[ ! "$pin" =~ ^[a-z0-9][a-z0-9.-]+$ ]]; then
    hps_log error "nixos_manifest_path: invalid pin '${pin}'"
    return 1
  fi
  root="$(hps_get_config resources)" || return 1
  printf '%s/nixos/%s/%s/boot.json\n' "$root" "$pin" "$profile"
}

# nixos_ips_address
# Address the node uses to reach the IPS (the same value ipxe_boot_alpine uses).
nixos_ips_address() {
  local cluster
  cluster="$(hps_get_config active_cluster)" || return 1
  cluster_registry "$cluster" get network_dhcp_ip
}

# nixos_boot_lines <mac> <profile> [pin]
# The iPXE kernel/initrd/boot lines for a profile, from its manifest.
# Pin: argument, else the host's system_pin, else cluster default, else latest.
# Returns 1 with a log line (no output) when the manifest is unusable.
nixos_boot_lines() {
  local mac="${1:-}"
  local profile="${2:-}"
  local pin="${3:-}"
  local manifest ips cmdline init

  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin "$mac")" || {
      hps_log error "[$mac] no NixOS pin (host system_pin, cluster nixos_default_pin, latest all unset)"
      return 1
    }
  fi
  manifest="$(nixos_manifest_path "$profile" "$pin")" || return 1
  if [[ ! -r "$manifest" ]]; then
    hps_log error "[$mac] NixOS manifest missing: ${manifest}"
    return 1
  fi
  ips="$(nixos_ips_address)" || ips=""
  if [[ -z "$ips" ]]; then
    hps_log error "[$mac] NixOS boot: IPS address (network_dhcp_ip) not set"
    return 1
  fi
  cmdline="$(jq -r '.cmdline // ""' "$manifest")" || return 1
  init="$(jq -r '.init // empty' "$manifest")" || return 1
  if [[ -z "$init" ]]; then
    hps_log error "[$mac] NixOS manifest has no init: ${manifest}"
    return 1
  fi

  local base="http://${ips}/nixos/${pin}/${profile}"
  local args="$cmdline"
  # build.sh's cmdline may already carry init=; add it only when absent.
  if [[ " ${args} " != *" init="* ]]; then
    args="${args:+${args} }init=${init}"
  fi
  args="${args} hps.ips=${ips} hps.mac=${mac} hps.profile=${profile} hps.pin=${pin}"
  printf 'kernel %s/bzImage %s\n' "$base" "$args"
  printf 'initrd %s/initrd\n' "$base"
  printf 'boot\n'
}

# nixos_emit_boot <mac> <profile> [pin]
# Full iPXE script for a profile; on failure sends the iPXE error screen.
nixos_emit_boot() {
  local mac="$1"
  local profile="$2"
  local pin="${3:-}"
  local lines manifest

  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin "$mac")" || {
      cgi_auto_fail "No NixOS pin for ${mac}: set cluster nixos_default_pin or build an image (nixos/latest)"
      return 1
    }
  fi
  manifest="$(nixos_manifest_path "$profile" "$pin")" || {
    cgi_auto_fail "NixOS profile '${profile}' or pin '${pin}' is invalid"
    return 1
  }
  lines="$(nixos_boot_lines "$mac" "$profile" "$pin")" || {
    cgi_auto_fail "NixOS boot unavailable: manifest ${manifest} missing or invalid"
    return 1
  }
  ipxe_header
  echo "# Required to prevent corrupt initrd"
  echo "imgfree"
  echo "$lines"
}

# ipxe_boot_audit <mac>
# Held hosts boot the audit profile at the cluster default pin, else latest
# (they have no system_pin yet).
ipxe_boot_audit() {
  local mac="${1:-${mac:-}}"
  hps_log info "[$mac] held: booting audit image"
  nixos_emit_boot "$mac" audit
}

# nixos_image_profile <host profile>
# Map a registry HOST_PROFILE to a built image profile.
nixos_image_profile() {
  case "${1:-}" in
    CONVERGED) echo node-converged ;;
    DEFAULT)   echo node-base ;;
    *)         return 1 ;;
  esac
}

# ipxe_boot_nixos <mac>
# Network boot of an assigned NixOS host: image profile from HOST_PROFILE.
ipxe_boot_nixos() {
  local mac="${1:-${mac:-}}"
  local host_profile image
  host_profile="$(host_registry "$mac" get HOST_PROFILE 2>/dev/null)" || host_profile=""
  image="$(nixos_image_profile "$host_profile")" || {
    cgi_auto_fail "No NixOS image profile for host profile '${host_profile}' (known: CONVERGED, DEFAULT)"
    return 1
  }
  hps_log info "[$mac] NixOS network boot: host profile ${host_profile} -> image ${image}"
  nixos_emit_boot "$mac" "$image"
}
