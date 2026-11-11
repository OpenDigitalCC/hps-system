#!/usr/bin/env bats
#
# IPS-14: a held node with its audit stored waits at iPXE (hold script, retry
# interval from the cluster key) and boots its role once assigned; hps-onboard
# reaudit brings the audit image back; the audit image reboots after a
# successful post and stays up after a failed one.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-161.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  source "$ROOT/lib/functions.d/os-function-helpers.sh"
  p1_50_stubs
  # the shared stub has no delete; the intake clears audit_stale with it
  host_registry() {
    local mac=$1 op=$2 key=${3:-} val=${4:-}
    local d="$TEST_DIR/hosts/${mac//:/}"
    case "$op" in
      exists)
        if [[ -z "$key" ]]; then [[ -d "$d" ]]; else [[ -f "$d/$key" ]]; fi
        return $? ;;
      get)    [[ -f "$d/$key" ]] || return 1
              cat "$d/$key" ;;
      set)    mkdir -p "$d"
              printf '%s' "$val" > "$d/$key" ;;
      delete) rm -f "$d/$key" ;;
    esac
    return 0
  }
  ipxe_configure_main_menu() { echo "MENU-SHOWN"; }
  ipxe_boot_installer() { echo "installer"; }
  ipxe_network_boot() { echo "network-boot $1"; }
  p1_50_manifest pin1 audit
  printf 'pin1' > "$TEST_DIR/cluster/nixos_default_pin"
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:61
  HOSTDIR="$TEST_DIR/hosts/525400aabb61"
}

teardown() {
  rm -rf "$TEST_DIR"
}

held_with_audit() {
  p1_50_host "$MAC" STATE HELD
  p1_50_host "$MAC" audit '{"schema":"hps-audit/1"}'
}

# --- ipxe_init_handler ---------------------------------------------------------

@test "a held host with no audit is served the audit image" {
  p1_50_host "$MAC" STATE HELD
  run ipxe_init_handler "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/audit/bzImage"* ]]
  [[ "$output" != *"is held; waiting"* ]]
}

@test "an unknown MAC is registered HELD and served the audit image" {
  run ipxe_init_handler "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/audit/bzImage"* ]]
}

@test "a held host with an audit is served the hold script, not the audit image" {
  held_with_audit
  run ipxe_init_handler "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#!ipxe"* ]]
  [[ "$output" == *"HPS: $MAC is held; waiting for a role (retry in 30 s)"* ]]
  [[ "$output" == *$'\nsleep 30\n'* ]]
  [[ "$output" == *"chain --replace http://ips/cgi-bin/boot_manager.sh?cmd=init"* ]]
  [[ "$output" != *"kernel "* ]]
  [[ "$output" != *"/audit/bzImage"* ]]
}

@test "the retry interval is the cluster key hold_retry_seconds" {
  held_with_audit
  printf '45' > "$TEST_DIR/cluster/hold_retry_seconds"
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"(retry in 45 s)"* ]]
  [[ "$output" == *$'\nsleep 45\n'* ]]
}

@test "hold_retry_seconds accepts the limits 5 and 3600" {
  held_with_audit
  printf '5' > "$TEST_DIR/cluster/hold_retry_seconds"
  run ipxe_init_handler "$MAC"
  [[ "$output" == *$'\nsleep 5\n'* ]]
  printf '3600' > "$TEST_DIR/cluster/hold_retry_seconds"
  run ipxe_init_handler "$MAC"
  [[ "$output" == *$'\nsleep 3600\n'* ]]
}

@test "an invalid hold_retry_seconds falls back to 30 and is logged" {
  held_with_audit
  local bad
  for bad in 4 3601 abc 1.5 -7 "" "30; reboot"; do
    printf '%s' "$bad" > "$TEST_DIR/cluster/hold_retry_seconds"
    run ipxe_init_handler "$MAC"
    [[ "$output" == *"(retry in 30 s)"* ]]
  done
  printf 'abc' > "$TEST_DIR/cluster/hold_retry_seconds"
  run ipxe_init_handler "$MAC"
  grep -q "warn cluster key hold_retry_seconds='abc'" "$TEST_DIR/hps.log"
}

