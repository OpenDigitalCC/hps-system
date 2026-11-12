#!/usr/bin/env bats
#
# ips-admin: hps-storage takes a dataset argument in exactly the forms
# hps-storage itself validates (<pool>/enc, <pool>/enc/<name>,
# <pool>/enc/vm/<name>), nothing broader and for no other tool; and
# hps-workload-define maps to `hps-workload define <name>` with the definition
# as its input (input=raw), like hps-cluster-config-apply. The tools are shims
# in a fake HPS tree named by hps.conf; logger is a shim.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-200.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export ROOT
  W="$ROOT/ips-admin"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  export HPS_BASE="$TEST_DIR"
  printf 'HPS_SYSTEM_BASE=%s\nHPS_CONFIG_BASE=%s/config\n' "$TEST_DIR/sys" "$TEST_DIR" > "$TEST_DIR/hps.conf"
  for t in hps-storage hps-workload hps-node hps-cluster-config; do
    cat > "$TEST_DIR/sys/bin/$t" <<'EOT'
#!/bin/bash
echo "tool=${0##*/} args=$*"
echo "stdin=[$(cat)]"
EOT
    chmod +x "$TEST_DIR/sys/bin/$t"
  done
  cat > "$TEST_DIR/bin/logger" <<'EOT'
#!/bin/bash
echo "$*" >> "$TEST_DIR/syslog"
EOT
  chmod +x "$TEST_DIR/bin/logger"
  export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "hps-storage takes the dataset forms <pool>/enc, <pool>/enc/<name> and <pool>/enc/vm/<name>" {
  run "$W/hps-storage" sch-001 zvol-create s1/enc/vm/probe-a 1G
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-storage args=sch-001 zvol-create s1/enc/vm/probe-a 1G"* ]]
  run "$W/hps-storage" sch-001 export s1/enc/vm/probe-a --iqn iqn.2026-01.lab.s1:probe-a \
    --initiator iqn.2026-01.lab.s1:host-b --portal 10.113.0.10
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=sch-001 export s1/enc/vm/probe-a --iqn iqn.2026-01.lab.s1:probe-a --initiator iqn.2026-01.lab.s1:host-b --portal 10.113.0.10"* ]]
  run "$W/hps-storage" sch-001 unexport iqn.2026-01.lab.s1:probe-a
  [ "$status" -eq 0 ]
  run "$W/hps-storage" sch-001 zvol-destroy s1/enc/vm/probe-a
  [ "$status" -eq 0 ]
  for a in s1/enc s1/enc/data s1/enc/vm a.b_c-d/enc/Probe_9-x lab/enc/vm/t0-t0-app-root; do
    run "$W/hps-storage" sch-001 zvol-destroy "$a"
    [ "$status" -eq 0 ] || { echo "refused: [$a]"; false; }
  done
  grep -q 'ips-admin.*run tool=hps-storage args=sch-001 zvol-destroy s1/enc/vm/probe-a' "$TEST_DIR/syslog"
}

@test "a slash outside those exact forms is refused for hps-storage" {
  for a in ../x /etc a//b pool/enc/../x pool/other/x /s1/enc/x s1/enc/ s1/enc/vm/ s1/enc/vm/a/b \
    s1/enc/a/b s1/enc/.x s1/enc/a.b s1/x/enc S1/enc/x 1s/enc/x s1/ENC/x s1/enc//x s1//enc \
    a../enc/x 's1/enc/x;id' 's1/enc/$(id)' 's1/enc/x y' 's1/enc/`id`' 's1/enc/x|y' $'s1/enc/x\ny' \
    's1/enc/x&' 's1/enc/x>y' 'a;b/enc/x'; do
    run "$W/hps-storage" sch-001 zvol-destroy "$a"
    [ "$status" -eq 2 ] || { echo "accepted: [$a]"; false; }
    [[ "$output" != *"tool="* ]]
  done
  long="s1/enc/$(printf 'a%.0s' $(seq 1 260))"
  run "$W/hps-storage" sch-001 zvol-destroy "$long"
  [ "$status" -eq 2 ]
  run "$W/hps-storage" sch-001 set network_dhcp_cidr 10.0.0.1/24
  [ "$status" -eq 0 ]
}

