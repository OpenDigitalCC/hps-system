#!/usr/bin/env bats
#
# CS-1.6 items 1-2: the NixOS node side. The bundle built for os=nixos-26
# carries the compat library; on NixOS a base function either does the
# equivalent safely or logs "nixos: skipped <what>" and returns 0. NixOS is
# detected from a fixture root (HPS_OS_ROOT); nothing here touches the host's
# /etc. curl, ip, ln, hostname and hostnamectl are PATH shims that log calls.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-60.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"
  export HPS_OS_ROOT="$TEST_DIR/root"
  mkdir -p "$HPS_OS_ROOT/etc"
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  echo "console=ttyS0 hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:01" > "$HPS_CMDLINE"

  SHIM="$TEST_DIR/shim"
  mkdir -p "$SHIM"
  local cmd
  for cmd in ln hostname hostnamectl logger; do
    cat > "$SHIM/$cmd" <<EOT
#!/usr/bin/env bash
echo "$cmd \$*" >> "$CALL_LOG"
exit 0
EOT
    chmod +x "$SHIM/$cmd"
  done
  # curl plays the IPS: answers the registry lookups the base functions make.
  cat > "$SHIM/curl" <<EOT
#!/usr/bin/env bash
echo "curl \$*" >> "$CALL_LOG"
case "\$*" in
  *name=HOSTNAME*) printf 'node-01' ;;
  *name=IP*) printf '10.0.0.50' ;;
  *name=network_dns_domain*) printf '"lab.example"' ;;
esac
printf 'HTTPCODE:200'
EOT
  chmod +x "$SHIM/curl"
  cat > "$SHIM/ip" <<'EOT'
#!/usr/bin/env bash
echo "default via 10.0.0.1 dev eth0"
EOT
  chmod +x "$SHIM/ip"
  export PATH="$SHIM:$PATH"

  # Stubs for the HPS node API the base functions call.
  n_remote_log() { echo "log: $*" >> "$CALL_LOG"; }
  n_remote_host_variable() {
    case "$1" in
      HOSTNAME) echo "node-01" ;;
      IP) echo "10.0.0.50" ;;
    esac
  }
  n_remote_cluster_variable() { echo '"lab.example"'; }
  export -f n_remote_log n_remote_host_variable n_remote_cluster_variable

  NM="$ROOT/node-manager"
}

teardown() {
  rm -rf "$TEST_DIR"
}

make_nixos() {
  printf 'ID=nixos\nNAME=NixOS\n' > "$HPS_OS_ROOT/etc/os-release"
}

make_alpine() {
  echo "3.20.2" > "$HPS_OS_ROOT/etc/alpine-release"
}

load_base() {
  # shellcheck source=/dev/null
  source "$NM/base/n_os-detect.sh"
}

load_nixos() {
  load_base
  # shellcheck source=/dev/null
  source "$NM/nixos-26/nixos-lib-functions.sh"
}

# ---- bundle -----------------------------------------------------------------

build_bundle() {
  # A separate shell: the builder is written for the CGI (no errexit), where
  # ((_LOADED_COUNT++)) and `declare -f` of an absent function may return 1.
  HPS_SYSTEM_BASE="$ROOT" ROOT="$ROOT" bash -c '
    hps_log() { :; }
    urlencode() { :; }
    netmask_to_cidr() { :; }
    source "$ROOT/lib/functions.d/node-libraries-init.sh"
    node_build_functions "x86_64:nixos:26.05" "" "DEFAULT" "NETWORK_BOOT" "false"
  ' > "$TEST_DIR/bundle.sh" < /dev/null
}

@test "nixos bundle carries the compat library after the base libraries" {
  build_bundle
  grep -q "^# Loading: nixos-lib-functions.sh" "$TEST_DIR/bundle.sh"
  base_at=$(grep -n "^# Loading: n_os-detect.sh" "$TEST_DIR/bundle.sh" | cut -d: -f1)
  nixos_at=$(grep -n "^# Loading: nixos-lib-functions.sh" "$TEST_DIR/bundle.sh" | cut -d: -f1)
  [ "$base_at" -lt "$nixos_at" ]
}

@test "nixos init sequence runs base inits first and leaves out ctrl-exec and opensvc" {
  build_bundle
  seq=$(sed -n '/^HPS_INIT_SEQUENCE=(/,/^)/p' "$TEST_DIR/bundle.sh" | tr -d ' ')
  [[ "$seq" == *'"n_configure_reboot_logging"'* ]]
  [[ "$seq" == *'"n_set_hostname_and_hosts"'* ]]
  [[ "$seq" != *n_ctrl_exec_enrol* ]]
  [[ "$seq" != *n_install_opensvc_packages* ]]
  # base/common-post (os=*) precedes the nixos.init action.
  post_at=$(printf '%s\n' "$seq" | grep -n n_configure_ips_profile | cut -d: -f1)
  host_at=$(printf '%s\n' "$seq" | grep -n n_set_hostname_and_hosts | cut -d: -f1)
  [ "$post_at" -lt "$host_at" ]
}

