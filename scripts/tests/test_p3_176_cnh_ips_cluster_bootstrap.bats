#!/usr/bin/env bats
#
# CS-3.11: cnh-ips-cluster-bootstrap - the inner IPS's cluster made on the CNH,
# in the IPS image, before its first start.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

IMG=localhost/hps-container:latest

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-176.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
  p3_171_mount "$I" "$HPS_CNH_ROOT/var/lib/containers/hps-ips"
  mkdir -p "$I/srv" "$I/hps-system/scripts"
  : > "$I/hps-system/scripts/cluster-bootstrap.sh"
  echo "$IMG" > "$STATE/images"
  export FAKE_ACTIVE_RC=3
}

teardown() {
  rm -rf "$TEST_DIR"
}

ARGS=(--name s1 --dhcp-iface ens4 --network 10.11.0.0/24 --ips-ip 10.11.0.1
  --dhcp-range 10.11.0.100-10.11.0.199 --static-range 10.11.0.10-10.11.0.99
  --dns-domain s1.hps --network-add mgmt:10.11.1.0/24:vlan=111:bridge=br-mgmt:purpose=workload
  --network-add storage-a:10.11.3.0/24:vlan=113:bridge=br-sa:purpose=storage
  --time-upstream "" --description "scale test cluster s1" --force)

@test "runs cluster-bootstrap.sh in the image, with the IPS mounts, through systemd-run" {
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CLUSTER-BOOTSTRAP done image=$IMG" ]
  line=$(grep '^systemd-run.* podman run' "$SHIM_LOG")
  [[ "$line" == "systemd-run --quiet --wait --pipe --collect -- podman run --rm --name hps-ips-cluster-bootstrap --replace"* ]]
  [[ "$line" == *"--privileged --cgroupns=host --network=host --hostname=ips --entrypoint bash"* ]]
  [[ "$line" == *"--volume $I/srv:/srv --volume $I/hps-system:/srv/hps-system --volume /sys/fs/cgroup:/sys/fs/cgroup:rw $IMG /srv/hps-system/scripts/cluster-bootstrap.sh --name s1 --dhcp-iface ens4 "* ]]
  [[ "$line" == *"--description scale test cluster s1 --force" ]]
}

@test "a running IPS is refused (3): stop it first" {
  FAKE_ACTIVE_RC=0 run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name s1
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-ips-stop"* ]]
  run ! grep -q 'podman run' "$SHIM_LOG"
}

@test "options outside the list and odd values are refused (3) before podman runs" {
  local v
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name s1 --entrypoint x
  [ "$status" -eq 3 ]
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name
  [ "$status" -eq 3 ]
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name ""
  [ "$status" -eq 3 ]
  for v in 's1;id' 's1$(id)' 's1`id`' "s1'x" 's1|x' 's1&x' 's1>x' 's1*'; do
    run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name "$v"
    [ "$status" -eq 3 ]
  done
  run ! grep -q 'podman run' "$SHIM_LOG"
}

@test "no disk, no tree or no image is refused (3)" {
  run bash "$S/cnh-ips-cluster-bootstrap" localhost/other:1 --name s1
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-image-load"* ]]
  rm -f "$I/hps-system/scripts/cluster-bootstrap.sh"
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name s1
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-ips-bootstrap"* ]]
  rm -f "$STATE/mounts"
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name s1
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-disk-prepare"* ]]
}

@test "a failing cluster-bootstrap.sh fails (1); usage errors exit 2" {
  cat > "$TEST_DIR/bin/podman" <<'SHIM'
#!/usr/bin/env bash
echo "podman $*" >> "$SHIM_LOG"
[[ "$1 $2" == "image exists" ]] && exit 0
exit 1
SHIM
  chmod +x "$TEST_DIR/bin/podman"
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG" --name s1
  [ "$status" -eq 1 ]
  run bash "$S/cnh-ips-cluster-bootstrap" "$IMG"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-cluster-bootstrap"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-cluster-bootstrap" --name s1
  [ "$status" -eq 2 ]
}
