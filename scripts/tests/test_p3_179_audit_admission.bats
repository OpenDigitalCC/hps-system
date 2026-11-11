#!/usr/bin/env bats
#
# IPS-16: audits start only when there is room for them. Real registry in a
# temp directory (as test_p3_162); the boot-script emitters of the audit image
# and the roles are the real ones, only the pairing window is stubbed.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-179.XXXXXX")"
  export TEST_DIR
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  export HPS_AUDIT_LOCK="$TEST_DIR/audit.lock"
  HOSTS="$TEST_DIR/cfg/clusters/lab/hosts"
  export HOSTS
  mkdir -p "$HOSTS" "$TEST_DIR/cfg/ck" "$TEST_DIR/res/nixos/pin1/audit" "$TEST_DIR/res/nixos/pin1/node-base"
  export HPS_LOG="$TEST_DIR/hps.log"
  : > "$HPS_LOG"
  hps_log() { echo "$*" >> "$HPS_LOG"; }
  cgi_header_plain() { printf 'Content-Type: text/plain\n\n'; }
  cgi_fail() { cgi_header_plain; printf '%s' "$1"; }
  cgi_success() { cgi_header_plain; printf '%s' "$1"; }
  cgi_auto_fail() { cgi_header_plain; printf 'FAIL: %s\n' "$1"; }
  make_timestamp() { echo "2026-11-11 12:00:00 UTC"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      cluster_hosts)  echo "$HOSTS" ;;
      config_base)    echo "$TEST_DIR/cfg" ;;
      resources)      echo "$TEST_DIR/res" ;;
      *) return 1 ;;
    esac
  }
  export -f hps_log cgi_header_plain cgi_fail cgi_success cgi_auto_fail make_timestamp hps_get_config
  # shellcheck disable=SC1091
  source "$ROOT/lib/hps-registry.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  cluster_registry() {
    [[ "$2" == get && -f "$TEST_DIR/cfg/ck/$3" ]] || return 1
    cat "$TEST_DIR/cfg/ck/$3"
  }
  list_cluster_hosts() { host_registry list_all; }
  nixos_open_pairing_window() { :; }
  ipxe_network_boot() { echo "network-boot $1"; }
  local p
  for p in audit node-base; do
    printf '{"kernel":"bzImage","initrd":"initrd","init":"/x/init","cmdline":"console=ttyS0","profile":"%s","pin":"pin1"}\n' "$p" \
      > "$TEST_DIR/res/nixos/pin1/$p/boot.json"
  done
  printf 'pin1' > "$TEST_DIR/cfg/ck/nixos_default_pin"
  printf '10.0.0.1' > "$TEST_DIR/cfg/ck/network_dhcp_ip"
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH
  NOW="$(date +%s)"
  H1=52:54:00:00:00:01
  H2=52:54:00:00:00:02
  H3=52:54:00:00:00:03
  H4=52:54:00:00:00:04
  # first seen in this order, a minute apart
  mk_held "$H1" $((NOW - 300))
  mk_held "$H2" $((NOW - 240))
  mk_held "$H3" $((NOW - 180))
}

teardown() {
  rm -rf "$TEST_DIR"
}

# mk_held <mac> <first-seen epoch>
mk_held() {
  host_registry "$1" set STATE HELD
  host_registry "$1" set initialised_at "$(date -Iseconds -d "@$2")"
  host_registry "$1" set last_boot_at "$(date +%s)"
}

# poll <mac>: the host asks the IPS for its boot script
poll() {
  run ipxe_init_handler "$1"
  [ "$status" -eq 0 ]
}

got_audit() { [[ "$output" == *"/audit/bzImage"* ]]; }
got_hold()  { [[ "$output" == *"is held; waiting for an audit slot"* && "$output" != *"/audit/bzImage"* ]]; }

store_audit() {
  run host_audit_intake "$1" <<< '{"schema":"hps-audit/1"}'
  [ "$status" -eq 0 ]
}

@test "limit 2, three held hosts with no audit: two get the audit image, the third the hold script" {
  poll "$H1"; got_audit
  poll "$H2"; got_audit
  poll "$H3"; got_hold
  [[ "$output" == *"HPS: $H3 is held; waiting for an audit slot (2 running, retry in 30 s)"* ]]
  [[ "$output" == *$'\nsleep 30\n'* ]]
  [[ "$output" == *"chain --replace"* ]]
}

@test "when one audit is stored the third host is admitted" {
  poll "$H1"; got_audit
  poll "$H2"; got_audit
  poll "$H3"; got_hold
  store_audit "$H1"
  poll "$H3"; got_audit
}

@test "audit_started_at is set on admission and cleared when the audit is stored" {
  poll "$H1"; got_audit
  run host_registry "$H1" get audit_started_at
  [[ "$output" =~ ^[0-9]+$ ]]
  store_audit "$H1"
  run host_registry "$H1" exists audit_started_at
  [ "$status" -ne 0 ]
}

@test "the default limit is 2 and the retry interval of the message is hold_retry_seconds" {
  printf '45' > "$TEST_DIR/cfg/ck/hold_retry_seconds"
  poll "$H1"; poll "$H2"; poll "$H3"
  [[ "$output" == *"(2 running, retry in 45 s)"* ]]
  [[ "$output" == *$'\nsleep 45\n'* ]]
}

@test "a limit of 1 holds the second host" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  poll "$H2"; got_hold
  [[ "$output" == *"(1 running,"* ]]
}

