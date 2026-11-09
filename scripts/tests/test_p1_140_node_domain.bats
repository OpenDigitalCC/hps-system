#!/usr/bin/env bats
#
# CS-1.15: node names carry the cluster DNS domain. IPS side: hps.domain on the
# kernel line. Node side: hps-pair / hps-node-init set <name>.<domain>.
# hps-run.sh: candidate order <name>.<domain>, <name>, <name>.. against the
# dispatcher's list-agents.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-140.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
  p1_50_manifest pin1 node-base
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "boot lines append hps.domain from network_dns_domain" {
  printf 'lab.hps' > "$TEST_DIR/cluster/network_dns_domain"
  run nixos_boot_lines "$MAC" node-base pin1
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *" hps.pin=pin1 hps.domain=lab.hps" ]]
}

@test "hps.domain follows hps.hostname when both are present" {
  printf 'lab.hps' > "$TEST_DIR/cluster/network_dns_domain"
  p1_50_host "$MAC" HOSTNAME node01
  run nixos_boot_lines "$MAC" node-base pin1
  [[ "${lines[0]}" == *" hps.hostname=node01 hps.domain=lab.hps" ]]
}

@test "hps.domain is omitted when the cluster has no domain" {
  run nixos_boot_lines "$MAC" node-base pin1
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"hps.domain"* ]]
}

@test "hps.domain is omitted when the domain is not a valid DNS name" {
  for bad in 'Lab.Hps' 'a b' 'a;b' '-x' '../x'; do
    printf '%s' "$bad" > "$TEST_DIR/cluster/network_dns_domain"
    run nixos_boot_lines "$MAC" node-base pin1
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" != *"hps.domain"* ]]
  done
}

# ---- node side ------------------------------------------------------------

node_setup() {
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/etc"
  export SHIM_LOG="$TEST_DIR/shim.log"
  : > "$SHIM_LOG"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_AGENT_ETC="$TEST_DIR/etc"
  export HPS_RUN_DIR="$TEST_DIR/run"
  printf 'quiet hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:ff %s\n' "$1" > "$HPS_CMDLINE"
  local s
  for s in hostnamectl hostname systemctl getent; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$SHIM_LOG"\n' "$s" > "$TEST_DIR/bin/$s"
    chmod +x "$TEST_DIR/bin/$s"
  done
  # curl answers the HOSTNAME query only
  cat > "$TEST_DIR/bin/curl" <<'EOT'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$SHIM_LOG"
case "$*" in
  *host_variable*) printf '%s' "${FAKE_HOSTNAME:-}" ;;
esac
exit 0
EOT
  chmod +x "$TEST_DIR/bin/curl"
  # the agent "pairs" at once: reqid on stdout and a certificate on disk
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'EOT'
#!/usr/bin/env bash
echo abc123
echo cert > "$HPS_AGENT_ETC/agent.crt"
EOT
  chmod +x "$TEST_DIR/bin/ctrl-exec-agent"
  export PATH="$TEST_DIR/bin:$PATH"
  export HPS_PAIR_TIMEOUT=5 HPS_PAIR_POLL=1
}

PAIR_SH() { echo "$ROOT/node-manager/nixos-26/boot/hps-pair.sh"; }

@test "hps-pair sets <registry label>.<domain> when hps.domain is present" {
  node_setup "hps.domain=lab.hps"
  FAKE_HOSTNAME=held01 run timeout 30 bash "$(PAIR_SH)"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient held01.lab.hps' "$SHIM_LOG"
  grep -qx 'getent hosts held01.lab.hps' "$SHIM_LOG"
}

@test "hps-pair uses hps-<mac12>.<domain> without a registry HOSTNAME" {
  node_setup "hps.domain=lab.hps"
  FAKE_HOSTNAME= run timeout 30 bash "$(PAIR_SH)"
  grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff.lab.hps' "$SHIM_LOG"
}

@test "hps-pair keeps the bare name when hps.domain is absent" {
  node_setup "hps.profile=audit"
  FAKE_HOSTNAME=held01 run timeout 30 bash "$(PAIR_SH)"
  grep -qx 'hostnamectl set-hostname --transient held01' "$SHIM_LOG"
  ! grep -q '^getent' "$SHIM_LOG"
}

@test "hps-pair ignores an invalid hps.domain" {
  node_setup "hps.domain=Bad_Domain"
  FAKE_HOSTNAME=held01 run timeout 30 bash "$(PAIR_SH)"
  grep -qx 'hostnamectl set-hostname --transient held01' "$SHIM_LOG"
}

