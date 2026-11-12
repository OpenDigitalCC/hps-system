#!/usr/bin/env bats
#
# ips-admin: the agent scripts of the IPS's own ctrl-exec agent
# (ips-admin/<tool> -> ips-admin/ips-admin-exec). Arguments pass through to the
# tool only as conservative tokens; stdin reaches a tool only for the two
# input=raw scripts; every call is logged. The tools are shims in a fake HPS
# tree named by hps.conf; logger is a shim.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-190.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export ROOT
  W="$ROOT/ips-admin"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  export HPS_BASE="$TEST_DIR"
  printf 'HPS_SYSTEM_BASE=%s\nHPS_CONFIG_BASE=%s/config\n' "$TEST_DIR/sys" "$TEST_DIR" > "$TEST_DIR/hps.conf"
  for t in hps-onboard hps-cluster-config hps-bmc hps-node hps-storage hps-workload hps-pins \
    hps-ips-check hps-osvc hps-monitor hps-syslog-forward; do
    cat > "$TEST_DIR/sys/bin/$t" <<'EOT'
#!/bin/bash
echo "tool=${0##*/} args=$*"
echo "stdin=[$(cat)]"
echo "cwd=$PWD"
echo "config=${HPS_CONFIG_BASE:-unset}"
exit "${FAKE_RC:-0}"
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

@test "a wrapper passes its arguments through to its tool and returns its output" {
  run "$W/hps-onboard" list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-onboard args=list --json"* ]]
  [[ "$output" == *"config=$TEST_DIR/config"* ]]
}

@test "the tool's exit status is the script's" {
  FAKE_RC=3 run "$W/hps-node" status tch-001
  [ "$status" -eq 3 ]
  [[ "$output" == *"tool=hps-node args=status tch-001"* ]]
}

@test "every wrapper reaches its own tool" {
  run "$W/hps-cluster-config" show
  [[ "$output" == *"tool=hps-cluster-config args=show"* ]]
  run "$W/hps-storage" status
  [[ "$output" == *"tool=hps-storage args=status"* ]]
  run "$W/hps-workload" list
  [[ "$output" == *"tool=hps-workload args=list"* ]]
  run "$W/hps-pins" list
  [[ "$output" == *"tool=hps-pins args=list"* ]]
  run "$W/hps-ips-check" --json
  [[ "$output" == *"tool=hps-ips-check args=--json"* ]]
  run "$W/hps-osvc" deliver tch-001
  [[ "$output" == *"tool=hps-osvc args=deliver tch-001"* ]]
  run "$W/ips-syslog-forward" 192.0.2.10 s1
  [[ "$output" == *"tool=hps-syslog-forward args=192.0.2.10 s1"* ]]
}

@test "shell metacharacters, spaces, quotes, newlines and empty arguments are refused" {
  for a in 'a;b' '$(id)' '`id`' 'a b' 'a|b' 'a&b' "a'b" 'a"b' $'a\nb' '' '>x' '<x' '*' 'a\b' '~root' '#x' '!x' 'a{b}'; do
    run "$W/hps-onboard" list "$a"
    [ "$status" -eq 2 ] || { echo "accepted: [$a]"; false; }
    [[ "$output" != *"tool="* ]]
  done
}

@test "no argument can name a file: '/' only in an IPv4 CIDR, '..' never" {
  for a in /etc/shadow etc/shadow ./x a..b ../x http://x/y 10.0.0.1/24/x; do
    run "$W/hps-cluster-config" apply "$a"
    [ "$status" -eq 2 ] || { echo "accepted: [$a]"; false; }
  done
  run "$W/hps-cluster-config" set network_dhcp_cidr 10.0.0.1/24
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=set network_dhcp_cidr 10.0.0.1/24"* ]]
}

@test "options, MACs, k=v and host names pass" {
  run "$W/hps-bmc" set aa:bb:cc:dd:ee:01 --driver ipmi --addr 10.0.0.9 --option user=admin
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=set aa:bb:cc:dd:ee:01 --driver ipmi --addr 10.0.0.9 --option user=admin"* ]]
}

