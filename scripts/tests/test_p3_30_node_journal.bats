#!/usr/bin/env bats
# node-journal (node-manager/nixos-26/scripts): read-only journal access for
# the IPS. journalctl is shimmed; the test proves the exact arguments, the
# caps and the refusals, and the allowlist wiring.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR=$(mktemp -d)
  export TEST_DIR
  mkdir -p "$TEST_DIR/bin"
  SHIM_LOG="$TEST_DIR/shim.log"
  export SHIM_LOG
  cat > "$TEST_DIR/bin/journalctl" <<'SHIM'
#!/usr/bin/env bash
echo "journalctl $*" >> "$SHIM_LOG"
if [ -n "${FAKE_JOURNALCTL_RC:-}" ]; then exit "$FAKE_JOURNALCTL_RC"; fi
echo "[    1.000000] host unit[1]: line"
SHIM
  chmod +x "$TEST_DIR/bin/journalctl"
  export PATH="$TEST_DIR/bin:$PATH"
  S="$BATS_TEST_DIRNAME/../../node-manager/nixos-26/scripts"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no arguments: this boot, 200 newest lines, no unit filter" {
  run bash "$S/node-journal"
  [ "$status" -eq 0 ]
  [ "$(cat "$SHIM_LOG")" = "journalctl -b --no-pager -o short-monotonic -n 200" ]
  [[ "$output" == *"host unit[1]: line"* ]]
}

@test "a unit without a suffix gets .service; --lines and --prio pass through" {
  run bash "$S/node-journal" libvirtd --lines 30 --prio err
  [ "$status" -eq 0 ]
  [ "$(cat "$SHIM_LOG")" = "journalctl -b --no-pager -o short-monotonic -n 30 -u libvirtd.service -p err" ]
  : > "$SHIM_LOG"
  run bash "$S/node-journal" virtlogd.socket
  [ "$status" -eq 0 ]
  [ "$(cat "$SHIM_LOG")" = "journalctl -b --no-pager -o short-monotonic -n 200 -u virtlogd.socket" ]
}

@test "bad values are usage (2); a unit name with shell characters is refused (3)" {
  run bash "$S/node-journal" --lines 0
  [ "$status" -eq 2 ]
  run bash "$S/node-journal" --lines 501
  [ "$status" -eq 2 ]
  run bash "$S/node-journal" --prio loud
  [ "$status" -eq 2 ]
  run bash "$S/node-journal" a b
  [ "$status" -eq 2 ]
  run bash "$S/node-journal" --bogus
  [ "$status" -eq 2 ]
  run bash "$S/node-journal" 'libvirtd;id'
  [ "$status" -eq 3 ]
  run bash "$S/node-journal" 'a b'
  [ "$status" -eq 3 ]
  run ! test -s "$SHIM_LOG"
}

@test "journalctl failing is 1" {
  FAKE_JOURNALCTL_RC=1 run bash "$S/node-journal" libvirtd
  [ "$status" -eq 1 ]
}

@test "allowlisted under the node profile" {
  local nix="$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  grep -q 'node-journal.source = mkScript "node-journal"' "$nix"
  grep -q 'node-journal.options.profile = "node"' "$nix"
}
