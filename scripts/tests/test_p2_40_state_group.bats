#!/usr/bin/env bats
#
# CS-2.0d: one group (hps) owns the IPS state, so the web user can write the
# registry that root-run CLIs created. The group switch itself needs root and
# the hps group, neither available here; these tests prove the mechanism the
# switch relies on: umask 002, setgid group-writable directories, the
# pre-start permission pass, and the keysafe exception.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-40.XXXXXX")"
  mkdir -p "$T/shim"
  printf '#!/usr/bin/env bash\ntrue\n' > "$T/shim/supervisord"
  cp "$T/shim/supervisord" "$T/shim/supervisorctl"
  chmod +x "$T/shim/supervisord" "$T/shim/supervisorctl"
  export PATH="$T/shim:$PATH"
}

teardown() {
  rm -rf "$T"
}

# Run a snippet with the state helpers and a quiet hps_log loaded.
in_state() {
  run bash -c 'hps_log() { echo "[$1] ${*:2}" >&2; }; source "$1/lib/hps-state.sh"; source "$1/lib/functions.d/supervisor-functions.sh"; shift; eval "$@"' _ "$ROOT" "$@"
}

@test "hps_system_initialize leaves umask 0002 in effect" {
  run bash -c '
    export HPS_BASE="$1/base" HPS_SYSTEM_PATH="$2"
    umask 022
    source "$2/lib/hps-system.sh"
    hps_system_initialize >/dev/null 2>&1
    umask' _ "$T" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "0002" ]
}

@test "hps_system_initialize creates the base directories setgid and group-writable" {
  run bash -c '
    export HPS_BASE="$1/base" HPS_SYSTEM_PATH="$2"
    umask 022
    source "$2/lib/hps-system.sh"
    hps_system_initialize >/dev/null 2>&1
    stat -c "%A" "$1/base/hps-config" "$1/base/hps-config/system.db" "$1/base/hps-config/system.db/.lock"' _ "$T" "$ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "drwxrwsr-x" ]
  [ "${lines[1]}" = "drwxrwsr-x" ]
  [ "${lines[2]}" = "drwxrwsr-x" ]
}

@test "json_registry set creates group-writable files and setgid directories" {
  run bash -c '
    export HPS_BASE="$1/base" HPS_SYSTEM_PATH="$2"
    umask 077
    source "$2/lib/hps-system.sh"
    hps_system_initialize >/dev/null 2>&1
    source "$2/lib/functions.sh" >/dev/null 2>&1
    json_registry "$1/base/hps-config/hosts/aa.db" set last_boot_at "\"x\""
    stat -c "%A" "$1/base/hps-config/hosts/aa.db" "$1/base/hps-config/hosts/aa.db/.lock" "$1/base/hps-config/hosts/aa.db/last_boot_at.json"' _ "$T" "$ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "drwxrwsr-x" ]
  [ "${lines[1]}" = "drwxrwsr-x" ]
  [ "${lines[2]}" = "-rw-rw-r--" ]
}

@test "loading functions.sh alone (the CGI path) sets umask 0002" {
  run bash -c '
    export HPS_BASE="$1/base" HPS_SYSTEM_PATH="$2"
    source "$2/lib/hps-system.sh"
    hps_system_initialize >/dev/null 2>&1
    umask 077
    source "$2/lib/functions.sh" >/dev/null 2>&1
    umask' _ "$T" "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "0002" ]
}

@test "hps_state_mkdir makes every created ancestor setgid and leaves existing ones" {
  mkdir -p "$T/top"
  chmod 755 "$T/top"
  in_state "umask 002; hps_state_mkdir '$T/top/a/b/c'; stat -c '%A' '$T/top' '$T/top/a' '$T/top/a/b' '$T/top/a/b/c'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "drwxr-xr-x" ]
  [ "${lines[1]}" = "drwxrwsr-x" ]
  [ "${lines[3]}" = "drwxrwsr-x" ]
}

