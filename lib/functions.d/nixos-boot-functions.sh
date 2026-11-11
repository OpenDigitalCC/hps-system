# shellcheck shell=bash
#===============================================================================
# NixOS netboot, driven by build manifests.
#
# The builder (nix/build.sh) writes, under ${resources}/nixos:
#   <pin>/<profile>/{bzImage,initrd,boot.json}      and   latest  (the pin)
# boot.json carries the kernel command line and init path; nothing about a
# NixOS boot is hard-coded here. lighttpd serves the tree at /nixos/.
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
  # Registry hostname, when assigned: lets the node name its logs from the
  # first line (hps-log-target reads it); held/audit nodes have none.
  local hostname
  hostname="$(host_registry "$mac" get HOSTNAME 2>/dev/null)" || hostname=""
  if [[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
    args="${args} hps.hostname=${hostname}"
  fi
  # Cluster DNS domain: the node makes its hostname <name>.<domain> so that
  # the ctrl-exec agent registers under a well-formed FQDN (hps-pair).
  local domain cluster
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  domain=""
  if [[ -n "$cluster" ]]; then
    domain="$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null)" || domain=""
  fi
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    args="${args} hps.domain=${domain}"
  fi
  # Boot-NIC bridge (host key boot_bridge): hps-net makes the boot NIC a
  # member of it so guests can attach to the provisioning segment itself.
  local bridge
  bridge="$(host_registry "$mac" get boot_bridge 2>/dev/null)" || bridge=""
  if [[ "$bridge" =~ ^br-[a-z0-9-]{1,12}$ ]]; then
    args="${args} hps.bridge=${bridge}"
  fi
  # Audit image only: the cluster key held_reboot_after_audit=false (IPS-14)
  # keeps it up after the audit (default: it reboots into the hold loop).
  if [[ "$profile" == audit && -n "$cluster" ]]; then
    local keep_up
    keep_up="$(cluster_registry "$cluster" get held_reboot_after_audit 2>/dev/null)" || keep_up=""
    case "$keep_up" in
      false|0|no) args="${args} hps.audit_reboot=0" ;;
    esac
  fi
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
  nixos_emit_boot "$mac" audit || return 1
  # The audit image runs the ctrl-exec agent and pairs (CS-1.10), so a held
  # node needs the pairing window like an assigned one.
  nixos_open_pairing_window "$mac"
}

# ipxe_hold_retry_seconds
# Seconds a held node waits between boot requests: cluster key
# hold_retry_seconds, an integer 5..3600, default 30. A value outside that
# range is logged and replaced by the default.
ipxe_hold_retry_seconds() {
  local cluster val=""
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  if [[ -n "$cluster" ]]; then
    val="$(cluster_registry "$cluster" get hold_retry_seconds 2>/dev/null)" || val=""
  fi
  if [[ -z "$val" ]]; then
    echo 30
    return 0
  fi
  if [[ "$val" =~ ^[0-9]{1,4}$ ]] && (( 10#$val >= 5 && 10#$val <= 3600 )); then
    echo $(( 10#$val ))
    return 0
  fi
  hps_log warn "cluster key hold_retry_seconds='${val}' is not an integer 5..3600; using 30"
  echo 30
}

# ipxe_held_needs_audit <mac>
# True (0) when a held host must boot the audit image: it has no stored audit,
# or the audit is marked stale (hps-onboard reaudit; cleared when a new audit
# is stored by host_audit_intake).
ipxe_held_needs_audit() {
  local mac="$1" stale=""
  host_registry "$mac" exists audit 2>/dev/null || return 0
  stale="$(host_registry "$mac" get audit_stale 2>/dev/null)" || stale=""
  [[ "$stale" == "true" ]]
}

# ipxe_boot_held <mac>
# A HELD host without a (fresh) audit boots the audit image. One with its
# audit stored waits at iPXE: a script that prints the hold message, sleeps,
# then chains back to the boot URL the DHCP boot option points at
# (boot_manager.sh?cmd=init). The next request after hps-onboard assign finds
# the host assigned and boots its role; no power action is involved. If the
# IPS is down the chain fails, iPXE shows its error and the script retries.
# Nothing secret is in the script.
ipxe_boot_held() {
  local mac="${1:-${mac:-}}"
  local n
  if ipxe_held_needs_audit "$mac"; then
    ipxe_boot_audit "$mac"
    return
  fi
  n="$(ipxe_hold_retry_seconds)"
  hps_log debug "[$mac] held with audit stored: hold script, retry in ${n}s"
  cgi_header_plain
  cat <<EOF
#!ipxe
echo HPS: ${mac} is held; waiting for a role (retry in ${n} s)
sleep ${n}
:retry
chain --replace ${CGI_URL}?cmd=init || goto failed
exit
:failed
echo HPS: the IPS did not answer; retry in ${n} s
sleep ${n}
goto retry
EOF
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
  nixos_emit_boot "$mac" "$image" || return 1
  nixos_open_pairing_window "$mac"
}

# nixos_open_pairing_window <mac>
# A RAM-booted node pairs with ctrl-exec on every boot: clear the previous
# pairing record and open the dispatcher's pairing window (ADR 0002). The
# window is single and shared; a failure to open is logged, never fatal.
nixos_open_pairing_window() {
  local mac="$1"
  host_registry "$mac" delete ctrl_exec_paired_at > /dev/null 2>&1 || true
  host_registry "$mac" delete ctrl_exec_paired > /dev/null 2>&1 || true
  if ! ce_pairing_window_open "${CTRL_EXEC_PAIR_WINDOW:-300}" > /dev/null 2>&1 < /dev/null; then
    hps_log warn "[$mac] pairing window not opened (already open, or dispatcher error)"
  fi
  return 0
}
