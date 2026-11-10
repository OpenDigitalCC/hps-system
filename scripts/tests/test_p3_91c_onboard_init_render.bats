#!/usr/bin/env bats
#
# IPS-02 item 3: hps-onboard show prints an Init section (last boot time, pin,
# steps with rc, failed steps first, the previous boot); list --all marks
# hosts whose last init failed. Plain-JSON registry in a temp dir.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-91c.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export HPS_CONFIG_BASE="$TEST_DIR"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/system.db"
  export HPS_ONBOARD_NETCONF_CMD=""
  mkdir -p "$TEST_DIR/clusters/lab/cluster.db" "$TEST_DIR/clusters/lab/hosts"
  cat > "$TEST_DIR/seed.pl" <<'PL'
use strict; use warnings;
use lib "$ENV{ROOT}/lib/perl";
use HPS::Registry;
my $r = HPS::Registry->new;
$r->system_set('ACTIVE_CLUSTER', 'lab');
my $bad = { boot_id => 'boot-2', pin => 'pin-7', started_at => '2026-11-10T10:00:00Z', finished_at => '2026-11-10T10:00:09Z',
  steps => [ { name => 'n_ok_one', rc => 0, seconds => 1, message => '' },
             { name => 'n_set_hostname_and_hosts', rc => 1, seconds => 2, message => "line a\nHTTP 403 for command: host_variable" },
             { name => 'n_ok_two', rc => 0, seconds => 0, message => '' } ] };
my $good = { boot_id => 'boot-1', pin => 'pin-6', started_at => '2026-11-09T10:00:00Z', finished_at => '2026-11-09T10:00:05Z',
  steps => [ { name => 'n_ok_one', rc => 0, seconds => 1, message => '' } ] };
$r->host_set('52:54:00:00:00:01', 'STATE', 'INSTALLED');
$r->host_set('52:54:00:00:00:01', 'init_result', $bad);
$r->host_set('52:54:00:00:00:01', 'init_result_prev', $good);
$r->host_set('52:54:00:00:00:01', 'init_ok', 'false');
$r->host_set('52:54:00:00:00:02', 'STATE', 'INSTALLED');
$r->host_set('52:54:00:00:00:02', 'init_result', $good);
$r->host_set('52:54:00:00:00:02', 'init_ok', 'true');
$r->host_set('52:54:00:00:00:03', 'STATE', 'HELD');
PL
  ROOT="$ROOT" perl "$TEST_DIR/seed.pl"
}

teardown() {
  rm -rf "$TEST_DIR"
}

onboard() { perl -I"$ROOT/lib/perl" "$ROOT/bin/hps-onboard" "$@"; }

@test "show prints the Init section with the failed step first" {
  run onboard show 52:54:00:00:00:01
  [ "$status" -eq 0 ]
  [[ "$output" == *"Init"* ]]
  [[ "$output" == *"Last boot: 1 of 3 steps FAILED, finished 2026-11-10T10:00:09Z, pin pin-7, boot boot-2"* ]]
  [[ "$output" == *"Previous boot: all 1 steps ok, finished 2026-11-09T10:00:05Z, pin pin-6"* ]]
  [[ "$output" == *"HTTP 403 for command: host_variable"* ]]
  local failed_line ok_line
  failed_line=$(printf '%s\n' "$output" | grep -n "FAILED  *rc=1 .*n_set_hostname_and_hosts" | head -1 | cut -d: -f1)
  ok_line=$(printf '%s\n' "$output" | grep -n "ok  *rc=0 .*n_ok_one" | head -1 | cut -d: -f1)
  [ -n "$failed_line" ]
  [ -n "$ok_line" ]
  [ "$failed_line" -lt "$ok_line" ]
}

@test "show keeps the raw init results out of the identity dump" {
  run onboard show 52:54:00:00:00:01
  [[ "$output" != *"init_result"* ]]
}

@test "show --json carries init, init_prev and init_ok" {
  run onboard show 52:54:00:00:00:01 --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.init.steps[1].rc')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.init_prev.boot_id')" = "boot-1" ]
  [ "$(printf '%s' "$output" | jq -r '.init_ok')" = "false" ]
}

@test "show for a host with no init result says so" {
  run onboard show 52:54:00:00:00:03
  [ "$status" -eq 0 ]
  [[ "$output" == *"No init result reported by this host."* ]]
}

@test "list --all marks the host whose last init failed" {
  run onboard list --all
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '525400000001 .*FAILED'
  printf '%s\n' "$output" | grep -q '525400000002 .* ok '
  printf '%s\n' "$output" | grep -q '525400000003 .* - '
  [[ "$output" != *"525400000002 "*FAILED* ]]
}

@test "list --all --json" {
  run onboard list --all --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.init_ok == "false")] | length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" -eq 3 ]
}

@test "list without --all is unchanged: held hosts only" {
  run onboard list
  [ "$status" -eq 0 ]
  [[ "$output" == *"525400000003"* ]]
  [[ "$output" != *"525400000001"* ]]
}
