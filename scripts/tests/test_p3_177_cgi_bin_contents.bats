#!/usr/bin/env bats
#
# The IPS serves http/cgi-bin. Only boot_manager.sh belongs there (the node
# boot and init API). Removed 2026-11-11: cgi-env-test.sh (printed the CGI
# environment to any caller), create-config.sh and replace-config.sh (wrote
# host config files from request parameters, unauthenticated); none was used.

@test "http/cgi-bin holds boot_manager.sh and nothing else" {
  run ls -1 "$BATS_TEST_DIRNAME/../../http/cgi-bin"
  [ "$status" -eq 0 ]
  [ "$output" = "boot_manager.sh" ]
}
