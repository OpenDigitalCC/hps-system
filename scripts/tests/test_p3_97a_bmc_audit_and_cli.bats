#!/usr/bin/env bats
#
# IPS-08: the BMC identity in the audit (hps-audit.sh collect_bmc), the driver
# selection after audit intake, and the hps-bmc CLI end to end against a real
# (temporary) registry and keysafe with curl, ipmitool, logger and the PDU
# command as PATH shims. Proves: the collected BMC facts, the lab DL360 audit
# maps to hpe-ilo, an operator choice survives a re-audit, the exit codes IPS-04
# relies on, and the credential is in no argv, no log line and no registry file.

bats_require_minimum_version 1.5.0

setup() {
  load p3_97_helpers
  p97_setup
  AUDIT="$ROOT/node-manager/nixos-26/audit/hps-audit.sh"
  HPSBMC="$ROOT/bin/hps-bmc"
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  export HPS_BMC_RETRY_DELAY=0
  export HPS_BMC_ENV_PASS="SHIM_LOG CALLS_LOG FIX_DIR TEST_DIR P97_USER P97_PASS FAKE_CURL_RC FAKE_PDU_STATE FAKE_PDU_RC FAKE_IPMI_POWER FAKE_IPMI_ERR"
  unset HPS_BMC_NO_SYSLOG
  export PERL5LIB="$ROOT/lib/perl"
  mkdir -p "$HPS_CONFIG_BASE/clusters/lab/cluster.db" "$HPS_CONFIG_BASE/clusters/lab/hosts" "$HPS_SYSTEM_REGISTRY"
  perl -MHPS::Registry -e 'HPS::Registry->new->system_set("ACTIVE_CLUSTER", "lab")'
  MAC=52:54:00:97:aa:01
  MAC12=52540097aa01
  cat > "$TEST_DIR/bin/logger" <<'SHIM'
#!/usr/bin/env bash
echo "logger $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$TEST_DIR/bin/logger"
}

teardown() {
  p97_teardown
}

# audit_setup: fake /sys, /dev and shims so hps-audit.sh runs, DL360 identity.
audit_setup() {
  export HPS_SYS="$TEST_DIR/sys" HPS_PROC="$TEST_DIR/proc" HPS_DEV="$TEST_DIR/dev"
  export HPS_CMDLINE="$TEST_DIR/proc/cmdline" HPS_CONSOLES="$TEST_DIR/console"
  export HPS_AUDIT_OUT="$TEST_DIR/run/audit.json" HPS_IPS=10.99.1.1
  mkdir -p "$HPS_SYS/class/dmi/id" "$HPS_PROC" "$HPS_DEV"
  : > "$TEST_DIR/console"
  echo "BOOT_IMAGE=bzImage" > "$HPS_CMDLINE"
  printf 'MemTotal: 1 kB\n' > "$HPS_PROC/meminfo"
  echo "HP" > "$HPS_SYS/class/dmi/id/sys_vendor"
  echo "ProLiant DL360 Gen9" > "$HPS_SYS/class/dmi/id/product_name"
  local c
  for c in lscpu numactl lspci blkid zpool lsblk ip dmesg; do
    printf '#!/bin/bash\necho "%s $*" >> "$SHIM_LOG"\nexit 0\n' "$c" > "$TEST_DIR/bin/$c"
    chmod +x "$TEST_DIR/bin/$c"
  done
}

with_bmc_hardware() {
  touch "$HPS_DEV/ipmi0"
  mkdir -p "$HPS_SYS/firmware/dmi/entries/38-0" "$HPS_SYS/firmware/dmi/entries/42-0"
}

# store_audit <file>: put the audit document into the registry as a held host.
store_audit() {
  perl -MHPS::Registry -MJSON::PP -e '
    my ($mac, $f) = @ARGV; open my $h, "<", $f or die; local $/; my $a = decode_json(<$h>);
    my $r = HPS::Registry->new; $r->host_set($mac, "STATE", "HELD"); $r->host_set($mac, "HOSTNAME", "sch-001.lab"); $r->host_set($mac, "audit", $a);
  ' "$MAC" "$1"
}

