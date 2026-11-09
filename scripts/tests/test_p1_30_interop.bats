#!/usr/bin/env bats
#
# Interop between the Bash registry (lib/hps-registry.sh) and the Perl one
# (lib/perl/HPS/Registry.pm): each reads what the other wrote, for a string,
# a number and a JSON object. Config lookups and logging are stubbed; the
# real json_registry / host_registry / system_registry functions run.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-30.XXXXXX")"
  ROOT="${BATS_TEST_DIRNAME}/../.."
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  mkdir -p "$HPS_CONFIG_BASE/clusters/lab/cluster.db" "$HPS_CONFIG_BASE/clusters/lab/hosts"

  hps_log() { :; }
  make_timestamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
  # Mirrors hps_get_config for the keys host_registry needs.
  hps_get_config() {
    case "$1" in
      config_base) echo "$HPS_CONFIG_BASE" ;;
      cluster_hosts) echo "$HPS_CONFIG_BASE/clusters/lab/hosts" ;;
      *) return 1 ;;
    esac
  }
  export -f hps_log make_timestamp hps_get_config

  source "$ROOT/lib/hps-registry.sh"
  source "$ROOT/lib/functions.d/network-functions.sh"

  MAC="52:54:00:aa:bb:cc"
  system_registry set ACTIVE_CLUSTER lab
}

teardown() {
  rm -rf "$TEST_DIR"
}

# perl_reg <perl-statement>: run against the same temp config base.
perl_reg() {
  perl -I"$ROOT/lib/perl" -MHPS::Registry -e '
    my $r = HPS::Registry->new;
    my $mac = shift;
    '"$1"'
  ' "$MAC"
}

@test "Perl resolves the active cluster written by Bash" {
  run perl_reg 'print $r->active_cluster'
  [ "$status" -eq 0 ]
  [ "$output" = "lab" ]
}

@test "Perl reads host values set by Bash: string, number, object" {
  host_registry "$MAC" set NAME "node one"
  host_registry "$MAC" set COUNT 42
  host_registry "$MAC" set OBJ '{"a":1,"b":["x","y"]}'

  run perl_reg 'print $r->host_get($mac, "NAME")'
  [ "$output" = "node one" ]
  run perl_reg 'print $r->host_get($mac, "COUNT")'
  [ "$output" = "42" ]
  run perl_reg 'print join ",", $r->host_get_json($mac, "OBJ")->{a}, @{ $r->host_get_json($mac, "OBJ")->{b} }'
  [ "$output" = "1,x,y" ]
  run perl_reg 'print $r->host_get($mac, "UPDATED")'
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:]{8}\ UTC$ ]]
}

@test "Bash reads host values set by Perl: string, number, object" {
  perl_reg '$r->host_set($mac, "NAME", "node two"); $r->host_set($mac, "COUNT", "7"); $r->host_set($mac, "OBJ", q({"a":1,"b":["x","y"]}))'

  run host_registry "$MAC" get NAME
  [ "$output" = "node two" ]
  run host_registry "$MAC" get COUNT
  [ "$output" = "7" ]
  run host_registry "$MAC" get OBJ
  [ "$status" -eq 0 ]
  run bash -c 'jq -c . <<<"$1"' _ "$output"
  [ "$output" = '{"a":1,"b":["x","y"]}' ]
  run host_registry "$MAC" exists UPDATED
  [ "$status" -eq 0 ]
  run host_registry list_all
  [ "$output" = "525400aabbcc" ]
}

@test "system scope interoperates both ways" {
  perl_reg '$r->system_set("PERL_KEY", "from perl")'
  run system_registry get PERL_KEY
  [ "$output" = "from perl" ]
  system_registry set BASH_KEY 3
  run perl_reg 'print $r->system_get("BASH_KEY")'
  [ "$output" = "3" ]
}

@test "Perl removes a dead-pid lock file written in the Bash format" {
  mkdir -p "$HPS_SYSTEM_REGISTRY/.lock"
  # A lock Bash would leave behind from a process that is gone.
  printf 'ts:1\npid:2147483000\nop:write\nhost:x\n' > "$HPS_SYSTEM_REGISTRY/.lock/K.lock"
  run perl_reg '$r->system_set("K", "v"); print $r->system_get("K")'
  [ "$output" = "v" ]
  [ ! -e "$HPS_SYSTEM_REGISTRY/.lock/K.lock" ]
}

@test "Bash takes over a lock file left by a finished Perl writer" {
  perl_reg '$r->system_set("K", "one")'
  [ ! -e "$HPS_SYSTEM_REGISTRY/.lock/K.lock" ]
  run system_registry set K two
  [ "$status" -eq 0 ]
  run perl_reg 'print $r->system_get("K")'
  [ "$output" = "two" ]
}
