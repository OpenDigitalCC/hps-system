#!/usr/bin/env bats
#
# CS-3.11: cnh-ips-run, cnh-ips-stop and the unit's launcher hps-ips-launch.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

IMG=localhost/hps-container:latest

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-173.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
  p3_171_mount "$I" "$HPS_CNH_ROOT/var/lib/containers/hps-ips"
  mkdir -p "$I/srv" "$I/hps-system/scripts"
  : > "$I/hps-system/scripts/run-hps.sh"
  echo "$IMG" > "$STATE/images"
  p3_171_nic ens3 aa:bb:cc:dd:ee:ff
  p3_171_nic ens4 52:54:00:11:00:01
  p3_171_nic ens3.110 aa:bb:cc:dd:ee:ff vlan
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "writes ips.env, restarts hps-ips.service and reports it running" {
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IPS running image=$IMG iface=ens4 address=10.11.0.1/24" ]
  [ "$(grep -v '^#' "$I/ips.env")" = "$(printf 'IMAGE=%s\nIFACE=ens4\nADDRESS=10.11.0.1/24' "$IMG")" ]
  grep -qxF "systemd-run --quiet --wait --pipe --collect -- podman image exists $IMG" "$SHIM_LOG"
  grep -qxF "systemctl restart hps-ips.service" "$SHIM_LOG"
  grep -qxF "systemctl is-active --quiet hps-ips.service" "$SHIM_LOG"
  # podman is never run directly: the unit does it
  run ! grep -q '^podman run' "$SHIM_LOG"
}

@test "without an address the interface's current IPv4 address is used" {
  echo '[{"ifname":"ens4","addr_info":[{"family":"inet","local":"10.11.0.1","prefixlen":24}]}]' > "$STATE/ipaddr.ens4"
  run bash "$S/cnh-ips-run" "$IMG" ens4
  [ "$status" -eq 0 ]
  grep -qx 'ADDRESS=10.11.0.1/24' "$I/ips.env"
  run bash "$S/cnh-ips-run" "$IMG" ens3.110
  [ "$status" -eq 3 ]
  [[ "$output" == *"has no IPv4 address"* ]]
}

@test "the boot NIC is refused (3); a VLAN on it is allowed" {
  run bash "$S/cnh-ips-run" "$IMG" ens3 10.11.0.1/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"boot MAC"* ]]
  [ ! -e "$I/ips.env" ]
  run bash "$S/cnh-ips-run" "$IMG" ens3.110 10.11.0.1/24
  [ "$status" -eq 0 ]
}

@test "unknown interfaces, bad names, bad addresses and the node's own IPS address are refused (3)" {
  local a
  run bash "$S/cnh-ips-run" "$IMG" ens9 10.11.0.1/24
  [ "$status" -eq 3 ]
  run bash "$S/cnh-ips-run" "$IMG" '../x' 10.11.0.1/24
  [ "$status" -eq 3 ]
  for a in 10.11.0.1 10.11.0.256/24 10.11.0.1/33 10.11.0.1/0 a.b.c.d/24 "10.11.0.1/24;x"; do
    run bash "$S/cnh-ips-run" "$IMG" ens4 "$a"
    [ "$status" -eq 3 ]
  done
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.99.1.1/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"own IPS"* ]]
  [ ! -e "$I/ips.env" ]
}

@test "bad image references and images not loaded are refused (3)" {
  local i
  for i in 'Bad Image' '../x' '-x' 'a;b' ''; do
    run bash "$S/cnh-ips-run" "$i" ens4 10.11.0.1/24
    [ "$status" -ne 0 ]
  done
  run bash "$S/cnh-ips-run" localhost/other:1 ens4 10.11.0.1/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-image-load"* ]]
  [ ! -e "$I/ips.env" ]
}

@test "no CNH disk or no bootstrapped state is refused (3)" {
  rm -rf "$I/hps-system"
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-ips-bootstrap"* ]]
  rm -f "$STATE/mounts"
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-disk-prepare"* ]]
}

@test "a unit that does not become active fails (1)" {
  FAKE_ACTIVE_RC=3 run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not become active"* ]]
}