@test "more than 64 arguments are refused" {
  args=()
  for i in $(seq 1 65); do args+=("a$i"); done
  run "$W/hps-onboard" "${args[@]}"
  [ "$status" -eq 2 ]
}

@test "a tool never reads the request context: its stdin is /dev/null" {
  run bash -c "printf '{\"token\":\"hpsop_secret\"}' | '$W/hps-node' list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stdin=[]"* ]]
}

@test "hps-bmc-credential gives the confidential input to hps-bmc credential on stdin, never to the log" {
  run bash -c "printf 'admin\nS3cret-pw\n' | '$W/hps-bmc-credential' aa:bb:cc:dd:ee:01"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-bmc args=credential aa:bb:cc:dd:ee:01"* ]]
  [[ "$output" == *"S3cret-pw"* ]]
  run ! grep -q 'S3cret-pw' "$TEST_DIR/syslog"
}

@test "hps-bmc is narrowed to status, list, set and select" {
  for s in status list set select; do
    run "$W/hps-bmc" "$s" tch-001
    [ "$status" -eq 0 ]
  done
  for s in on off force-off reset pxe-once console credential device ''; do
    run "$W/hps-bmc" "$s" tch-001
    [ "$status" -eq 2 ] || { echo "accepted: [$s]"; false; }
  done
}

@test "hps-monitor is narrowed to run" {
  run "$W/hps-monitor" run --host tch-001
  [ "$status" -eq 0 ]
  run "$W/hps-monitor" loop
  [ "$status" -eq 2 ]
}

@test "hps-cluster-config-apply applies its input with apply -, and takes only --dry-run and --json" {
  run bash -c "printf 'network_dns_domain = s1.hps\n' | '$W/hps-cluster-config-apply' --dry-run"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-cluster-config args=apply - --dry-run"* ]]
  [[ "$output" == *"network_dns_domain = s1.hps"* ]]
  run "$W/hps-cluster-config-apply" /etc/x
  [ "$status" -eq 2 ]
  run "$W/hps-cluster-config-apply" --cluster other
  [ "$status" -eq 2 ]
}

@test "an unknown or missing tool is refused" {
  run "$W/ips-admin-exec" bash -c id
  [ "$status" -eq 2 ]
  run "$W/ips-admin-exec"
  [ "$status" -eq 2 ]
  rm "$TEST_DIR/sys/bin/hps-pins"
  run "$W/hps-pins" list
  [ "$status" -eq 2 ]
}

@test "each call is logged before and after, with tool, arguments and exit" {
  FAKE_RC=4 run "$W/hps-node" status tch-002
  grep -q 'ips-admin.*run tool=hps-node args=status tch-002' "$TEST_DIR/syslog"
  grep -q 'ips-admin.*end tool=hps-node exit=4' "$TEST_DIR/syslog"
  run "$W/hps-node" 'a;b'
  grep -q 'ips-admin.*refused tool=hps-node' "$TEST_DIR/syslog"
}

@test "the tool runs in an empty private directory that is removed after" {
  run "$W/hps-node" list
  dir=$(printf '%s\n' "$output" | sed -n 's/^cwd=//p')
  [[ "$dir" == /tmp/ips-admin.* ]]
  [ ! -e "$dir" ]
}

@test "every allowlisted ips-admin name has an executable wrapper, and nothing else is in ips-admin/" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [ "${#IPS_ADMIN_SCRIPTS[@]}" -eq 17 ]
  for s in "${IPS_ADMIN_SCRIPTS[@]}"; do
    [ -x "$W/$s" ] || { echo "no wrapper: $s"; false; }
    grep -qx "exec \"\${0%/\*}/ips-admin-exec\" $s \"\$@\"" "$W/$s"
  done
  n=$(find "$W" -maxdepth 1 -type f | wc -l)
  [ "$n" -eq $(( ${#IPS_ADMIN_SCRIPTS[@]} + 1 )) ]
}
