# shellcheck shell=bash
# n_os-detect.sh
#
# OS identity helpers for the node function bundle. Base functions use these to
# pick a per-distro branch (or to skip with a log line on NixOS).
#
# HPS_OS_ROOT prefixes the probed paths; tests point it at a fixture tree.

#===============================================================================
# n_os_is_nixos
# -------------
# True on NixOS: /etc/os-release has ID=nixos, or /etc/NIXOS exists.
#===============================================================================
n_os_is_nixos() {
  local root="${HPS_OS_ROOT:-}"
  if [[ -e "${root}/etc/NIXOS" ]]; then
    return 0
  fi
  if [[ -r "${root}/etc/os-release" ]] && grep -qE '^ID="?nixos"?$' "${root}/etc/os-release"; then
    return 0
  fi
  return 1
}

#===============================================================================
# n_os_id
# -------
# Print the distro family: nixos, alpine, rocky or unknown. Always returns 0 so
# callers can branch on the output instead of failing on an unknown distro.
#===============================================================================
n_os_id() {
  local root="${HPS_OS_ROOT:-}"
  if n_os_is_nixos; then
    echo nixos
  elif [[ -f "${root}/etc/alpine-release" ]]; then
    echo alpine
  elif [[ -f "${root}/etc/rocky-release" || -f "${root}/etc/redhat-release" ]]; then
    echo rocky
  else
    echo unknown
  fi
  return 0
}

#===============================================================================
# n_nixos_skip
# ------------
# Log that a step was skipped because this is NixOS. Always returns 0.
#
# Arguments:
#   $* - what was skipped
#===============================================================================
n_nixos_skip() {
  echo "nixos: skipped $*" >&2
  if declare -F n_remote_log > /dev/null 2>&1; then
    n_remote_log "nixos: skipped $*"
  fi
  return 0
}
