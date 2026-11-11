#!/usr/bin/env bats
#
# The HPS auth hook (scripts/ctrl-exec-auth-hook.sh) with remote operators:
# HPS's own callers are unchanged (root on the unix socket; ced, the CLI); a
# TCP caller of the API needs an operator credential and may then run only the
# ips-admin scripts on the IPS's own agent. The hook tells ced from the API by
# ENVEXEC_CALLER and ENVEXEC_LISTENER (ctrl-exec 0.14.7), and an operator call
# must arrive on tls. Without ENVEXEC_CALLER (an older dispatcher) operators are
# refused and ced still works (the legacy parent-process check, hence the
# launchers named ctrl-exec-api and ctrl-exec-dispatcher).

bats_require_minimum_version 1.5.0

TOKEN="hpsop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER="hpsop_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-191.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/conf" "$TEST_DIR/bin" "$TEST_DIR/launch"
  HOOK="$TEST_DIR/conf/auth-hook-hps"
  export HOOK
  cp "$ROOT/scripts/ctrl-exec-auth-hook.sh" "$HOOK"
  chmod 0755 "$HOOK"
  printf 'ips_agent = ips.lab.hps\nscripts = hps-onboard hps-node hps-bmc-credential\n' > "$TEST_DIR/conf/hps-operator.conf"
  hash=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)
  printf '# header\nalice %s\n' "$hash" > "$TEST_DIR/conf/hps-operators"

  cat > "$TEST_DIR/bin/logger" <<'EOT'
#!/bin/bash
echo "$*" >> "$TEST_DIR/syslog"
EOT
  chmod +x "$TEST_DIR/bin/logger"
  export PATH="$TEST_DIR/bin:$PATH"
  # The launchers fork the hook (it is not their last command), so the hook's
  # parent is the launcher, whose command line names it.
  for p in ctrl-exec-api ctrl-exec-dispatcher; do
    printf '#!/bin/bash\n"$HOOK"\nrc=$?\nexit "$rc"\n' > "$TEST_DIR/launch/$p"
    chmod +x "$TEST_DIR/launch/$p"
  done
  API="$TEST_DIR/launch/ctrl-exec-api"
  CED="$TEST_DIR/launch/ctrl-exec-dispatcher"
  unset ENVEXEC_PEER_UID ENVEXEC_TOKEN ENVEXEC_ARGS_JSON ENVEXEC_USERNAME ENVEXEC_CALLER ENVEXEC_LISTENER
}

teardown() {
  rm -rf "$TEST_DIR"
}

# req <launcher> <action> <script> <hosts> <source> [token]
# The launcher names the caller: ctrl-exec-api is an API caller on $LISTENER
# (default tls; unix for a unix source), ctrl-exec-dispatcher is ced.
# NO_CALLER=1 leaves ENVEXEC_CALLER and ENVEXEC_LISTENER out (an older
# dispatcher).
req() {
  local caller=api listener="${LISTENER-tls}"
  if [[ "$1" == "$CED" ]]; then
    caller=cli
    listener=
  fi
  if [[ "$5" == unix:* ]]; then
    listener=unix
  fi
  if [[ -n "${NO_CALLER:-}" ]]; then
    caller=
    listener=
  fi
  ENVEXEC_CALLER="$caller" ENVEXEC_LISTENER="$listener" \
    ENVEXEC_ACTION="$2" ENVEXEC_SCRIPT="$3" ENVEXEC_HOSTS="$4" ENVEXEC_SOURCE_IP="$5" \
    ENVEXEC_TOKEN="${6:-}" ENVEXEC_ARGS_JSON='["list","--json"]' ENVEXEC_USERNAME=alice "$1"
}

@test "unchanged: root on the unix socket is allowed, another uid and no uid are denied" {
  ENVEXEC_PEER_UID=0 run req "$API" run hps-node tch-001.lab.hps unix:/run/ctrl-exec-api/api.sock
  [ "$status" -eq 0 ]
  ENVEXEC_PEER_UID=33 run req "$API" run hps-node tch-001.lab.hps unix:/run/ctrl-exec-api/api.sock
  [ "$status" -eq 1 ]
  run req "$API" run hps-node tch-001.lab.hps unix:/run/ctrl-exec-api/api.sock
  [ "$status" -eq 1 ]
}

@test "unchanged: ced (the dispatcher CLI) is allowed on any host and script" {
  run req "$CED" run dataset-unlock sch-001.lab.hps 127.0.0.1
  [ "$status" -eq 0 ]
  grep -q 'ALLOW cli action=run script=dataset-unlock' "$TEST_DIR/syslog"
}

