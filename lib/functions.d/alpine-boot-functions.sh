# shellcheck shell=bash
#===============================================================================
# Booting an Alpine host from the stock starter (plan step 4, docs/STARTER.md
# "Alpine", docs/BUNDLE.md "The hook" on Alpine).
#
# HOST_PROFILE STARTER on an Alpine host boots the kernel and initramfs that
# hps-starter sync alpine put under <resources>/starter/alpine/<release>/, matched
# to the repository's kernel, with the stock initramfs's own arguments:
#
#   alpine_repo=   the IPS's package repository (main and community), which the
#                  stock initramfs reads at boot to install its base packages
#   modloop=none   no modloop: the node installs linux-lts from the repository
#   apkovl=        the stock initramfs's own hook: it fetches this file over the
#                  provisioning network, unpacks it into the new root and installs
#                  the packages its etc/apk/world names. The overlay is built by the
#                  IPS on each request (node_apkovl_tar): a world file, the runlevel
#                  of OpenRC's own "local" service, and one script that runs
#                  node_bootstrap, the same script the NixOS hook runs. It holds no
#                  secret and no node logic; the starter files are untouched.
#   hps.*          the node bundle's arguments (docs/BUNDLE.md)
#
# The apkovl URL ends in a file name ending in .tar.gz because the stock init
# decides how to unpack by that suffix (it takes whatever follows the last "/" and
# drops a query), and it has no "&" and no ";" so that iPXE passes it as it is.
#===============================================================================

# alpine_starter_lsm_args <stock cmdline>
# The boot-arguments part of AppArmor on an Alpine node (docs/BUNDLE.md "Alpine"): the
# stock kernel has AppArmor built in (CONFIG_SECURITY_APPARMOR=y) but its built-in list
# (CONFIG_LSM=landlock,lockdown,yama,loadpin,safesetid,integrity) leaves it out. The line
# gets that list with apparmor added, and apparmor=1; a stock lsm= is kept and gains
# apparmor. Prints the stock arguments followed by these.
alpine_starter_lsm_args() {
  local word out="" lsm_seen=""
  for word in $1; do
    case "$word" in
      lsm=*)
        lsm_seen=1
        [[ ",${word#lsm=}," == *",apparmor,"* ]] || word="${word},apparmor"
        ;;
      apparmor=*) continue ;;
    esac
    out="${out:+$out }$word"
  done
  [[ -n "$lsm_seen" ]] || out="${out:+$out }lsm=landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"
  printf '%s apparmor=1\n' "$out"
}

# alpine_starter_boot_lines <mac> <version>
# The iPXE kernel/initrd/boot lines; returns 1 with a log line when the starter
# is not usable.
alpine_starter_boot_lines() {
  local mac="${1:-}"
  local version="${2:-}"
  local root manifest ips cmdline os_id cluster domain args base zfs_hostid
  if [[ ! "$version" =~ ^[0-9][0-9A-Za-z.-]*$ ]]; then
    hps_log error "[$mac] Alpine starter: invalid release '${version}' (the host's os_id must end in the release, x86_64:alpine:3.24)"
    return 1
  fi
  root="$(hps_get_config resources)" || return 1
  manifest="${root}/starter/alpine/${version}/manifest.json"
  if [[ ! -r "$manifest" || ! -r "${manifest%/*}/vmlinuz-lts" || ! -r "${manifest%/*}/initramfs-lts" ]]; then
    hps_log error "[$mac] Alpine starter ${version} missing under ${manifest%/*}: run hps-starter sync alpine"
    return 1
  fi
  if [[ ! -r "${root}/packages/alpine/${version}/manifest.json" ]]; then
    hps_log error "[$mac] Alpine repository ${version} missing under ${root}/packages/alpine/${version}: run hps-starter sync alpine"
    return 1
  fi
  ips="$(nixos_ips_address)" || ips=""
  if [[ -z "$ips" ]]; then
    hps_log error "[$mac] Alpine starter boot: IPS address (network_dhcp_ip) not set"
    return 1
  fi
  if [[ ! "$ips" =~ ^[0-9A-Za-z.:-]+$ ]]; then
    hps_log error "[$mac] Alpine starter boot: IPS address '${ips}' is not usable in a kernel line"
    return 1
  fi
  cmdline="$(jq -r '.cmdline // ""' "$manifest")" || return 1
  os_id="$(host_registry "$mac" get os_id 2>/dev/null)" || os_id=""
  base="http://${ips}/starter/alpine/${version}"
  args="initrd=initramfs-lts $(alpine_starter_lsm_args "$cmdline") console=ttyS0,115200"
  args="${args} alpine_repo=http://${ips}/packages/alpine/${version}/main,http://${ips}/packages/alpine/${version}/community"
  args="${args} apkovl=http://${ips}/cgi-bin/boot_manager.sh?cmd=node_apkovl/node.apkovl.tar.gz"
  args="${args} hps.ips=${ips} hps.mac=${HPS_BOOT_MAC:-$mac} hps.os=${os_id} hps.profile=STARTER"
  # The node's own ZFS hostid (as on the pinned images and the NixOS starter): a pool
  # left imported by a power loss must not import on another node without -f. The
  # node's role step writes /etc/hostid from it (zgenhostid) before ZFS loads.
  if zfs_hostid="$(nixos_zfs_hostid "$mac")"; then
    args="${args} hps.zfs_hostid=${zfs_hostid}"
    if [[ "$(host_registry "$mac" get zfs_hostid 2>/dev/null)" != "$zfs_hostid" ]]; then
      host_registry "$mac" set zfs_hostid "$zfs_hostid" > /dev/null 2>&1 || hps_log warn "[$mac] could not record zfs_hostid"
    fi
  else
    hps_log warn "[$mac] no ZFS hostid derived (malformed host key MAC)"
  fi
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  domain=""
  if [[ -n "$cluster" ]]; then
    domain="$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null)" || domain=""
  fi
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    args="${args} hps.domain=${domain}"
  fi
  printf 'kernel %s/vmlinuz-lts %s\n' "$base" "$args"
  printf 'initrd %s/initramfs-lts\n' "$base"
  printf 'boot\n'
}

# alpine_emit_starter_boot <mac> <version>
alpine_emit_starter_boot() {
  local mac="$1" version="$2" lines
  lines="$(alpine_starter_boot_lines "$mac" "$version")" || {
    cgi_auto_fail "Alpine starter ${version} unavailable: run hps-starter sync alpine on the IPS"
    return 1
  }
  ipxe_header
  echo "# Required to prevent corrupt initrd"
  echo "imgfree"
  echo "$lines"
}

# alpine_ipxe_starter <mac>: the STARTER branch of ipxe_boot_alpine. Like any RAM-booted
# node it pairs on every boot, so the boot opens the pairing window.
alpine_ipxe_starter() {
  local mac="${1:-}" os_id
  os_id="$(host_registry "$mac" get os_id 2>/dev/null)" || os_id=""
  hps_log info "[$mac] Alpine network boot: stock starter ${os_id##*:}"
  alpine_emit_starter_boot "$mac" "${os_id##*:}" || return 1
  nixos_open_pairing_window "$mac"
  return 0
}
