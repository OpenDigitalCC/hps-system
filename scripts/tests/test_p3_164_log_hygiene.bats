#!/usr/bin/env bats
#
# IPS-11 (P3-164): lines that are not errors stop being logged as errors, and
# the boot steps that provoked them are ordered or conditioned. One test group
# per item of the filing; the numbers are the filing's.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-164.XXXXXX")"
  export T
}

teardown() {
  rm -rf "$T"
}

# --- 1: an absent host key is a 404 logged at info ------------------------------

@test "1: cgi_fail logs at error by default and at the level it is given" {
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/cgi-functions.sh"
  hps_log() { echo "LOG $1 $2" >> "$T/log"; }
  run cgi_fail "boom"
  [ "${lines[0]}" = "Status: 500 Internal Server Error" ]
  cgi_fail "gone" 404 "Not Found" info > "$T/out"
  head -1 "$T/out" | grep -qx "Status: 404 Not Found"
  grep -qx "LOG error boom" "$T/log"
  grep -qx "LOG info gone" "$T/log"
}

@test "1: cgi_auto_fail hands the level to cgi_fail for a cli caller and keeps the 404" {
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/cgi-functions.sh"
  hps_log() { echo "LOG $1 $2" >> "$T/log"; }
  detect_client_type() { echo cli; }
  cgi_auto_fail "Key 'HOSTNAME' not found" 404 "Not Found" info > "$T/out"
  head -1 "$T/out" | grep -qx "Status: 404 Not Found"
  grep -qx "LOG info Key 'HOSTNAME' not found" "$T/log"
  run ! grep -q "LOG error" "$T/log"
}

@test "1: boot_manager's host_variable GET passes info for the absent key" {
  grep -q "cgi_auto_fail \"Key '\$var_name' not found\" 404 \"Not Found\" info" "$ROOT/http/cgi-bin/boot_manager.sh"
}

@test "1: the nixos node scripts read HOSTNAME with curl -f and no -S, so a 404 prints nothing" {
  for f in hps-node-init.sh hps-pair.sh; do
    grep -q 'run curl -fs "http://${ips}/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"' "$ROOT/node-manager/nixos-26/boot/$f"
    run ! grep -q 'run curl -fsS "http://${ips}/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"' "$ROOT/node-manager/nixos-26/boot/$f"
  done
}

# --- 2: no nets key answers an empty list --------------------------------------

@test "2: boot_manager answers an absent nets key with 200 and an empty JSON list" {
  grep -q 'elif \[\[ "\$var_name" == "nets" \]\]; then' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'cgi_success "\[\]"' "$ROOT/http/cgi-bin/boot_manager.sh"
}

@test "2: net-bridge-ensure reads an empty list as no networks" {
  run jq -e 'type == "array"' <<< '[]'
  [ "$status" -eq 0 ]
  run jq -r '.[]' <<< '[]'
  [ -z "$output" ]
  grep -q "printf '%s' \"\$text\" | jq -e 'type == \"array\"'" "$ROOT/node-manager/nixos-26/scripts/net-bridge-ensure"
}

# --- 3: storage-up waits for the agent ------------------------------------------

make_run_tree() {
  mkdir -p "$T/sys/lib" "$T/hosts/aabbccddeeff"
  cat > "$T/sys/lib/functions.sh" <<EOT
source "$ROOT/lib/functions.d/host-functions.sh"
hps_log() { :; }
normalise_mac() { local m="\${1//[:.-]/}"; echo "\${m,,}"; }
host_registry() { [[ "\$2" == exists ]] && return 0; [[ "\$2" == get ]] && cat "$T/hosts/\$1/\$3"; }
get_host_mac_by_keyvalue() { return 1; }
hps_get_config() { [[ "\$1" == active_cluster ]] && echo lab; }
cluster_registry() { echo -n lab.hps; }
source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
EOT
  echo -n held01 > "$T/hosts/aabbccddeeff/HOSTNAME"
  export HPS_SYSTEM_PATH="$T/sys"
  export CTRL_EXEC_DISPATCHER="$T/ced"
  cat > "$T/ced" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/ced.log"
case "$1" in
  list-agents) printf 'HOSTNAME IP PORT\n----\nheld01.lab.hps 10.0.0.5 7443\n' ;;
  ping) printf 'HOST STATUS RTT\n----\n%s  %s  1ms\n' "$2" "${FAKE_PING_STATUS:-ok}" ;;
esac
EOT
  chmod +x "$T/ced"
}

@test "3: hps-run --ping exits 0 when the dispatcher shows the agent ok and runs no script" {
  make_run_tree
  run bash "$ROOT/scripts/hps-run.sh" --ping aabbccddeeff
  [ "$status" -eq 0 ]
  grep -qx 'ping held01.lab.hps' "$T/ced.log"
  run ! grep -q '^run ' "$T/ced.log"
}

@test "3: hps-run --ping exits 1 when the agent does not answer" {
  make_run_tree
  FAKE_PING_STATUS=error run bash "$ROOT/scripts/hps-run.sh" --ping aabbccddeeff
  [ "$status" -eq 1 ]
}

@test "3: hps-run --ping takes exactly one target" {
  make_run_tree
  run bash "$ROOT/scripts/hps-run.sh" --ping
  [ "$status" -eq 2 ]
  run bash "$ROOT/scripts/hps-run.sh" --ping aabbccddeeff node-facts
  [ "$status" -eq 2 ]
}