# --- the audit collector -------------------------------------------------------

@test "the audit records the BMC identity from ipmitool and DMI" {
  audit_setup
  with_bmc_hardware
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.bmc.ipmi_device == true' "$HPS_AUDIT_OUT"
  jq -e '.bmc.lan == {mac:"aa:bb:cc:00:11:22", ip_source:"Static Address", ip:"192.0.2.50"}' "$HPS_AUDIT_OUT"
  jq -e '.bmc.mc == {manufacturer_id:"11", product_id:"8199", firmware:"2.55"}' "$HPS_AUDIT_OUT"
  jq -e '.bmc.dmi38 == 1 and .bmc.dmi42 == 1' "$HPS_AUDIT_OUT"
}

@test "the audit reads the BMC with lan print and mc info only" {
  audit_setup
  with_bmc_hardware
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run grep -c '^ipmitool ' "$SHIM_LOG"
  [ "$output" -eq 2 ]
  grep -qx 'ipmitool lan print \[IPMI_PASSWORD_SET=\]' "$SHIM_LOG"
  grep -qx 'ipmitool mc info \[IPMI_PASSWORD_SET=\]' "$SHIM_LOG"
}

@test "the audit skips ipmitool when there is no local IPMI device" {
  audit_setup
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.bmc.ipmi_device == false and .bmc.lan.ip == "" and .bmc.dmi38 == 0 and .bmc.dmi42 == 0' "$HPS_AUDIT_OUT"
  run grep -c '^ipmitool ' "$SHIM_LOG"
  [ "$output" -eq 0 ]
}

@test "the audit image carries ipmitool and the IPMI kernel modules" {
  grep -q 'ipmitool' "$ROOT/nix/modules/hps-audit.nix"
  grep -q '"ipmi_si" "ipmi_devintf"' "$ROOT/nix/modules/hps-audit.nix"
}

@test "the lab DL360 audit, as collected, selects hpe-ilo with the BMC address" {
  audit_setup
  with_bmc_hardware
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  store_audit "$HPS_AUDIT_OUT"
  run "$HPSBMC" select "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"driver hpe-ilo"* ]]
  [ "$(cat "$HPS_CONFIG_BASE/hosts/$MAC12/bmc_driver.json" 2> /dev/null || cat "$HPS_CONFIG_BASE/clusters/lab/hosts/$MAC12.db/bmc_driver.json")" = '"hpe-ilo"' ]
  run "$HPSBMC" list --json
  [ "$(jq -r '.[0].driver' <<< "$output")" = hpe-ilo ]
  [ "$(jq -r '.[0].source' <<< "$output")" = audit ]
  [ "$(jq -r '.[0].addr' <<< "$output")" = 192.0.2.50 ]
}

@test "an operator choice survives a re-audit and an audit-time select" {
  audit_setup
  with_bmc_hardware
  run bash "$AUDIT"
  store_audit "$HPS_AUDIT_OUT"
  run "$HPSBMC" select "$MAC"
  [ "$status" -eq 0 ]
  run "$HPSBMC" device set pdu1 --addr 192.0.2.99 --option 'cmd=pdu-ctl --host {addr} --outlet {outlet} {action}'
  [ "$status" -eq 0 ]
  run "$HPSBMC" set "$MAC" --driver external --option outlet=pdu1:7
  [ "$status" -eq 0 ]
  # the node is audited again and the audit intake runs the selection
  run bash "$AUDIT"
  store_audit "$HPS_AUDIT_OUT"
  run "$HPSBMC" select "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"operator choice kept"* ]]
  run "$HPSBMC" list --json
  [ "$(jq -r '.[0].driver' <<< "$output")" = external ]
  [ "$(jq -r '.[0].source' <<< "$output")" = operator ]
}

# --- the intake hook -------------------------------------------------------------

