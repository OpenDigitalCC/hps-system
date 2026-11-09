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

cmdline_mac() {
  local word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    case "$word" in
      hps.mac=*) printf '%s\n' "${word#hps.mac=}"; return 0 ;;
    esac
  done
  return 1
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

write_all_nics() {
  rm -f "$HPS_NETWORK_DIR/99-hps-others.network"
  write_file "$HPS_NETWORK_DIR/10-hps-boot.network" "[Match]
Name=*

[Network]
DHCP=ipv4

${dhcp_options}"
}

main() {
  local raw mac
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
  log "boot NIC ${mac}: DHCP there only; all other interfaces unmanaged"
  write_boot_nic "$mac"
}

main "$@"
