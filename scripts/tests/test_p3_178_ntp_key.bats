#!/usr/bin/env bats
#
# The cluster's NTP server is one key, network_time_server (Registry/Keys.pm).
# 2026-11-11 (doc review D13): the configure menu read NTP_SERVER but wrote
# network_time_server, so it always showed the fallback and "keep current"
# overwrote the configured value; the Alpine node path read NTP_SERVER too.

bats_require_minimum_version 1.5.0

@test "the configure menu reads the key it writes" {
  f="$BATS_TEST_DIRNAME/../../scripts/cluster-config.d/070-system-services.sh"
  grep -q 'current_ntp=$(config_get_value "network_time_server"' "$f"
  run ! grep -n '"NTP_SERVER"' "$f"
}

@test "the Alpine node reads network_time_server" {
  f="$BATS_TEST_DIRNAME/../../node-manager/alpine-3/alpine-lib-functions.sh"
  grep -q 'n_remote_cluster_variable network_time_server' "$f"
  run ! grep -n 'n_remote_cluster_variable NTP_SERVER' "$f"
}