@test "every action in the nixos init sequence is defined in the bundle" {
  build_bundle
  make_nixos
  run bash -c '
    set +u
    source "$1"
    for action in "${HPS_INIT_SEQUENCE[@]}"; do
      read -r -a w <<< "$action"
      type "${w[0]}" >/dev/null 2>&1 || { echo "undefined: ${w[0]}"; exit 1; }
    done
  ' _ "$TEST_DIR/bundle.sh" < /dev/null
  [ "$status" -eq 0 ]
}

@test "the whole nixos init run succeeds against a fixture root and touches no unwritable path" {
  build_bundle
  make_nixos
  export HPS_PROFILE_D="$TEST_DIR/etc-profile.d"
  run bash -c '
    set +u
    source "$1"
    n_init_run
  ' _ "$TEST_DIR/bundle.sh" < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"Function not found"* ]]
  grep -qE "^hostnamectl set-hostname (--transient )?node-01.lab.example" "$CALL_LOG"
  [ -f "$HPS_RUN_DIR/profile.d/hps-env.sh" ]
  [ ! -e "$HPS_OS_ROOT/etc/hosts" ]
  [ ! -e "$HPS_OS_ROOT/etc/hostname" ]
  ! grep -q "^ln " "$CALL_LOG"
}

# ---- detection --------------------------------------------------------------

@test "distro detection returns nixos from os-release" {
  make_nixos
  load_base
  run n_os_id
  [ "$status" -eq 0 ]
  [ "$output" = "nixos" ]
  n_os_is_nixos
}

@test "distro detection returns nixos from /etc/NIXOS" {
  touch "$HPS_OS_ROOT/etc/NIXOS"
  load_base
  run n_os_id
  [ "$output" = "nixos" ]
}

@test "distro detection still knows alpine and rocky and never fails on unknown" {
  load_base
  run n_os_id
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  make_alpine
  run n_os_id
  [ "$output" = "alpine" ]
  rm "$HPS_OS_ROOT/etc/alpine-release"
  touch "$HPS_OS_ROOT/etc/rocky-release"
  run n_os_id
  [ "$output" = "rocky" ]
  ! n_os_is_nixos
}

@test "ID_LIKE=nixos-ish does not count as nixos" {
  printf 'ID=debian\nID_LIKE=nixos\n' > "$HPS_OS_ROOT/etc/os-release"
  load_base
  ! n_os_is_nixos
}

# ---- packages ---------------------------------------------------------------

@test "n_install_packages is a logged no-op on nixos" {
  load_nixos
  run n_install_packages jq curl
  [ "$status" -eq 0 ]
  [[ "$output" == *"nixos: packages come from the image; ignoring: jq curl"* ]]
  grep -q "log: nixos: packages come from the image; ignoring: jq curl" "$CALL_LOG"
}

@test "base package-installing paths skip on nixos instead of failing" {
  make_nixos
  load_base
  source "$NM/base/n_install_opensvc_packages.sh"
  source "$NM/base/n_ctrl-exec.sh"
  run n_install_opensvc_packages
  [ "$status" -eq 0 ]
  run n_install_ctrl_exec
  [ "$status" -eq 0 ]
  run n_ctrl_exec_enrol
  [ "$status" -eq 0 ]
  grep -q "log: nixos: skipped ctrl-exec enrol" "$CALL_LOG"
  ! grep -q "^curl " "$CALL_LOG"
}

# ---- profile ----------------------------------------------------------------

@test "n_configure_ips_profile writes to the fallback dir when /etc/profile.d is unwritable" {
  [ "$(id -u)" -ne 0 ] || skip "root can write a read-only directory"
  load_nixos
  export HPS_PROFILE_D="$TEST_DIR/ro-profile.d"
  mkdir -p "$HPS_PROFILE_D"
  chmod 555 "$HPS_PROFILE_D"
  run n_configure_ips_profile
  chmod 755 "$HPS_PROFILE_D"
  [ "$status" -eq 0 ]
  [ -f "$HPS_RUN_DIR/profile.d/hps-env.sh" ]
  [ -z "$(ls -A "$HPS_PROFILE_D")" ]
  grep -q "export HPS_BOOTSTRAP_LIB=\"$HPS_RUN_DIR/functions.sh\"" "$HPS_RUN_DIR/profile.d/hps-env.sh"
  grep -q "log: nixos: $HPS_PROFILE_D is not a writable directory" "$CALL_LOG"
  ! grep -q "^ln " "$CALL_LOG"
}