@test "3: HPS::Storage pings before the first call (t/99-storage-await-agent.t)" {
  run perl -I"$ROOT/lib/perl" -I"$ROOT/t/lib" "$ROOT/t/99-storage-await-agent.t"
  [ "$status" -eq 0 ]
}

# --- 4: only the module of the CPU vendor ---------------------------------------

@test "4: the compute profile no longer lists both kvm modules; hps-kvm picks by vendor" {
  grep -q 'boot.kernelModules = \[ "vhost_net" "8021q" "bridge" \];' "$ROOT/nix/modules/profiles/compute.nix"
  run ! grep -q 'boot.kernelModules = .*kvm' "$ROOT/nix/modules/profiles/compute.nix"
  grep -q 'modprobe kvm-intel' "$ROOT/nix/modules/profiles/compute.nix"
  grep -q 'modprobe kvm-amd' "$ROOT/nix/modules/profiles/compute.nix"
  grep -q 'before = \[ "libvirtd.service" \];' "$ROOT/nix/modules/profiles/compute.nix"
}

@test "4: the hps-kvm vendor test picks the right module from a cpuinfo" {
  awk '/^    script = '"''"'$/{f=1;next} /^    '"''"';$/{f=0} f' "$ROOT/nix/modules/profiles/compute.nix" | sed 's/^      //' > "$T/kvm.sh"
  [ -s "$T/kvm.sh" ]
  mkdir -p "$T/bin"
  printf '#!/bin/bash\necho "modprobe $*" >> "$T/mp.log"\n' > "$T/bin/modprobe"
  chmod +x "$T/bin/modprobe"
  # grep reads /proc/cpuinfo: run the body against a substituted path
  sed -i "s#/proc/cpuinfo#$T/cpuinfo#g" "$T/kvm.sh"
  printf 'vendor_id\t: AuthenticAMD\n' > "$T/cpuinfo"
  PATH="$T/bin:$PATH" run bash "$T/kvm.sh"
  [ "$status" -eq 0 ]
  printf 'vendor_id\t: GenuineIntel\n' > "$T/cpuinfo"
  PATH="$T/bin:$PATH" run bash "$T/kvm.sh"
  printf 'vendor_id\t: SomethingElse\n' > "$T/cpuinfo"
  PATH="$T/bin:$PATH" run bash "$T/kvm.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/mp.log")" = "$(printf 'modprobe kvm-amd\nmodprobe kvm-intel')" ]
}

# --- 5: transient hostname only --------------------------------------------------

@test "5: the nixos boot scripts set the transient hostname only" {
  for f in hps-node-init.sh hps-pair.sh; do
    grep -q 'run hostnamectl set-hostname --transient "\$name" && return 0' "$ROOT/node-manager/nixos-26/boot/$f"
    run ! grep -q 'run hostnamectl set-hostname "\$name"' "$ROOT/node-manager/nixos-26/boot/$f"
    run ! grep -q 'hostnamectl (static) failed' "$ROOT/node-manager/nixos-26/boot/$f"
  done
}

# --- 6: ttyS1 getty only for a real UART -----------------------------------------

@test "6: serial-getty@ttyS1 is conditioned on the port's sysfs type" {
  grep -q 'unitConfig.ConditionPathExists = "/sys/class/tty/ttyS1/type";' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'serviceConfig.ExecCondition = "${pkgs.gnugrep}/bin/grep -qvx 0 /sys/class/tty/ttyS1/type";' "$ROOT/nix/modules/hps-common.nix"
}

@test "6: the ExecCondition grep succeeds for a UART type and fails for type 0 or no file" {
  echo 4 > "$T/type"
  run grep -qvx 0 "$T/type"
  [ "$status" -eq 0 ]
  echo 0 > "$T/type"
  run grep -qvx 0 "$T/type"
  [ "$status" -eq 1 ]
  run grep -qvx 0 "$T/nofile"
  [ "$status" -eq 2 ]
}

# --- 7: rsyslog ordering left as it is --------------------------------------------

@test "7: hps-log-target stays unordered after network-online (its comment says why)" {
  grep -q 'Not ordered after network-online' "$ROOT/nix/modules/hps-common.nix"
}

# --- 8: no overlay is a debug line ------------------------------------------------

@test "8: a missing state overlay is logged at debug" {
  grep -q 'hps_log debug "State overlay not found' "$ROOT/lib/functions.d/node-libraries-init.sh"
  run ! grep -q 'hps_log warn "State overlay not found' "$ROOT/lib/functions.d/node-libraries-init.sh"
}

# --- 9: the agent unit waits for its certificate ------------------------------------

@test "9: ctrl-exec-agent is conditioned on agent.crt and hps-pair restarts it after the certificate" {
  grep -q 'systemd.services.ctrl-exec-agent.unitConfig.ConditionPathExists = "/etc/ctrl-exec-agent/agent.crt";' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q 'systemctl restart ctrl-exec-agent.service' "$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  # the restart comes after the certificate wait
  local wait_line restart_line
  wait_line=$(grep -n 'wait_for_cert; then' "$ROOT/node-manager/nixos-26/boot/hps-pair.sh" | head -1 | cut -d: -f1)
  restart_line=$(grep -n 'systemctl restart ctrl-exec-agent.service' "$ROOT/node-manager/nixos-26/boot/hps-pair.sh" | head -1 | cut -d: -f1)
  [ "$wait_line" -lt "$restart_line" ]
}

# --- 10: polkit duplicate is not from HPS ---------------------------------------------

@test "10: no HPS module lists polkit or dbus packages" {
  run ! grep -rniE 'polkit|dbus\.packages' "$ROOT/nix/modules" --include=*.nix
}