@test "audit intake asks hps-bmc to select the driver, and survives its failure" {
  load p1_50_helpers
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  p1_50_stubs
  p1_50_host "$MAC" STATE HELD
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH
  printf '#!/bin/bash\necho "hps-bmc $*" >> "$SHIM_LOG"\nexit "${FAKE_BMC_RC:-0}"\n' > "$TEST_DIR/fake-hps-bmc"
  chmod +x "$TEST_DIR/fake-hps-bmc"
  export HPS_BMC_BIN="$TEST_DIR/fake-hps-bmc"
  printf '{"schema":"hps-audit/1","dmi":{"sys_vendor":"HP"}}' > "$TEST_DIR/a.json"
  run host_audit_intake "$MAC" < "$TEST_DIR/a.json"
  [ "$status" -eq 0 ]
  grep -qx "hps-bmc select $MAC" "$SHIM_LOG"
  FAKE_BMC_RC=1 run host_audit_intake "$MAC" < "$TEST_DIR/a.json"
  [ "$status" -eq 0 ]
  grep -q 'BMC driver selection from the audit failed' "$TEST_DIR/hps.log"
}

# --- the CLI ----------------------------------------------------------------------

# cli_host <driver> [hps-bmc set options...]: a registered host with a driver.
cli_host() {
  perl -MHPS::Registry -e '$r = HPS::Registry->new; $r->host_set($ARGV[0], "STATE", "INSTALLED"); $r->host_set($ARGV[0], "HOSTNAME", "sch-001.lab")' "$MAC"
  run "$HPSBMC" set "$MAC" --driver "$@"
  [ "$status" -eq 0 ]
}

set_credential() {
  run bash -c 'printf "%s\n%s\n" "$P97_USER" "$P97_PASS" | "$0" credential "$1"' "$HPSBMC" "$1"
  [ "$status" -eq 0 ]
}

ilo_fixtures() {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"On","Model":"ProLiant DL360 Gen9","SerialNumber":"SER123","Boot":{"BootSourceOverrideMode":"UEFI"},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart"]}}}'
  p97_fix GET /redfish/v1/Managers/1/ '{"FirmwareVersion":"iLO 4 v2.55"}'
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}'
  p97_fix PATCH /redfish/v1/Systems/1/ '{}'
}

@test "hps-bmc status --json prints exactly the four contract fields" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  run --separate-stderr "$HPSBMC" status sch-001 --json
  [ "$status" -eq 0 ]
  [ "$(jq -cS . <<< "$output")" = '{"bmc_firmware":"iLO 4 v2.55","model":"ProLiant DL360 Gen9","power":"on","serial":"SER123"}' ]
}

@test "hps-bmc status without --json prints readable lines" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  run --separate-stderr "$HPSBMC" status "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"power: on"* ]]
}

@test "every action is accepted and the exit codes are those of the contract" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  local a
  for a in on off force-off reset pxe-once; do
    run --separate-stderr "$HPSBMC" "$a" "$MAC"
    [ "$status" -eq 0 ]
  done
  run --separate-stderr "$HPSBMC" identify "$MAC"
  [ "$status" -eq 5 ]
}

@test "exit 4 after the retries when the BMC is unreachable" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  FAKE_CURL_RC=7 run --separate-stderr "$HPSBMC" status "$MAC"
  [ "$status" -eq 4 ]
  run grep -c '^curl ' "$SHIM_LOG"
  [ "$output" -eq 4 ]
}

@test "exit 3 and no retry when the credential is refused" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  run bash -c 'printf "admin-test\nnot-the-password\n" | "$0" credential "$1"' "$HPSBMC" "$MAC"
  [ "$status" -eq 0 ]
  run --separate-stderr "$HPSBMC" status "$MAC"
  [ "$status" -eq 3 ]
  run grep -c '^curl ' "$SHIM_LOG"
  [ "$output" -eq 1 ]
}