@test "the hold script survives an IPS that is down: chain failure retries" {
  held_with_audit
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"chain --replace http://ips/cgi-bin/boot_manager.sh?cmd=init || goto failed"* ]]
  [[ "$output" == *$'\n:failed\n'* ]]
  [[ "$output" == *$'\ngoto retry'* ]]
}

@test "a hold request is logged at debug, not info" {
  held_with_audit
  run ipxe_init_handler "$MAC"
  grep -q "^debug .*held with audit stored" "$TEST_DIR/hps.log"
  run grep -E "^info .*(held|audit boot)" "$TEST_DIR/hps.log"
  [ "$status" -ne 0 ]
}

@test "the hold script carries nothing but the MAC, the interval and the boot URL" {
  held_with_audit
  run ipxe_init_handler "$MAC"
  [[ "$output" != *"token"* ]]
  [[ "$output" != *"secret"* ]]
  [[ "$output" != *"pairing"* ]]
}

@test "an assigned host (NETWORK_BOOT) boots its role, not the hold script" {
  p1_50_host "$MAC" STATE NETWORK_BOOT
  p1_50_host "$MAC" audit '{"schema":"hps-audit/1"}'
  run ipxe_init_handler "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == "network-boot $MAC" ]]
  [[ "$output" != *"is held"* ]]
}

@test "the retry after assign reaches the role: HELD then NETWORK_BOOT" {
  held_with_audit
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"is held; waiting for a role"* ]]
  # hps-onboard assign ends by writing STATE=NETWORK_BOOT (t/96-onboard-reaudit.t)
  p1_50_host "$MAC" STATE NETWORK_BOOT
  run ipxe_init_handler "$MAC"
  [[ "$output" == "network-boot $MAC" ]]
}

# --- reaudit and the stale mark -----------------------------------------------------

@test "a stale audit brings the audit image back" {
  held_with_audit
  p1_50_host "$MAC" audit_stale true
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"/audit/bzImage"* ]]
  [[ "$output" != *"is held; waiting"* ]]
}

@test "a mark other than true leaves the hold loop alone" {
  held_with_audit
  p1_50_host "$MAC" audit_stale false
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"is held; waiting for a role"* ]]
}

@test "a newly stored audit clears the stale mark and the hold loop resumes" {
  held_with_audit
  p1_50_host "$MAC" audit_stale true
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH
  run host_audit_intake "$MAC" <<< '{"schema":"hps-audit/1","collected_at":"2026-11-11T10:00:00Z"}'
  [ "$status" -eq 0 ]
  [ ! -e "$HOSTDIR/audit_stale" ]
  run ipxe_init_handler "$MAC"
  [[ "$output" == *"is held; waiting for a role"* ]]
}

@test "hps-onboard reaudit marks the audit stale (Perl side, real registry)" {
  run prove -I "$ROOT/lib/perl" "$ROOT/t/96-onboard-reaudit.t"
  [ "$status" -eq 0 ]
}

# --- the audit image boot line -------------------------------------------------------

@test "the audit boot line has no hps.audit_reboot by default" {
  run nixos_boot_lines "$MAC" audit pin1
  [[ "$output" != *"hps.audit_reboot"* ]]
}

@test "held_reboot_after_audit=false adds hps.audit_reboot=0 to the audit image only" {
  printf 'false' > "$TEST_DIR/cluster/held_reboot_after_audit"
  run nixos_boot_lines "$MAC" audit pin1
  [[ "$output" == *"hps.audit_reboot=0"* ]]
  p1_50_manifest pin1 node-base
  run nixos_boot_lines "$MAC" node-base pin1
  [[ "$output" != *"hps.audit_reboot"* ]]
}

@test "held_reboot_after_audit=true leaves the audit boot line alone" {
  printf 'true' > "$TEST_DIR/cluster/held_reboot_after_audit"
  run nixos_boot_lines "$MAC" audit pin1
  [[ "$output" != *"hps.audit_reboot"* ]]
}

# --- the audit script ---------------------------------------------------------------