@test "the dataset forms are open to hps-storage only" {
  for t in hps-node hps-workload hps-cluster-config; do
    run "$W/$t" show s1/enc/vm/probe-a
    [ "$status" -eq 2 ] || { echo "accepted for $t"; false; }
  done
}

@test "the gate's dataset pattern is HPS::Storage's dataset pattern" {
  grep -qF 'my $DS_RE   = qr{^([a-z][a-z0-9_.-]*)/enc/(?:vm/)?([A-Za-z0-9_-]+)$};' "$ROOT/lib/perl/HPS/Storage.pm"
  grep -qF "DATASET_RE='^[a-z][a-z0-9_.-]*/enc(/(vm/)?[A-Za-z0-9_-]+)?\$'" "$W/ips-admin-exec"
}

@test "hps-workload-define gives its input to hps-workload define <name>, never to the log" {
  run bash -c "printf '{\"name\":\"w1\",\"secret\":\"Zz9-marker\"}' | '$W/hps-workload-define' w1 --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-workload args=define w1 --dry-run"* ]]
  [[ "$output" == *'Zz9-marker'* ]]
  run ! grep -q 'Zz9-marker' "$TEST_DIR/syslog"
  grep -q 'ips-admin.*run tool=hps-workload-define args=w1 --dry-run' "$TEST_DIR/syslog"
  run bash -c "printf '{}' | '$W/hps-workload-define' w1 --replace --json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=define w1 --replace --json"* ]]
}

@test "hps-workload-define takes one name and only --dry-run, --replace and --json" {
  for args in "" "w1 w2" "w1 --forget" "w1 --resume" "--dry-run" "w1 --cluster" "w1 -x"; do
    # shellcheck disable=SC2086  # word splitting of the argument list is the point
    run "$W/hps-workload-define" $args
    [ "$status" -eq 2 ] || { echo "accepted: [$args]"; false; }
    [[ "$output" != *"tool="* ]]
  done
  run "$W/hps-workload-define" ../w1
  [ "$status" -eq 2 ]
  run "$W/hps-workload-define" 'w1;id'
  [ "$status" -eq 2 ]
}

@test "hps-workload-define is allowlisted, input=raw, with its wrapper" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [[ " ${IPS_ADMIN_SCRIPTS[*]} " == *" hps-workload-define "* ]]
  [[ " ${IPS_ADMIN_RAW_SCRIPTS[*]} " == *" hps-workload-define "* ]]
  [ -x "$W/hps-workload-define" ]
  grep -qx 'exec "${0%/\*}/ips-admin-exec" hps-workload-define "$@"' "$W/hps-workload-define"
}

@test "plain hps-workload still reads no input: its stdin is /dev/null" {
  run bash -c "printf '{\"name\":\"w1\"}' | '$W/hps-workload' show-definition w1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=show-definition w1"* ]]
  [[ "$output" == *"stdin=[]"* ]]
}

@test "hps-storage zvol-grow and hps-workload grow-disk pass the gate with their dataset and plain arguments" {
  run "$W/hps-storage" sch-001 zvol-grow lab/enc/vm/s1-ips-s1-ips-d0 64G
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-storage args=sch-001 zvol-grow lab/enc/vm/s1-ips-s1-ips-d0 64G"* ]]
  run "$W/hps-storage" sch-001 zvol-grow lab/enc/vm/../x 64G
  [ "$status" -eq 2 ]
  run "$W/hps-workload" grow-disk s1-ips s1-ips d0 64G
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-workload args=grow-disk s1-ips s1-ips d0 64G"* ]]
}

@test "hps-storage vdev-online passes the gate with a pool and a plain by-id name; a path to the disk does not" {
  run "$W/hps-storage" sch-001 vdev-online s1 virtio-s1-sch-001-d3
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-storage args=sch-001 vdev-online s1 virtio-s1-sch-001-d3"* ]]
  run "$W/hps-storage" sch-001 vdev-online s1 ata-Samsung_SSD_860_EVO_1TB_S3Z9NB0K
  [ "$status" -eq 0 ]
  for a in /dev/disk/by-id/virtio-s1-sch-001-d3 ../virtio-x 'virtio-x;id' 'virtio x' virtio..x; do
    run "$W/hps-storage" sch-001 vdev-online s1 "$a"
    [ "$status" -eq 2 ] || { echo "accepted: [$a]"; false; }
    [[ "$output" != *"tool="* ]]
  done
}