@test "n_configure_ips_profile falls back when /etc/profile.d does not exist" {
  load_nixos
  export HPS_PROFILE_D="$TEST_DIR/absent"
  run n_configure_ips_profile
  [ "$status" -eq 0 ]
  [ -f "$HPS_RUN_DIR/profile.d/hps-env.sh" ]
  [ ! -e "$HPS_PROFILE_D" ]
}

@test "n_configure_ips_profile uses a writable /etc/profile.d" {
  load_nixos
  export HPS_PROFILE_D="$TEST_DIR/rw-profile.d"
  mkdir -p "$HPS_PROFILE_D"
  run n_configure_ips_profile
  [ "$status" -eq 0 ]
  [ -f "$HPS_PROFILE_D/hps-env.sh" ]
  [ ! -e "$HPS_RUN_DIR/profile.d" ]
  # sourced, not executed: no shebang
  ! grep -q '^#!' "$HPS_PROFILE_D/hps-env.sh"
}

@test "the profile drop-in sets TERM and HPS_BOOTSTRAP_LIB when sourced" {
  load_nixos
  export HPS_PROFILE_D="$TEST_DIR/rw-profile.d"
  mkdir -p "$HPS_PROFILE_D"
  n_configure_ips_profile
  run env TERM=vt100 bash -c 'source "$1"; echo "$TERM $HPS_BOOTSTRAP_LIB"' _ "$HPS_PROFILE_D/hps-env.sh"
  [ "$output" = "vt100 $HPS_RUN_DIR/functions.sh" ]
  grep -q ': "${TERM:=xterm}"' "$HPS_PROFILE_D/hps-env.sh"
}

# ---- shell, console, reboot -------------------------------------------------

@test "n_configure_bash_shell never touches /bin/sh on nixos" {
  make_nixos
  load_base
  source "$NM/base/n_shell-config.sh"
  run n_configure_bash_shell
  [ "$status" -eq 0 ]
  grep -q "log: nixos: skipped bash as /bin/sh" "$CALL_LOG"
  ! grep -q "^ln " "$CALL_LOG"
}

@test "motd, console info and reboot logging skip on nixos" {
  make_nixos
  load_nixos
  source "$NM/base/console.sh"
  run n_configure_motd
  [ "$status" -eq 0 ]
  run n_display_info_before_prompt
  [ "$status" -eq 0 ]
  run n_configure_reboot_logging
  [ "$status" -eq 0 ]
  grep -q "skipped MOTD" "$CALL_LOG"
  grep -q "skipped console info" "$CALL_LOG"
  grep -q "skipped reboot logging" "$CALL_LOG"
}

# ---- hostname ---------------------------------------------------------------

@test "hostname on nixos sets the FQDN with hostnamectl and writes no files" {
  make_nixos
  load_base
  source "$NM/base/n_configure-hostname.sh"
  run n_set_hostname_and_hosts
  [ "$status" -eq 0 ]
  grep -qE "^hostnamectl set-hostname (--transient )?node-01.lab.example" "$CALL_LOG"
  grep -q "log: nixos: skipped /etc/hostname and /etc/hosts writes" "$CALL_LOG"
  [ ! -e "$HPS_OS_ROOT/etc/hostname" ]
  [ ! -e "$HPS_OS_ROOT/etc/hosts" ]
}

@test "hostname on alpine still writes the hostname and hosts files" {
  make_alpine
  # No hostnamectl on alpine: a PATH with only the tools the function uses.
  local bin="$TEST_DIR/alpine-bin"
  mkdir -p "$bin" "$HPS_OS_ROOT/etc/conf.d"
  local t
  for t in bash cat grep sed; do command -p ln -s "$(command -v "$t")" "$bin/$t"; done
  cp "$SHIM/hostname" "$bin/hostname"
  echo 'hostname="old"' > "$HPS_OS_ROOT/etc/conf.d/hostname"
  load_base
  source "$NM/base/n_configure-hostname.sh"
  PATH="$bin" run n_set_hostname_and_hosts
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_OS_ROOT/etc/hostname")" = "node-01.lab.example" ]
  grep -q "10.0.0.50       node-01.lab.example node-01" "$HPS_OS_ROOT/etc/hosts"
  grep -q 'hostname="node-01.lab.example"' "$HPS_OS_ROOT/etc/conf.d/hostname"
  grep -q "^hostname node-01.lab.example" "$CALL_LOG"
  ! grep -q "^hostnamectl" "$CALL_LOG"
}

# ---- provisioning node ------------------------------------------------------

@test "n_get_provisioning_node prefers hps.ips from the command line" {
  load_nixos
  run n_get_provisioning_node
  [ "$output" = "10.0.0.1" ]
  echo "console=ttyS0" > "$HPS_CMDLINE"
  run n_get_provisioning_node
  [ "$output" = "10.0.0.1" ]   # default-gateway fallback (ip shim)
}