audit_setup() {
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_SYS="$TEST_DIR/sys" HPS_PROC="$TEST_DIR/proc" HPS_DEV="$TEST_DIR/dev"
  export HPS_CMDLINE="$TEST_DIR/proc/cmdline" HPS_CONSOLES="$TEST_DIR/console"
  export HPS_AUDIT_OUT="$TEST_DIR/run/audit.json" HPS_IPS=10.99.1.1
  export HPS_REBOOT_CMD="$TEST_DIR/bin/reboot-shim" HPS_REBOOT_DELAY=0
  AUDIT="$ROOT/node-manager/nixos-26/audit/hps-audit.sh"
  mkdir -p "$TEST_DIR/bin" "$HPS_PROC" "$HPS_SYS/class/dmi/id" "$HPS_DEV"
  : > "$TEST_DIR/console"
  : > "$SHIM_LOG"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.profile=audit" > "$HPS_CMDLINE"
  printf 'MemTotal: 1 kB\n' > "$HPS_PROC/meminfo"
  local c
  for c in lscpu numactl lspci lsblk blkid zpool ip dmesg ipmitool; do
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/$c"
  done
  printf '#!/bin/bash\necho "reboot $*" >> "$SHIM_LOG"\n' > "$TEST_DIR/bin/reboot-shim"
  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$SHIM_LOG"
exit "${FAKE_CURL_RC:-0}"
EOF
  chmod +x "$TEST_DIR"/bin/*
  export PATH="$TEST_DIR/bin:$PATH"
}

@test "the audit script reboots after a successful post" {
  audit_setup
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -q '^reboot' "$SHIM_LOG"
  [[ "$output" == *"audit stored (HTTP 200); rebooting into the IPS hold loop"* ]]
}

@test "the reboot comes after the post, once" {
  audit_setup
  run bash "$AUDIT"
  [ "$(grep -c '^reboot' "$SHIM_LOG")" -eq 1 ]
  [ "$(grep -n '^curl' "$SHIM_LOG" | cut -d: -f1)" -lt "$(grep -n '^reboot' "$SHIM_LOG" | cut -d: -f1)" ]
}

@test "the audit script stays up after a failed post" {
  audit_setup
  FAKE_CURL_RC=22 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run grep -c '^reboot' "$SHIM_LOG"
  [ "$output" = "0" ]
  [[ "$(cat "$TEST_DIR/console")" == *"SEND FAILED"* ]]
}

@test "the audit script stays up when there is no IPS address to post to" {
  audit_setup
  unset HPS_IPS
  echo "BOOT_IMAGE=bzImage" > "$HPS_CMDLINE"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/ip"
  run bash "$AUDIT"
  run grep -c '^reboot' "$SHIM_LOG"
  [ "$output" = "0" ]
}

@test "hps.audit_reboot=0 on the command line keeps the audit image up after a good post" {
  audit_setup
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.profile=audit hps.audit_reboot=0" > "$HPS_CMDLINE"
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -q '^curl' "$SHIM_LOG"
  run grep -c '^reboot' "$SHIM_LOG"
  [ "$output" = "0" ]
}

@test "a failing reboot command leaves the audit script exiting 0" {
  audit_setup
  printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/reboot-shim"
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reboot command failed"* ]]
}

# --- catalogue and docs ---------------------------------------------------------------

@test "the new keys are catalogued: audit_stale, hold_retry_seconds, held_reboot_after_audit" {
  run perl "$ROOT/bin/hps-registry-keys" --type host audit_stale
  [ "$output" = "bool" ]
  run perl "$ROOT/bin/hps-registry-keys" --type cluster hold_retry_seconds
  [ "$output" = "int" ]
  run perl "$ROOT/bin/hps-registry-keys" --type cluster held_reboot_after_audit
  [ "$output" = "bool" ]
}

@test "hold_retry_seconds is validated 5..3600 by hps-cluster-config" {
  run perl -I "$ROOT/lib/perl" -MHPS::ClusterConfig -e '
    my $q = HPS::ClusterConfig::question("hold_retry_seconds");
    for my $v (qw(4 5 3600 3601 abc)) { my $e = HPS::ClusterConfig::validate_value($q, $v); print "$v:", (defined $e ? "bad" : "ok"), "\n" }'
  [ "$status" -eq 0 ]
  [[ "$output" == *"4:bad"* && "$output" == *"5:ok"* && "$output" == *"3600:ok"* && "$output" == *"3601:bad"* && "$output" == *"abc:bad"* ]]
}