@test "usage errors exit 2" {
  run bash "$S/cnh-ips-run"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-run" "$IMG"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24 extra
  [ "$status" -eq 2 ]
}

@test "cnh-ips-stop stops the unit and keeps it off after a reboot; idempotent" {
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 0 ]
  run bash "$S/cnh-ips-stop"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "IPS stopped" ]
  grep -qxF "systemctl stop hps-ips.service" "$SHIM_LOG"
  [ ! -e "$I/ips.env" ]
  [ -f "$I/ips.env.stopped" ]
  run bash "$S/cnh-ips-stop"
  [ "$status" -eq 0 ]
  run bash "$S/cnh-ips-stop" extra
  [ "$status" -eq 2 ]
  # cnh-ips-run turns it back on
  run bash "$S/cnh-ips-run" "$IMG" ens4 10.11.0.1/24
  [ "$status" -eq 0 ]
  [ -f "$I/ips.env" ]
  [ ! -e "$I/ips.env.stopped" ]
}

# --- hps-ips-launch (the unit) ---------------------------------------------

write_env() {
  printf '# test\nIMAGE=%s\nIFACE=%s\nADDRESS=%s\n' "$1" "$2" "$3" > "$I/ips.env"
}

@test "launch start: address, firewall, then podman run in the lab IPS shape" {
  write_env "$IMG" ens4 10.11.0.1/24
  : > "$STATE/fw"
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 0 ]
  grep -qxF "ip link set dev ens4 up" "$SHIM_LOG"
  grep -qxF "ip addr replace 10.11.0.1/24 dev ens4" "$SHIM_LOG"
  grep -qxF "iptables -w -I nixos-fw 1 -i ens4 -j nixos-fw-accept" "$SHIM_LOG"
  line=$(grep '^podman run' "$SHIM_LOG")
  [[ "$line" == *"--name hps-ips --replace --rm"* ]]
  [[ "$line" == *"--privileged --cgroupns=host --network=host --hostname=ips"* ]]
  [[ "$line" == *"--log-driver=journald --log-opt=tag=hps-ips"* ]]
  [[ "$line" == *"--volume $I/srv:/srv --volume $I/hps-system:/srv/hps-system --volume /sys/fs/cgroup:/sys/fs/cgroup:rw $IMG" ]]
  [ -d "$I/srv/hps-system" ]
  # a second start does not add the firewall rule twice
  run bash "$B/hps-ips-launch.sh" start
  [ "$(grep -c ens4 "$STATE/fw-rules")" -eq 1 ]
}

@test "launch: no nixos-fw chain skips the firewall step" {
  write_env "$IMG" ens4 10.11.0.1/24
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 0 ]
  run ! grep -q 'iptables -w -I' "$SHIM_LOG"
  grep -q '^podman run' "$SHIM_LOG"
}

@test "launch stop and stop-post: podman stop, the firewall rule removed" {
  write_env "$IMG" ens4 10.11.0.1/24
  : > "$STATE/fw"
  run bash "$B/hps-ips-launch.sh" start
  run bash "$B/hps-ips-launch.sh" stop
  [ "$status" -eq 0 ]
  grep -qxF "podman stop --time 30 hps-ips" "$SHIM_LOG"
  run bash "$B/hps-ips-launch.sh" stop-post
  [ "$status" -eq 0 ]
  run ! grep -q ens4 "$STATE/fw-rules"
}

@test "launch refuses a missing or malformed ips.env (3) and runs nothing" {
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 3 ]
  write_env 'bad image' ens4 10.11.0.1/24
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 3 ]
  write_env "$IMG" 'ens4;x' 10.11.0.1/24
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 3 ]
  write_env "$IMG" ens4 10.11.0.1
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 3 ]
  printf 'IMAGE=%s\nIFACE=ens4\nADDRESS=10.11.0.1/24\nEXTRA=$(id)\n' "$IMG" > "$I/ips.env"
  run bash "$B/hps-ips-launch.sh" start
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown key"* ]]
  run ! grep -qE '^(podman run|ip )' "$SHIM_LOG"
  run bash "$B/hps-ips-launch.sh" bogus
  [ "$status" -eq 2 ]
}
