# shellcheck shell=bash
# nixos-lib-functions.sh
#
# NixOS compatibility functions for the node function bundle. Sourced after
# base/*.sh, so these definitions replace or supply the names that base inits
# call. The rule on NixOS: a function either does the equivalent safely or
# logs "nixos: skipped <what>" and returns 0 - it never fails the init run.
#
# n_os_is_nixos, n_os_id and n_nixos_skip live in base/n_os-detect.sh.
#
# Test overrides: HPS_CMDLINE, HPS_PROFILE_D, HPS_RUN_DIR.

#===============================================================================
# n_get_provisioning_node
# -----------------------
# The IPS address. A NixOS node is told it on the kernel command line
# (hps.ips=); fall back to the default gateway as the base function does.
#===============================================================================
n_get_provisioning_node() {
  local word ips=""
  local cmdline="${HPS_CMDLINE:-/proc/cmdline}"
  if [[ -r "$cmdline" ]]; then
    for word in $(cat "$cmdline"); do
      if [[ "$word" == hps.ips=* ]]; then
        ips="${word#hps.ips=}"
        break
      fi
    done
  fi
  if [[ -z "$ips" ]]; then
    ips=$(ip route | awk '/^default/ { print $3; exit }')
  fi
  echo "$ips"
}

#===============================================================================
# n_install_packages
# ------------------
# Packages are part of the NixOS image; nothing is installed at runtime.
#===============================================================================
n_install_packages() {
  echo "nixos: packages come from the image; ignoring: $*" >&2
  n_remote_log "nixos: packages come from the image; ignoring: $*"
  return 0
}

#===============================================================================
# n_configure_ips_profile
# -----------------------
# Write the HPS login-shell environment drop-in. /etc/profile.d is used only if
# it is a writable directory; otherwise the drop-in goes to /run/hps/profile.d
# and the fallback is logged. Never touches /bin/sh.
#
# The bundle saved by hps-node-init is /run/hps/functions.sh; the drop-in
# exports it as HPS_BOOTSTRAP_LIB (the hps-node plugin reads that name) and does
# not source it, since sourcing runs the bundle's top-level code.
#
# Returns: 0 on success, 1 if neither directory can be written.
#===============================================================================
n_configure_ips_profile() {
  local run_dir="${HPS_RUN_DIR:-/run/hps}"
  local profile_d="${HPS_PROFILE_D:-/etc/profile.d}"
  local target_dir

  if [[ -d "$profile_d" && -w "$profile_d" ]]; then
    target_dir="$profile_d"
  else
    target_dir="$run_dir/profile.d"
    n_remote_log "nixos: $profile_d is not a writable directory; using $target_dir"
    echo "nixos: $profile_d is not a writable directory; using $target_dir" >&2
    mkdir -p "$target_dir" || {
      n_remote_log "nixos: cannot create $target_dir"
      return 1
    }
  fi

  local profile_script="$target_dir/hps-env.sh"
  cat > "$profile_script" <<EOT
# HPS environment for login shells (written by n_configure_ips_profile).
: "\${TERM:=xterm}"
export TERM
export HPS_BOOTSTRAP_LIB="$run_dir/functions.sh"
EOT
  chmod 0644 "$profile_script" || true

  if [[ ! -s "$profile_script" ]]; then
    n_remote_log "nixos: failed to write $profile_script"
    return 1
  fi
  n_remote_log "nixos: profile script written: $profile_script"
  return 0
}

#===============================================================================
# n_configure_reboot_logging
# --------------------------
# The Alpine version wraps /sbin/reboot via /usr/local/sbin; on NixOS the
# commands are store-managed and /usr/local/sbin is not on PATH.
#===============================================================================
n_configure_reboot_logging() {
  n_nixos_skip "reboot logging wrappers (/sbin and /usr/local are not writable here)"
  return 0
}
