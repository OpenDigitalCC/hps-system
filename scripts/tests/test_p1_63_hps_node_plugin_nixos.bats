#!/usr/bin/env bats
#
# CS-1.6 item 3: the hps-node plugin runs on NixOS. It uses
# `#!/usr/bin/env bash`, takes the bundle path from HPS_BOOTSTRAP_LIB, and when
# that is unset and the Alpine path is absent falls back to the bundle
# hps-node-init saved (/run/hps/functions.sh; HPS_RUN_FUNCTIONS in tests).

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-63.XXXXXX")"
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/node-manager/plugins/hps-node/hps-node.sh"
  unset HPS_BOOTSTRAP_LIB
  export HPS_RUN_FUNCTIONS="$TEST_DIR/functions.sh"
  # A raw bundle as hps-node-init saves it: functions only, no
  # hps_load_node_functions, and top-level code that is not -eu clean.
  cat > "$HPS_RUN_FUNCTIONS" <<EOT
echo "\$UNSET_BUNDLE_VAR" > /dev/null
false
n_init_run() { echo "n_init_run" > "$TEST_DIR/called"; }
n_remote_host_variable() { echo "n_remote_host_variable \$*" > "$TEST_DIR/called"; }
EOT
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "the plugin and its test use env bash, not /bin/bash" {
  [ "$(head -n1 "$PLUGIN")" = "#!/usr/bin/env bash" ]
  [ "$(head -n1 "$(dirname "$PLUGIN")/test/run.sh")" = "#!/usr/bin/env bash" ]
}

@test "ping falls back to the bundle hps-node-init saved" {
  run "$PLUGIN" ping < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == "hps-node: bundle loaded on "* ]]
}

@test "run-init dispatches into the fallback bundle" {
  run "$PLUGIN" run-init < /dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/called")" = "n_init_run" ]
}

@test "set-status dispatches into the fallback bundle" {
  run "$PLUGIN" set-status RUNNING < /dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/called")" = "n_remote_host_variable STATE RUNNING" ]
}

@test "neither bundle present fails with a message naming both paths" {
  rm "$HPS_RUN_FUNCTIONS"
  run "$PLUGIN" ping < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"bundle not found"* ]]
  [[ "$output" == *"$HPS_RUN_FUNCTIONS"* ]]
  [[ "$output" == *"hps-bootstrap-lib.sh"* ]]
}

@test "an explicit HPS_BOOTSTRAP_LIB that is missing does not fall back" {
  HPS_BOOTSTRAP_LIB="$TEST_DIR/absent.sh" run "$PLUGIN" ping < /dev/null
  [ "$status" -eq 2 ]
}

@test "an explicit HPS_BOOTSTRAP_LIB wins over the fallback" {
  cat > "$TEST_DIR/lib.sh" <<EOT
hps_load_node_functions() { echo loaded-explicit > "$TEST_DIR/which"; }
EOT
  HPS_BOOTSTRAP_LIB="$TEST_DIR/lib.sh" run "$PLUGIN" ping < /dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/which")" = "loaded-explicit" ]
}

@test "the plugin's own test suite still passes" {
  run bash "$(dirname "$PLUGIN")/test/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: PASS"* ]]
}