@test "the pre-start pass makes a root-style tree group-writable with setgid directories" {
  mkdir -p "$T/cfg/clusters/lab/hosts/aa.db/.lock" "$T/log/supervisor"
  : > "$T/cfg/clusters/lab/hosts/aa.db/x.json"
  : > "$T/log/supervisor/a.log"
  chmod 755 "$T/cfg" "$T/cfg/clusters" "$T/cfg/clusters/lab/hosts/aa.db" "$T/log"
  chmod 644 "$T/cfg/clusters/lab/hosts/aa.db/x.json" "$T/log/supervisor/a.log"
  in_state "HPS_CONFIG_BASE='$T/cfg' HPS_LOG='$T/log' supervisor_fix_state_permissions"
  [ "$status" -eq 0 ]
  [[ "$output" == *"path(s) checked"* ]]
  run stat -c '%A' "$T/cfg" "$T/cfg/clusters/lab/hosts/aa.db/.lock" "$T/cfg/clusters/lab/hosts/aa.db/x.json" "$T/log/supervisor" "$T/log/supervisor/a.log"
  [ "${lines[0]}" = "drwxrwsr-x" ]
  [ "${lines[1]}" = "drwxrwsr-x" ]
  [ "${lines[2]}" = "-rw-rw-r--" ]
  [ "${lines[3]}" = "drwxrwsr-x" ]
  [ "${lines[4]}" = "-rw-rw-r--" ]
}

@test "the pre-start pass skips keysafe" {
  mkdir -p "$T/cfg/clusters/lab/keysafe/tokens" "$T/log"
  : > "$T/cfg/clusters/lab/keysafe/tokens/t1"
  chmod 700 "$T/cfg/clusters/lab/keysafe" "$T/cfg/clusters/lab/keysafe/tokens"
  chmod 600 "$T/cfg/clusters/lab/keysafe/tokens/t1"
  in_state "HPS_CONFIG_BASE='$T/cfg' HPS_LOG='$T/log' supervisor_fix_state_permissions"
  [ "$status" -eq 0 ]
  run stat -c '%A' "$T/cfg/clusters/lab/keysafe" "$T/cfg/clusters/lab/keysafe/tokens" "$T/cfg/clusters/lab/keysafe/tokens/t1"
  [ "${lines[0]}" = "drwx------" ]
  [ "${lines[1]}" = "drwx------" ]
  [ "${lines[2]}" = "-rw-------" ]
}

@test "the pre-start pass is idempotent" {
  mkdir -p "$T/cfg/a" "$T/log"
  in_state "HPS_CONFIG_BASE='$T/cfg' HPS_LOG='$T/log' supervisor_fix_state_permissions; supervisor_fix_state_permissions; stat -c '%A' '$T/cfg/a'"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "drwxrwsr-x" ]
}

@test "the pre-start pass refuses / and empty variables and changes nothing" {
  mkdir -p "$T/cfg"
  chmod 755 "$T/cfg"
  in_state "HPS_CONFIG_BASE=/ HPS_LOG='$T/cfg' supervisor_fix_state_permissions"
  [ "$status" -eq 1 ]
  in_state "HPS_CONFIG_BASE='$T/cfg' HPS_LOG='' supervisor_fix_state_permissions"
  [ "$status" -eq 1 ]
  in_state "unset HPS_CONFIG_BASE; HPS_LOG='$T/cfg' supervisor_fix_state_permissions"
  [ "$status" -eq 1 ]
  [ "$(stat -c %A "$T/cfg")" = "drwxr-xr-x" ]
}

@test "pre-start runs the permission pass after preparing services and before the reload" {
  run grep -nE '^  supervisor_(prepare_services|fix_state_permissions|reload_core_config)$' "$ROOT/lib/functions.d/supervisor-functions.sh"
  [ "${lines[0]#*:}" = "  supervisor_prepare_services" ]
  [ "${lines[1]#*:}" = "  supervisor_fix_state_permissions" ]
  [ "${lines[2]#*:}" = "  supervisor_reload_core_config" ]
}

@test "keysafe directories are created 0700 by a private umask and named in a comment" {
  grep -q 'umask 077 && mkdir -p "$keysafe_dir/tokens"' "$ROOT/lib/functions.d/keysafe-functions.sh"
  grep -q 'root-only' "$ROOT/lib/functions.d/keysafe-functions.sh"
}

@test "the Dockerfile creates group hps and adds www-data to it" {
  DF="$ROOT/../../../hps-container/Dockerfile"
  [ -f "$DF" ] || skip "hps-container not beside the worktree"
  grep -qE 'groupadd -r hps' "$DF"
  grep -qE 'usermod -aG hps www-data' "$DF"
}

@test "lighttpd keeps www-data as primary group" {
  grep -q 'server.groupname *= "www-data"' "$ROOT/lib/functions.d/create-config-lighttpd.sh"
}

@test "SECURITY.md has the state ownership paragraph" {
  grep -q 'State ownership' "$ROOT/docs/SECURITY.md"
}