@test "hps-pair warns, and carries on, when the FQDN does not resolve" {
  node_setup "hps.domain=lab.hps"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$TEST_DIR/bin/getent"
  FAKE_HOSTNAME=held01 run timeout 30 bash "$(PAIR_SH)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"held01.lab.hps does not resolve locally"* ]]
}

@test "hps-node-init sets <name>.<domain> and hands --no-hostname to hps-pair" {
  node_setup "hps.domain=lab.hps hps.profile=node-base"
  printf '#!/usr/bin/env bash\necho "pair $*" >> "$SHIM_LOG"\n' > "$TEST_DIR/pair"
  chmod +x "$TEST_DIR/pair"
  HPS_PAIR="$TEST_DIR/pair" FAKE_HOSTNAME=node01 run timeout 30 bash "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  grep -qx 'hostnamectl set-hostname --transient node01.lab.hps' "$SHIM_LOG"
  grep -qx 'pair --no-hostname' "$SHIM_LOG"
}

@test "hps-node-init uses hps-<mac12>.<domain> without a registry HOSTNAME" {
  node_setup "hps.domain=lab.hps hps.profile=node-base"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/pair"
  chmod +x "$TEST_DIR/pair"
  HPS_PAIR="$TEST_DIR/pair" FAKE_HOSTNAME= run timeout 30 bash "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff.lab.hps' "$SHIM_LOG"
}

# ---- hps-run.sh -----------------------------------------------------------

run_setup() {
  RUN="$ROOT/scripts/hps-run.sh"
  mkdir -p "$TEST_DIR/sys/lib" "$TEST_DIR/hosts/aabbccddeeff" "$TEST_DIR/hosts/112233445566"
  echo -n held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOT
normalise_mac() { local m="\${1//[:.-]/}"; echo "\${m,,}"; }
hps_get_config() { echo c1; }
cluster_registry() { [[ -f "$TEST_DIR/domain" ]] && cat "$TEST_DIR/domain"; }
host_registry() {
  local d="$TEST_DIR/hosts/\$1"
  case "\$2" in
    exists) [[ -d "\$d" ]] ;;
    get) [[ -f "\$d/\$3" ]] && cat "\$d/\$3" ;;
  esac
}
get_host_mac_by_keyvalue() { [[ "\$2" == held01 ]] && echo aabbccddeeff; }
source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
EOT
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CE_LOG"
if [[ "$1" == list-agents ]]; then
  printf 'HOSTNAME  IP  PORT\n------\n'
  cat "$TEST_DIR/agents"
  exit "${FAKE_LIST_RC:-0}"
fi
echo "ran"
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER"
}

@test "hps-run prefers <name>.<domain> when it is registered" {
  run_setup
  printf 'lab.hps' > "$TEST_DIR/domain"
  printf 'held01  1.1.1.1  7443\nheld01.lab.hps  1.1.1.2  7443\nheld01..  1.1.1.3  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.hps node-facts" ]
}

@test "hps-run falls back to the bare name, then to <name>.." {
  run_setup
  printf 'lab.hps' > "$TEST_DIR/domain"
  printf 'held01  1.1.1.1  7443\nheld01..  1.1.1.3  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$(tail -n 1 "$CE_LOG")" = "run held01 node-facts" ]
  printf 'held01..  1.1.1.3  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.. node-facts" ]
}

@test "hps-run resolves an hps-<mac12> node under the domain" {
  run_setup
  printf 'lab.hps' > "$TEST_DIR/domain"
  printf 'hps-112233445566.lab.hps  1.1.1.1  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" 11:22:33:44:55:66 node-facts
  [ "$(tail -n 1 "$CE_LOG")" = "run hps-112233445566.lab.hps node-facts" ]
}

@test "hps-run without a cluster domain tries the bare name and <name>.. only" {
  run_setup
  printf 'held01.lab.hps  1.1.1.2  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 4 ]
  [[ "$output" == *"tried: held01 held01.. "* ]]
}

@test "hps-run names every candidate tried when none is registered" {
  run_setup
  printf 'lab.hps' > "$TEST_DIR/domain"
  printf 'other  1.1.1.1  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 4 ]
  [[ "$output" == *"tried: held01.lab.hps held01 held01.. "* ]]
  ! grep -q '^run ' "$CE_LOG"
}

@test "hps-run does not match a prefix of a registered name" {
  run_setup
  printf 'held01-extra  1.1.1.1  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 4 ]
}

@test "hps-run reports a failing list-agents (1)" {
  run_setup
  : > "$TEST_DIR/agents"
  FAKE_LIST_RC=1 run bash "$RUN" held01 node-facts
  [ "$status" -eq 1 ]
  [[ "$output" == *"list-agents failed"* ]]
}