@test "exit 5 for a host with no driver, and for the manual driver" {
  perl -MHPS::Registry -e 'HPS::Registry->new->host_set($ARGV[0], "STATE", "INSTALLED")' "$MAC"
  run --separate-stderr "$HPSBMC" reset "$MAC"
  [ "$status" -eq 5 ]
  run "$HPSBMC" set "$MAC" --driver manual
  [ "$status" -eq 0 ]
  run --separate-stderr "$HPSBMC" force-off "$MAC"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"operator"* ]]
}

@test "an external PDU host: on and off go to the PDU, pxe-once exits 5" {
  perl -MHPS::Registry -e 'HPS::Registry->new->host_set($ARGV[0], "STATE", "INSTALLED")' "$MAC"
  run "$HPSBMC" device set pdu1 --addr 192.0.2.99 --option 'cmd=pdu-ctl --host {addr} --outlet {outlet} {action}'
  [ "$status" -eq 0 ]
  run "$HPSBMC" set "$MAC" --driver external --option outlet=pdu1:7
  [ "$status" -eq 0 ]
  set_credential device:pdu1
  run --separate-stderr "$HPSBMC" off "$MAC"
  [ "$status" -eq 0 ]
  run --separate-stderr "$HPSBMC" on "$MAC"
  [ "$status" -eq 0 ]
  grep -qF 'pdu-ctl --host 192.0.2.99 --outlet 7 off' "$SHIM_LOG"
  grep -qF 'pdu-ctl --host 192.0.2.99 --outlet 7 on' "$SHIM_LOG"
  run --separate-stderr "$HPSBMC" pxe-once "$MAC"
  [ "$status" -eq 5 ]
  [ "$(head -n1 "$TEST_DIR/pdu-stdin")" = "$P97_USER" ]
}

@test "hps-bmc set refuses an unknown driver and an undefined device" {
  perl -MHPS::Registry -e 'HPS::Registry->new->host_set($ARGV[0], "STATE", "INSTALLED")' "$MAC"
  run --separate-stderr "$HPSBMC" set "$MAC" --driver nosuch
  [ "$status" -ne 0 ]
  run --separate-stderr "$HPSBMC" set "$MAC" --driver external --option outlet=nopdu:1
  [ "$status" -ne 0 ]
}

@test "hps-bmc list shows driver, source, address and the last call" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  run --separate-stderr "$HPSBMC" status "$MAC"
  [ "$status" -eq 0 ]
  run "$HPSBMC" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hpe-ilo"* ]]
  [[ "$output" == *"operator"* ]]
  [[ "$output" == *"bmc.example.invalid"* ]]
  [[ "$output" == *"status rc=0 power=on"* ]]
}

@test "the credential is in no argv, no log line and no registry file" {
  ilo_fixtures
  cli_host hpe-ilo --addr bmc.example.invalid
  set_credential "$MAC"
  run --separate-stderr "$HPSBMC" pxe-once "$MAC"
  [ "$status" -eq 0 ]
  run --separate-stderr "$HPSBMC" status "$MAC" --json
  # every shim records its argv: the password is in none, and the logger shim saw the syslog lines
  p97_no_credential_in "$SHIM_LOG"
  p97_no_credential_in "$CALLS_LOG"
  grep -q '^logger .*hps-bmc: action=pxe-once host=52540097aa01 driver=hpe-ilo exit=0' "$SHIM_LOG"
  [[ "$output" != *"$P97_PASS"* ]]
  [[ "$stderr" != *"$P97_PASS"* ]]
  run grep -rlF --exclude-dir=keysafe -e "$P97_PASS" "$HPS_CONFIG_BASE"
  [ "$status" -eq 1 ]
  # and it is in the keysafe, mode 0600
  [ -f "$HPS_CONFIG_BASE/clusters/lab/keysafe/credentials/$MAC12.cred" ]
  [ "$(stat -c %a "$HPS_CONFIG_BASE/clusters/lab/keysafe/credentials/$MAC12.cred")" = 600 ]
}

@test "hps-bmc --help prints usage and exits 2" {
  run --separate-stderr "$HPSBMC" --help
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"hps-bmc status|on|off|force-off|reset|pxe-once|identify <host>"* ]]
}
