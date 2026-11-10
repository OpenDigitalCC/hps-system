#!/usr/bin/env bash
#
# hps-net - configure ONLY the NIC the node booted from.
#
# Runs as a oneshot before systemd-networkd (nix/modules/hps-common.nix) on
# every HPS image. A node can have a second NIC on a switch that also carries
# another LAN; with DHCP on every interface that NIC took a lease and a domain
# there and the ctrl-exec agent registered under the foreign FQDN.
#
#  1. reads hps.mac= from the kernel command line (12 hex digits as the IPS
#     writes it, or colon separated; any case)
#  2. writes $HPS_NETWORK_DIR/10-hps-boot.network: match that MAC, DHCP=ipv4,
#     and from the lease take the address, routes and DNS only - no hostname
#     (HPS names the node), no search domain, no hostname sent
#  3. writes $HPS_NETWORK_DIR/99-hps-others.network: every other interface is
#     Unmanaged, so a NIC on a foreign LAN gets nothing
#  4. hps.mac absent or malformed: logs loudly and falls back to DHCP on every
#     interface (same lease options), so the node still comes up
#  5. hps.bridge=<name> (host key boot_bridge; ^br-[a-z0-9-]{1,12}$) with a
#     good hps.mac: the boot NIC becomes a bridge member so guests can sit on
#     the provisioning segment itself (macvtap cannot reach the host). Three
#     units instead of one: 08-hps-boot-bridge.netdev (the bridge, MACAddress
#     = the boot NIC's MAC, so the IPS sees the same host), 11-hps-boot-
#     member.network (the NIC, Bridge=<name>) and 10-hps-boot.network moved to
#     match the bridge by name, same lease options. Without the key, or with
#     a malformed one, nothing changes.
#
# networkd uses the first .network file (by name) that matches a link, so the
# boot NIC is taken by 10- and 99- sees only the rest.
#
# Overrides for tests: HPS_CMDLINE (file), HPS_NETWORK_DIR.

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_NETWORK_DIR:=/run/systemd/network}"

log() {
  printf '[hps-net] %s\n' "$*" >&2
}

# cmdline_value <key>: the value of key=<value> on the kernel command line.
cmdline_value() {
  local key="$1" word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    case "$word" in
      "$key"=*) printf '%s\n' "${word#"$key"=}"; return 0 ;;
    esac
  done
  return 1
}

cmdline_mac() {
  cmdline_value hps.mac
}

# normalise_mac <text>: print aa:bb:cc:dd:ee:ff, or fail when not a MAC.
normalise_mac() {
  local raw="${1//:/}"
  raw="${raw,,}"
  if [[ ! "$raw" =~ ^[0-9a-f]{12}$ ]]; then
    return 1
  fi
  printf '%s:%s:%s:%s:%s:%s\n' "${raw:0:2}" "${raw:2:2}" "${raw:4:2}" \
    "${raw:6:2}" "${raw:8:2}" "${raw:10:2}"
}

# write_file <path> <content>: logged write.
write_file() {
  log "+ write $1"
  printf '%s' "$2" > "$1"
}

dhcp_options='[DHCPv4]
UseHostname=false
UseDomains=false
SendHostname=false
'

write_boot_nic() {
  local mac="$1"
  rm -f "$HPS_NETWORK_DIR/08-hps-boot-bridge.netdev" "$HPS_NETWORK_DIR/11-hps-boot-member.network"
  write_file "$HPS_NETWORK_DIR/10-hps-boot.network" "[Match]
MACAddress=${mac}

[Network]
DHCP=ipv4

[Link]
RequiredForOnline=yes

${dhcp_options}"
  write_file "$HPS_NETWORK_DIR/99-hps-others.network" "[Match]
Name=*

[Link]
Unmanaged=yes
"
}

# write_boot_bridge <mac> <bridge>: the boot NIC is a member of <bridge>, which
# carries the MAC and the DHCP client. The member file excludes the bridge by
# type and name because the bridge has the NIC's MAC.
write_boot_bridge() {
  local mac="$1" bridge="$2"
  write_file "$HPS_NETWORK_DIR/08-hps-boot-bridge.netdev" "[NetDev]
Name=${bridge}
Kind=bridge
MACAddress=${mac}
"
  write_file "$HPS_NETWORK_DIR/11-hps-boot-member.network" "[Match]
MACAddress=${mac}
Type=ether
Name=!${bridge}

[Network]
Bridge=${bridge}

[Link]
RequiredForOnline=enslaved
"
  write_file "$HPS_NETWORK_DIR/10-hps-boot.network" "[Match]
Name=${bridge}

[Network]
DHCP=ipv4

[Link]
RequiredForOnline=yes

${dhcp_options}"
  write_file "$HPS_NETWORK_DIR/99-hps-others.network" "[Match]
Name=*

[Link]
Unmanaged=yes
"
}

write_all_nics() {
  rm -f "$HPS_NETWORK_DIR/08-hps-boot-bridge.netdev" "$HPS_NETWORK_DIR/11-hps-boot-member.network"
  rm -f "$HPS_NETWORK_DIR/99-hps-others.network"
  write_file "$HPS_NETWORK_DIR/10-hps-boot.network" "[Match]
Name=*

[Network]
DHCP=ipv4

${dhcp_options}"
}

# boot_bridge: the validated hps.bridge= value, nothing when absent or malformed.
boot_bridge() {
  local raw
  raw=$(cmdline_value hps.bridge || true)
  [[ -n "$raw" ]] || return 0
  if [[ ! "$raw" =~ ^br-[a-z0-9-]{1,12}$ ]]; then
    log "WARNING: hps.bridge '${raw}' is not br-<1-12 of a-z0-9-> ; ignored"
    return 0
  fi
  printf '%s\n' "$raw"
}

main() {
  local raw mac bridge
  log "+ mkdir -p $HPS_NETWORK_DIR"
  mkdir -p "$HPS_NETWORK_DIR"
  raw=$(cmdline_mac || true)
  mac=$(normalise_mac "$raw" || true)
  if [[ -z "$mac" ]]; then
    log "WARNING: hps.mac absent or malformed on the command line (${raw:-<none>})"
    log "WARNING: falling back to DHCP on EVERY interface; a NIC on a foreign LAN will be configured"
    write_all_nics
    return 0
  fi
  bridge=$(boot_bridge)
  if [[ -n "$bridge" ]]; then
    log "boot NIC ${mac}: member of bridge ${bridge}; DHCP on the bridge only; all other interfaces unmanaged"
    write_boot_bridge "$mac" "$bridge"
    return 0
  fi
  log "boot NIC ${mac}: DHCP there only; all other interfaces unmanaged"
  write_boot_nic "$mac"
}

main "$@"