@test "a limit of 0 means no limit" {
  printf '0' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  mk_held "$H4" $((NOW - 60))
  poll "$H1"; got_audit
  poll "$H2"; got_audit
  poll "$H3"; got_audit
  poll "$H4"; got_audit
}

@test "an assigned host is never held, however many audits run" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  host_registry "$H4" set STATE NETWORK_BOOT
  host_registry "$H4" set audit '{"schema":"hps-audit/1"}'
  poll "$H4"
  [ "$output" = "network-boot $H4" ]
}

@test "a timed-out audit frees its slot" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  host_registry "$H1" set audit_started_at $((NOW - 899))
  poll "$H2"; got_hold
  host_registry "$H1" set audit_started_at $((NOW - 901))
  host_registry "$H1" set last_boot_at $((NOW - 3600))   # a timed-out host that went away
  poll "$H2"; got_audit
}

@test "audit_timeout_seconds sets the timeout" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  printf '60' > "$TEST_DIR/cfg/ck/audit_timeout_seconds"
  poll "$H1"; got_audit
  host_registry "$H1" set audit_started_at $((NOW - 59))
  poll "$H2"; got_hold
  host_registry "$H1" set audit_started_at $((NOW - 61))
  host_registry "$H1" set last_boot_at $((NOW - 3600))
  poll "$H2"; got_audit
}

@test "first seen, first audited: a later host does not overtake an earlier one that is waiting" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  poll "$H2"; got_hold
  poll "$H3"; got_hold
  store_audit "$H1"
  poll "$H3"; got_hold      # H2 is older and still asking
  poll "$H2"; got_audit
  poll "$H3"; got_hold
}

@test "the order is by first seen, not by MAC" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  # H4 has the highest MAC but was seen before all of them
  mk_held "$H4" $((NOW - 1000))
  poll "$H1"; got_hold
  poll "$H4"; got_audit
  store_audit "$H4"
  poll "$H2"; got_hold      # H1 is older
  poll "$H1"; got_audit
}

@test "a waiting host that stopped asking does not hold a slot back" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  host_registry "$H2" set last_boot_at $((NOW - 3600))
  store_audit "$H1"
  poll "$H3"; got_audit
}

@test "a host asking again while its audit runs is served again and takes no second slot" {
  poll "$H1"; got_audit
  first="$(host_registry "$H1" get audit_started_at)"
  poll "$H1"; got_audit
  [ "$(host_registry "$H1" get audit_started_at)" = "$first" ]
  poll "$H2"; got_audit
  poll "$H3"; got_hold
  [[ "$output" == *"(2 running,"* ]]
}

@test "hps-onboard reaudit: a stale audit queues like a new one" {
  printf '1' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  poll "$H1"; got_audit
  store_audit "$H1"
  poll "$H2"; got_audit
  host_registry "$H1" set audit_stale true
  poll "$H1"; got_hold
  store_audit "$H2"
  poll "$H1"; got_audit
}

@test "a host with its audit stored still gets the role-wait hold script, not the slot message" {
  host_registry "$H1" set audit '{"schema":"hps-audit/1"}'
  poll "$H1"
  [[ "$output" == *"waiting for a role (retry in 30 s)"* ]]
  [[ "$output" != *"audit slot"* ]]
}

@test "admissions are logged at info" {
  poll "$H1"
  grep -q "^info \[$H1\] audit admitted" "$HPS_LOG"
}

@test "an audit image that cannot be served frees the slot taken for it" {
  rm -f "$TEST_DIR/res/nixos/pin1/audit/boot.json"
  run ipxe_init_handler "$H1"
  run host_registry "$H1" exists audit_started_at
  [ "$status" -ne 0 ]
}

@test "invalid limits fall back to the defaults and are logged" {
  local bad
  for bad in abc -1 1001 1.5 ""; do
    printf '%s' "$bad" > "$TEST_DIR/cfg/ck/audit_max_concurrent"
    run ipxe_audit_max_concurrent
    [ "$output" = "2" ]
  done
  printf 'abc' > "$TEST_DIR/cfg/ck/audit_max_concurrent"
  run ipxe_audit_max_concurrent
  grep -q "warn cluster key audit_max_concurrent='abc'" "$HPS_LOG"
  for bad in abc 29 86401 -5; do
    printf '%s' "$bad" > "$TEST_DIR/cfg/ck/audit_timeout_seconds"
    run ipxe_audit_timeout_seconds
    [ "$output" = "900" ]
  done
}

@test "the keys are catalogued with their defaults and limits" {
  run perl -I "$ROOT/lib/perl" -MHPS::ClusterConfig -MHPS::Registry::Keys -e '
    my $m = HPS::ClusterConfig::question("audit_max_concurrent") or die "no max";
    my $t = HPS::ClusterConfig::question("audit_timeout_seconds") or die "no timeout";
    die "default" unless $m->{default} eq "2" && $t->{default} eq "900";
    for my $v (0, 2, 1000) { my $e = HPS::ClusterConfig::validate_value($m, $v); die "reject $v: $e" if defined $e }
    for my $v (-1, 1001, "x") { die "accept $v" unless defined HPS::ClusterConfig::validate_value($m, $v) }
    print HPS::Registry::Keys::type_of("host", "audit_started_at"), "\n";
  '
  [ "$status" -eq 0 ]
  [ "$output" = "epoch" ]
}
