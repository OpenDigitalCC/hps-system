# shellcheck shell=bash
# ipxe-nixos-functions.sh
#
# iPXE boot script for a NixOS node that runs from RAM. The kernel, initrd and
# base command line come from the builder's boot.json for the host's version
# pin (hps-resources/nixos/<pin>/<image>/boot.json, served at /nixos/...).
#
# Host keys read:  system_pin (cluster nixos_default_pin as fallback),
#                  nixos_image (default node-converged), HOST_PROFILE.
# Host keys written: ctrl_exec_paired is cleared - a RAM node loses its agent
#                  certificate on every boot, so each boot script starts a new
#                  enrolment cycle (ADR 0002 check 4).

: "${HPS_NIXOS_IMAGE:=node-converged}"

#===============================================================================
# _nixos_boot_manifest_path
# -------------------------
# Print the boot.json path for a pin and image.
#
# Arguments:
#   $1 - pin
#   $2 - image
#===============================================================================
_nixos_boot_manifest_path() {
  local pin="$1"
  local image="$2"
  local resources
  resources=$(hps_get_config resources) || return 1
  printf '%s/nixos/%s/%s/boot.json\n' "$resources" "$pin" "$image"
}

#===============================================================================
# _nixos_open_pairing_window
# --------------------------
# Start a new enrolment cycle for the host and open the dispatcher pairing
# window. The window command is detached from the CGI's stdio so the response
# can complete; a failure (for example a window already open for another node)
# is logged and does not stop the boot script.
#
# Arguments:
#   $1 - mac
#===============================================================================
_nixos_open_pairing_window() {
  local mac="$1"
  host_registry "$mac" delete ctrl_exec_paired > /dev/null 2>&1 || true
  if ! ce_pairing_window_open "${CTRL_EXEC_PAIR_WINDOW:-300}" > /dev/null 2>&1 < /dev/null; then
    hps_log warn "[$mac] pairing window not opened (already open, or dispatcher error)"
  fi
  return 0
}

#===============================================================================
# ipxe_boot_nixos
# ---------------
# Emit the iPXE script that netboots the host's pinned NixOS image.
#
# Arguments:
#   $1 - mac (default: the CGI's $mac)
#
# Returns: 0 on success; 1 (after ipxe_cgi_fail) when the pin or manifest is
# missing.
#===============================================================================
ipxe_boot_nixos() {
  local mac="${1:-${mac:-}}"
  local cluster pin image profile ips manifest
  local kernel initrd cmdline base

  cluster=$(hps_get_config active_cluster) || {
    hps_log error "No active cluster configured"
    return 1
  }
  pin=$(host_registry "$mac" get system_pin 2>/dev/null) || pin=""
  if [[ -z "$pin" ]]; then
    pin=$(cluster_registry "$cluster" get nixos_default_pin 2>/dev/null) || pin=""
  fi
  if [[ -z "$pin" ]]; then
    ipxe_cgi_fail "No NixOS version pin for $mac (host system_pin / cluster nixos_default_pin)"
    return 1
  fi
  image=$(host_registry "$mac" get nixos_image 2>/dev/null) || image=""
  image="${image:-$HPS_NIXOS_IMAGE}"
  profile=$(host_registry "$mac" get HOST_PROFILE 2>/dev/null) || profile=""
  profile="${profile:-DEFAULT}"

  manifest=$(_nixos_boot_manifest_path "$pin" "$image") || {
    ipxe_cgi_fail "Cannot determine the resources directory"
    return 1
  }
  if [[ ! -r "$manifest" ]]; then
    ipxe_cgi_fail "NixOS boot manifest missing: $pin/$image/boot.json"
    return 1
  fi
  kernel=$(jq -r '.kernel // empty' "$manifest")
  initrd=$(jq -r '.initrd // empty' "$manifest")
  cmdline=$(jq -r '.cmdline // empty' "$manifest")
  if [[ -z "$kernel" || -z "$initrd" ]]; then
    ipxe_cgi_fail "NixOS boot manifest incomplete: $pin/$image/boot.json"
    return 1
  fi

  ips=$(cluster_registry "$cluster" get network_dhcp_ip)
  base="http://${ips}/nixos/${pin}/${image}"
  cmdline="${cmdline} hps.ips=${ips} hps.mac=${mac} hps.profile=${profile}"

  _nixos_open_pairing_window "$mac"
  _do_pxe_boot "${base}/${kernel} ${cmdline}" "${base}/${initrd}"
}
