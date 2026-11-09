#!/usr/bin/env bats
#
# CS-2.0a: lighttpd replaced nginx + fcgiwrap; no trace remains in the code.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "no web-server shim names remain in lib, scripts, http, or LOGGING.md" {
  run grep -rIniE 'ngin[x]|fcgiwra[p]|spawn-fcg[i]' \
    "$ROOT/lib" "$ROOT/scripts" "$ROOT/http" "$ROOT/docs/LOGGING.md" \
    --exclude=test_p2_00_no_nginx.bats
  [ "$status" -eq 1 ]
}

@test "the Dockerfile installs lighttpd and none of the old packages" {
  [ -f "$ROOT/../../../hps-container/Dockerfile" ] || skip "hps-container not beside the worktree"
  run grep -iE 'ngin[x]|fcgiwra[p]|spawn-fcg[i]' "$ROOT/../../../hps-container/Dockerfile"
  [ "$status" -eq 1 ]
  grep -qE '^\s+lighttpd \\$' "$ROOT/../../../hps-container/Dockerfile"
}

@test "supervisor_prepare_services calls the lighttpd generator" {
  grep -qx '  create_config_lighttpd' "$ROOT/lib/functions.d/supervisor-functions.sh"
}
