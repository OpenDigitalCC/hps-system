#!/usr/bin/env bats
#
# CS-1.7 items 1, 4, 5: syslog forwarding to the IPS from early boot, and the
# audit-only console. nix cannot run here, so the Nix side is checked
# structurally (the supervisor evaluates it with `nix flake check`); the
# oneshot script is run for real against a fixture command line.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-71.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/boot/hps-log-target.sh"
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  SHIM="$TEST_DIR/shim"
  mkdir -p "$SHIM"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "hps-common.nix forwards journald to a rsyslog that includes the generated target" {
  local f="$ROOT/nix/modules/hps-common.nix"
  grep -q 'services.journald.extraConfig = "ForwardToSyslog=yes";' "$f"
  grep -q 'services.rsyslogd = {' "$f"
  grep -q 'enable = true;' "$f"
  grep -q 'include(file="/run/hps/rsyslog-target.conf" mode="optional")' "$f"
  grep -q 'node-manager/nixos-26/boot/hps-log-target.sh' "$f"
  grep -q 'systemd.services.hps-log-target' "$f"
  grep -q 'before = \[ "syslog.service" "rsyslog.service" \];' "$f"
}

@test "the oneshot script exists, is env bash, executable and shellcheck-clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -n1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  shellcheck -S warning "$SCRIPT"
}

@test "no other module touches rsyslog or journald, and no image forwards elsewhere" {
  run grep -rlE 'services\.rsyslogd|services\.journald' "$ROOT/nix" "$ROOT/flake.nix"
  [ "$output" = "$ROOT/nix/modules/hps-common.nix" ]
  ! grep -rn 'journal-upload\|journalUpload' "$ROOT/nix"
}

@test "autologin appears only in hps-audit.nix" {
  run grep -rln 'autologin' "$ROOT/nix" "$ROOT/flake.nix"
  [ "$output" = "$ROOT/nix/modules/hps-audit.nix" ]
  grep -q 'services.getty.autologinUser = "root";' "$ROOT/nix/modules/hps-audit.nix"
}

@test "hps.ips on the command line becomes a TCP omfwd action to port 514" {
  echo "console=ttyS0 hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:01" > "$HPS_CMDLINE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'target="10.0.0.1" port="514" protocol="tcp"' "$HPS_RUN_DIR/rsyslog-target.conf"
  grep -q '^\*\.\* action(type="omfwd"' "$HPS_RUN_DIR/rsyslog-target.conf"
}

@test "without hps.ips the default gateway is used" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  cat > "$SHIM/ip" <<'EOT'
#!/usr/bin/env bash
echo "default via 10.9.9.1 dev eth0"
EOT
  chmod +x "$SHIM/ip"
  PATH="$SHIM:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'target="10.9.9.1"' "$HPS_RUN_DIR/rsyslog-target.conf"
}

@test "no address at all writes a comment-only file and still exits 0" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/ip"
  chmod +x "$SHIM/ip"
  HPS_LOG_GW_TRIES=1 PATH="$SHIM:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -v '^#' "$HPS_RUN_DIR/rsyslog-target.conf"
  [ -z "$output" ]
}

@test "the no-secrets scan still passes with the new lines" {
  run bats "$BATS_TEST_DIRNAME/test_p1_43_no_secrets.bats"
  [ "$status" -eq 0 ]
}

@test "hps.hostname on the command line becomes rsyslog's localHostname, before the action" {
  echo "hps.ips=10.0.0.1 hps.hostname=sch-1.lab.hps hps.mac=aa:bb:cc:dd:ee:01" > "$HPS_CMDLINE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run sed -n 1p "$HPS_RUN_DIR/rsyslog-target.conf"
  [ "$output" = 'global(localHostname="sch-1.lab.hps")' ]
  grep -q 'target="10.0.0.1"' "$HPS_RUN_DIR/rsyslog-target.conf"
}

@test "a malformed hps.hostname is ignored" {
  echo 'hps.ips=10.0.0.1 hps.hostname=bad")$(x hps.mac=aa:bb:cc:dd:ee:01' > "$HPS_CMDLINE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'localHostname' "$HPS_RUN_DIR/rsyslog-target.conf"
  grep -q 'target="10.0.0.1"' "$HPS_RUN_DIR/rsyslog-target.conf"
}