@test "an API caller from 127.0.0.1 is not taken for ced (the caller says api)" {
  run req "$API" run dataset-unlock sch-001.lab.hps 127.0.0.1
  [ "$status" -eq 2 ]
}

@test "an operator call must arrive on tls: a plain tcp or unlabelled listener is denied" {
  LISTENER=tcp run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 1 ]
  grep -q "operator calls must arrive on tls" "$TEST_DIR/syslog"
  LISTENER= run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 1 ]
}

@test "ENVEXEC_CALLER=cli is ced whatever the source address says" {
  run req "$CED" run dataset-unlock sch-001.lab.hps 10.99.1.50
  [ "$status" -eq 0 ]
}

@test "an unknown ENVEXEC_CALLER is denied" {
  ENVEXEC_CALLER=bogus ENVEXEC_ACTION=run ENVEXEC_HOSTS=ips.lab.hps ENVEXEC_SOURCE_IP=10.99.1.50 ENVEXEC_TOKEN="$TOKEN" run "$HOOK"
  [ "$status" -eq 1 ]
}

@test "no ENVEXEC_CALLER (ctrl-exec older than 0.14.7): operators are refused, valid token or not" {
  NO_CALLER=1 run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 1 ]
  NO_CALLER=1 run req "$API" api '' '' 10.99.1.50 "$TOKEN"
  [ "$status" -eq 1 ]
  grep -q "no ENVEXEC_CALLER" "$TEST_DIR/syslog"
}

@test "no ENVEXEC_CALLER: HPS's own callers work as before (ced, root on the unix socket)" {
  NO_CALLER=1 run req "$CED" run dataset-unlock sch-001.lab.hps 127.0.0.1
  [ "$status" -eq 0 ]
  NO_CALLER=1 ENVEXEC_PEER_UID=0 run req "$API" run hps-node tch-001.lab.hps unix:/run/ctrl-exec-api/api.sock
  [ "$status" -eq 0 ]
}

@test "a TCP caller without a credential is denied as bad credentials" {
  run req "$API" api '' '' 10.99.1.50
  [ "$status" -eq 2 ]
  run req "$API" api '' '' 10.99.1.50 short-token
  [ "$status" -eq 2 ]
  grep -q 'DENY action=api' "$TEST_DIR/syslog"
}

@test "an unknown or revoked credential is denied" {
  run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$OTHER"
  [ "$status" -eq 2 ]
  grep -q 'unknown or revoked operator credential' "$TEST_DIR/syslog"
}

@test "an operator passes the API's pre-route check" {
  run req "$API" api '' '' 10.99.1.50 "$TOKEN"
  [ "$status" -eq 0 ]
}

@test "an operator may run an ips-admin script on the IPS's own agent, and the call is logged" {
  run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 0 ]
  grep -q 'OPERATOR run operator=alice source=10.99.1.50 user=alice agent=ips.lab.hps script=hps-onboard args=\["list","--json"\]' "$TEST_DIR/syslog"
  run req "$API" run hps-bmc-credential ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 0 ]
}

@test "an operator may not run on a node agent, or on two hosts" {
  run req "$API" run hps-node tch-001.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
  run req "$API" run hps-node ips.lab.hps,tch-001.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
  grep -q 'DENY action=run script=hps-node hosts=tch-001.lab.hps.*operator=alice' "$TEST_DIR/syslog"
}

@test "an operator may not run a script outside ips-admin on the IPS agent" {
  run req "$API" run hps-storage ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
  run req "$API" run dataset-unlock ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
}

@test "an operator may ping the IPS agent only, and never read a stored result" {
  run req "$API" ping '' ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 0 ]
  run req "$API" ping '' tch-001.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
  run req "$API" status '' '' 10.99.1.50 "$TOKEN"
  [ "$status" -eq 3 ]
}

@test "without hps-operator.conf (no IPS agent yet) or hps-operators every TCP call is denied" {
  rm "$TEST_DIR/conf/hps-operator.conf"
  run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 1 ]
  printf 'ips_agent = ips.lab.hps\nscripts = hps-onboard\n' > "$TEST_DIR/conf/hps-operator.conf"
  rm "$TEST_DIR/conf/hps-operators"
  run req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN"
  [ "$status" -eq 2 ]
}

@test "the credential never reaches the log" {
  req "$API" run hps-onboard ips.lab.hps 10.99.1.50 "$TOKEN" || true
  req "$API" run hps-node tch-001.lab.hps 10.99.1.50 "$TOKEN" || true
  run ! grep -q "$TOKEN" "$TEST_DIR/syslog"
}
