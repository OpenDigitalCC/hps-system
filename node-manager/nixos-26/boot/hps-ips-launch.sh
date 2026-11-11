#!/usr/bin/env bash
#
# hps-ips-launch - start and stop the IPS container of a container host.
#
# Run by hps-ips.service (nix/modules/profiles/container-host.nix):
#   ExecStart     hps-ips-launch start      (stays in the foreground: podman run)
#   ExecStop      hps-ips-launch stop
#   ExecStopPost  hps-ips-launch stop-post
#
# Settings come from /var/lib/hps-ips/ips.env, written by cnh-ips-run, one
# KEY=VALUE per line (IMAGE, IFACE, ADDRESS); the file is parsed, never
# sourced, and every value is checked again here. The unit only starts when
# that file exists (ConditionPathExists), so a CNH with no IPS configured, or
# one stopped with cnh-ips-stop, runs nothing.
#
# start:
#   1. ip link set <IFACE> up; ip addr replace <ADDRESS> dev <IFACE>
#      (hps-net leaves every non-boot link unmanaged, so networkd keeps off it)
#   2. when the NixOS firewall chain nixos-fw exists: accept everything that
#      arrives on <IFACE> (the IPS owns that network: DHCP, TFTP and its data
#      ports, DNS, HTTP, syslog, chrony, ctrl-exec pairing)
#   3. exec podman run, the lab IPS shape (lab/ips/compose.yml: privileged,
#      cgroup host, /srv and /srv/hps-system bind mounts, the cgroup tree) with
#      host networking and its output in the journal (tag hps-ips), so it is
#      forwarded with the node's own log to the IPS that provisions this node.
# stop:       podman stop --time 30 hps-ips
# stop-post:  the firewall rule is removed (the address stays on the interface)
#
# Exit: 0 ok, 2 usage, 3 refused (ips.env missing or a value malformed),
# 1 a command failed.
#
# Overrides for tests: HPS_CNH_ROOT (prefix of /var/lib/hps-ips).

set -euo pipefail

: "${HPS_CNH_ROOT:=}"

IPSDIR="$HPS_CNH_ROOT/var/lib/hps-ips"
ENVFILE="$IPSDIR/ips.env"
NAME=hps-ips
IMAGE=""
IFACE=""
ADDRESS=""

log() {
  printf '[hps-ips-launch] %s\n' "$*" >&2
}

refuse() {
  log "refused: $*"
  exit 3
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

valid_cidr() {
  local ip=${1%/*} prefix=${1#*/} o
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || return 1
  [[ $prefix -ge 1 && $prefix -le 32 ]] || return 1
  for o in ${ip//./ }; do
    [[ $((10#$o)) -le 255 ]] || return 1
  done
  return 0
}

read_env() {
  local line key value
  [[ -f "$ENVFILE" ]] || refuse "no $ENVFILE (cnh-ips-run writes it)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      IMAGE) IMAGE=$value ;;
      IFACE) IFACE=$value ;;
      ADDRESS) ADDRESS=$value ;;
      *) refuse "unknown key '$key' in $ENVFILE" ;;
    esac
  done < "$ENVFILE"
  [[ "$IMAGE" =~ ^[a-z0-9][a-z0-9._/:@-]{0,254}$ && "$IMAGE" != *..* ]] || refuse "IMAGE '$IMAGE' in $ENVFILE is not a plain image reference"
  [[ "$IFACE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ ]] || refuse "IFACE '$IFACE' in $ENVFILE is not an interface name"
  valid_cidr "$ADDRESS" || refuse "ADDRESS '$ADDRESS' in $ENVFILE is not an IPv4 address/prefix"
}

have_nixos_fw() {
  run iptables -w -n -L nixos-fw > /dev/null 2>&1
}

firewall_open() {
  if ! have_nixos_fw; then
    log "no nixos-fw iptables chain: firewall rule not needed"
    return 0
  fi
  if run iptables -w -C nixos-fw -i "$IFACE" -j nixos-fw-accept 2> /dev/null; then
    log "nixos-fw already accepts $IFACE"
    return 0
  fi
  run iptables -w -I nixos-fw 1 -i "$IFACE" -j nixos-fw-accept
}

firewall_close() {
  have_nixos_fw || return 0
  while run iptables -w -C nixos-fw -i "$IFACE" -j nixos-fw-accept 2> /dev/null; do
    run iptables -w -D nixos-fw -i "$IFACE" -j nixos-fw-accept
  done
}

start() {
  [[ -d "$IPSDIR/srv" ]] || refuse "no $IPSDIR/srv (cnh-ips-bootstrap fills it)"
  [[ -d "$IPSDIR/hps-system" ]] || refuse "no $IPSDIR/hps-system (cnh-ips-bootstrap fills it)"
  run ip link set dev "$IFACE" up
  run ip addr replace "$ADDRESS" dev "$IFACE"
  firewall_open
  run mkdir -p -- "$IPSDIR/srv/hps-system"
  printf '+ exec podman run %s on %s (%s)\n' "$IMAGE" "$IFACE" "$ADDRESS" >&2
  exec podman run --name "$NAME" --replace --rm \
    --privileged --cgroupns=host --network=host --hostname=ips \
    --log-driver=journald --log-opt=tag=hps-ips \
    --stop-timeout=30 \
    --volume "$IPSDIR/srv:/srv" \
    --volume "$IPSDIR/hps-system:/srv/hps-system" \
    --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
    "$IMAGE"
}

main() {
  case "${1:-}" in
    start)
      read_env
      start
      ;;
    stop)
      run podman stop --time 30 "$NAME" || log "podman stop $NAME exited $? (not running?)"
      ;;
    stop-post)
      read_env
      firewall_close
      ;;
    *)
      printf 'Usage: hps-ips-launch start|stop|stop-post\n' >&2
      exit 2
      ;;
  esac
}

main "$@"
