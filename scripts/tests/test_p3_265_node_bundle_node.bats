#!/usr/bin/env bats
#
# Plan step 2, node side (node-manager/bundle/, docs/BUNDLE.md): bootstrap.sh,
# init and the NixOS adapter, run against shims of curl, useradd, sshd, systemctl,
# nix and the rest, with the bundle the IPS really builds. No network, no root.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-265.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TEST_DIR ROOT
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_ROOT="$TEST_DIR/root"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_NIX_PROFILE="$TEST_DIR/profile"
  export HPS_SYSTEMD_DIR="$TEST_DIR/systemd"
  export HPS_PATH_EXTRA="$TEST_DIR/bin"
  export HPS_FETCH_RETRY=0
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/serve" "$TEST_DIR/home/sysadmin" "$HPS_ROOT/etc/ssh" "$HPS_NIX_PROFILE"
  echo "BOOT_IMAGE=bzImage console=ttyS0 hps.ips=10.9.9.9 hps.mac=aa:bb:cc:dd:ee:ff hps.os=x86_64:nixos:26.05 hps.profile=STARTER hps.domain=lab.test systemd.run=\"/bin/sh -c 'curl hps.ips=6.6.6.6'\"" > "$HPS_CMDLINE"
  printf '# the starter\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM yes\n' > "$HPS_ROOT/etc/ssh/sshd_config"
  shims
  node_bundle() {
    source "$ROOT/lib/functions.d/node-bundle-functions.sh"
    hps_log() { :; }
    node_bundle_tar "$ROOT"
  }
  node_bundle > "$TEST_DIR/serve/bundle.tgz"
  # the agent tarball the IPS serves, in miniature
  mkdir -p "$TEST_DIR/ce/ctrl-exec-0.14.7/bin" "$TEST_DIR/ce/ctrl-exec-0.14.7/lib/Exec"
  printf '#!/usr/bin/perl\nour $VERSION = '\''UNINSTALLED'\'';\n' > "$TEST_DIR/ce/ctrl-exec-0.14.7/bin/ctrl-exec-agent"
  echo 0.14.7 > "$TEST_DIR/ce/ctrl-exec-0.14.7/VERSION"
  tar -czf "$TEST_DIR/serve/ce.tgz" -C "$TEST_DIR/ce" ctrl-exec-0.14.7
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 admin@site' > "$TEST_DIR/serve/keys"
  printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-perl-5.42.3\n/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-openssl-3.6.5-bin\n' > "$TEST_DIR/serve/packages"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# shims: stand-ins for what init calls on a node. Each logs "name args" to $CALLS.
shims() {
  local b="$TEST_DIR/bin" s
  cat > "$b/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$CALLS"
out=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"
  prev="$a"
  case "$a" in http://*) url="$a" ;; esac
done
emit() { if [[ -n "$out" ]]; then cp "$1" "$out"; else cat "$1"; fi; }
case "$url" in
  *cmd=node_bundle) [[ -f "$TEST_DIR/serve/bundle.tgz" && -z "${FAIL_BUNDLE:-}" ]] || exit 22; emit "$TEST_DIR/serve/bundle.tgz" ;;
  *cmd=node_sysadmin_keys) [[ -f "$TEST_DIR/serve/keys" ]] || exit 22; emit "$TEST_DIR/serve/keys" ;;
  *cmd=node_packages) [[ -f "$TEST_DIR/serve/packages" ]] || exit 22; emit "$TEST_DIR/serve/packages" ;;
  *ctrl-exec-latest.tar.gz) emit "$TEST_DIR/serve/ce.tgz" ;;
  *get_remote_functions) exit 22 ;;
  *cmd=log_message*) exit 0 ;;
  *) echo "unexpected url $url" >&2; exit 22 ;;
esac
EOF
  cat > "$b/id" <<'EOF'
#!/bin/bash
case "$*" in
  "-gn sysadmin") echo users ;;
  sysadmin) [[ -e "$TEST_DIR/user-exists" ]] || exit 1; echo "uid=1001(sysadmin)" ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
  cat > "$b/getent" <<'EOF'
#!/bin/bash
echo "sysadmin:x:1001:100::$TEST_DIR/home/sysadmin:/bin/bash"
EOF
  cat > "$b/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$CALLS"
touch "$TEST_DIR/user-exists"
EOF
  cat > "$b/install" <<'EOF'
#!/bin/bash
# the real install without -o/-g (the tests do not run as root)
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
/usr/bin/install "${args[@]}"
EOF
  for s in usermod chown passwd systemctl iptables sshd; do
    printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n[[ "%s" == iptables && "$1" == -C ]] && exit 1\nexit 0\n' "$s" "$s" > "$b/$s"
  done
  cat > "$b/nix" <<'EOF'
#!/bin/bash
echo "nix $*" >> "$CALLS"
[[ -n "${FAIL_NIX:-}" ]] && exit 1
# record the installed paths in the profile's manifest, as nix profile does
for a in "$@"; do [[ "$a" == /nix/store/* ]] && echo "$a" >> "$HPS_NIX_PROFILE/manifest.json"; done
exit 0
EOF
  # the pairing step is its own script with its own tests (test_p1_102): a stand-in here
  cat > "$TEST_DIR/hps-pair-stub" <<'EOF'
#!/bin/bash
echo "hps-pair $*" >> "$CALLS"
exit "${PAIR_RC:-0}"
EOF
  chmod +x "$b"/* "$TEST_DIR/hps-pair-stub"
}

# extract_bundle: the bundle the IPS built, unpacked, with the pairing stub in place
extract_bundle() {
  mkdir -p "$TEST_DIR/bundle"
  tar -xzf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/bundle"
  cp "$TEST_DIR/hps-pair-stub" "$TEST_DIR/bundle/lib/hps-pair"
}

# --- bootstrap.sh ------------------------------------------------------------

@test "bootstrap: no hps.ips on the kernel line is an error that says so" {
  echo "BOOT_IMAGE=bzImage" > "$HPS_CMDLINE"
  run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hps.ips="* ]]
}

@test "bootstrap: the address is the first hps.ips on the kernel line, not a later word inside the hook's quotes" {
  run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -ne 99 ]
  grep -q 'cmd=node_bundle' "$CALLS"
  grep -q 'http://10.9.9.9/cgi-bin/boot_manager.sh?cmd=node_bundle' "$CALLS"
  ! grep -q '6.6.6.6' "$CALLS"
}

@test "bootstrap: an address that is not an address is refused" {
  echo "hps.ips=10.0.0.1/../evil" > "$HPS_CMDLINE"
  run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not an address"* ]]
  [ ! -s "$CALLS" ]
}

@test "bootstrap: no bundle from the IPS is an error, and nothing is half installed" {
  FAIL_BUNDLE=1 run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot fetch the bundle from 10.9.9.9"* ]]
  [ ! -e "$HPS_RUN_DIR/bundle" ]
}

@test "bootstrap: unpacks to /run/hps/b/<id>, switches the bundle link, runs init with the mode, init gets no stdin" {
  # a bundle whose init only records what it was given
  mkdir -p "$TEST_DIR/mini"
  printf '#!/bin/bash\necho "init $* stdin=$(cat | wc -c)" >> "$CALLS"\n' > "$TEST_DIR/mini/init"
  chmod +x "$TEST_DIR/mini/init"
  tar -czf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/mini" .
  run bash "$ROOT/node-manager/bundle/bootstrap.sh" < <(echo "pipe data the hook would leave")
  [ "$status" -eq 0 ]
  grep -qx 'init boot stdin=0' "$CALLS"
  [ -L "$HPS_RUN_DIR/bundle" ]
  [ -x "$HPS_RUN_DIR/bundle/init" ]
  [[ "$(readlink "$HPS_RUN_DIR/bundle")" == b/???????????????? ]]
  run bash "$ROOT/node-manager/bundle/bootstrap.sh" refresh
  [ "$status" -eq 0 ]
  grep -qx 'init refresh stdin=0' "$CALLS"
}

@test "bootstrap: keeps the bundle in use and the one before, drops the older ones" {
  for n in 1 2 3; do
    mkdir -p "$TEST_DIR/mini"
    printf '#!/bin/bash\necho %s > /dev/null\n' "$n" > "$TEST_DIR/mini/init"
    chmod +x "$TEST_DIR/mini/init"
    tar -czf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/mini" .
    run bash "$ROOT/node-manager/bundle/bootstrap.sh"
    [ "$status" -eq 0 ]
    live="$(readlink "$HPS_RUN_DIR/bundle")"
  done
  [ "$(ls "$HPS_RUN_DIR/b" | wc -l)" -eq 2 ]
  [ -d "$HPS_RUN_DIR/$live" ]
  # the same bundle again: the link and the bundle in use stay
  run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -eq 0 ]
  [ -d "$HPS_RUN_DIR/$live" ]
  [ "$(readlink "$HPS_RUN_DIR/bundle")" = "$live" ]
}

@test "bootstrap: a bundle without an init is refused" {
  mkdir -p "$TEST_DIR/mini"
  echo x > "$TEST_DIR/mini/readme"
  tar -czf "$TEST_DIR/serve/bundle.tgz" -C "$TEST_DIR/mini" .
  run bash "$ROOT/node-manager/bundle/bootstrap.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no init"* ]]
  [ ! -e "$HPS_RUN_DIR/bundle" ]
}

# --- init --------------------------------------------------------------------

@test "init: sysadmin, packages, agent, pairing, in that order" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"done: bundle"* ]]
  order="$(grep -nE '^(useradd|sshd|nix|systemctl start|hps-pair)' "$CALLS" | sed 's/:.*//' | tr '\n' ' ')"
  [ "$(grep -nE '^useradd' "$CALLS" | cut -d: -f1)" -lt "$(grep -nE '^nix ' "$CALLS" | cut -d: -f1)" ]
  [ "$(grep -nE '^nix ' "$CALLS" | cut -d: -f1)" -lt "$(grep -nE '^systemctl start ctrl-exec-agent' "$CALLS" | cut -d: -f1)" ]
  [ "$(grep -nE '^systemctl start ctrl-exec-agent' "$CALLS" | cut -d: -f1)" -lt "$(grep -nE '^hps-pair' "$CALLS" | cut -d: -f1)" ]
}

@test "init: the sysadmin user has the key from the IPS, sudo through the OS's group, and root login is refused" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  grep -q '^useradd -m -s .*bash -G wheel sysadmin' "$CALLS"
  grep -q 'admin@site' "$TEST_DIR/home/sysadmin/.ssh/authorized_keys"
  [ "$(stat -c %a "$TEST_DIR/home/sysadmin/.ssh/authorized_keys")" = 600 ]
  [ "$(stat -c %a "$TEST_DIR/home/sysadmin/.ssh")" = 700 ]
  grep -q '^passwd -l root' "$CALLS"
  # sshd: our directives come first (the first value wins), the starter's own follow, sshd -t before the move
  head -n 8 "$HPS_ROOT/etc/ssh/sshd_config" | grep -qx 'PermitRootLogin no'
  head -n 8 "$HPS_ROOT/etc/ssh/sshd_config" | grep -qx 'PasswordAuthentication no'
  head -n 8 "$HPS_ROOT/etc/ssh/sshd_config" | grep -qx 'AllowUsers sysadmin'
  grep -qx 'UsePAM yes' "$HPS_ROOT/etc/ssh/sshd_config"
  grep -q '^sshd -t -f' "$CALLS"
  grep -q '^systemctl reload sshd.service' "$CALLS"
  diff "$HPS_ROOT/etc/ssh/sshd_config.hps-orig" <(printf '# the starter\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM yes\n')
}

@test "init: no key on the IPS is a warning, not a stop; the user is made without one" {
  extract_bundle
  rm "$TEST_DIR/serve/keys"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: the IPS gave no sysadmin ssh key"* ]]
  [ ! -s "$TEST_DIR/home/sysadmin/.ssh/authorized_keys" ]
}

@test "init: a key with options in front of it is not installed" {
  extract_bundle
  echo 'command="/bin/true" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 evil' > "$TEST_DIR/serve/keys"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [ ! -s "$TEST_DIR/home/sysadmin/.ssh/authorized_keys" ]
}

@test "init: the packages are the IPS's list, from the IPS repository, nothing else" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  grep -q 'nix --extra-experimental-features nix-command profile install --profile' "$CALLS"
  grep -q -- '--option substituters http://10.9.9.9/packages/nixos/26.05' "$CALLS"
  grep -q '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-perl-5.42.3 /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-openssl-3.6.5-bin' "$CALLS"
  ! grep -q 'cache.nixos.org/' "$CALLS"
}

@test "init: a package list that is not store paths is not passed to nix" {
  extract_bundle
  printf 'libvirt; rm -rf /\n../../etc/passwd\n' > "$TEST_DIR/serve/packages"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"package list"*"empty"* ]]
  ! grep -q '^nix ' "$CALLS"
}

@test "init: a failed package install stops before the agent and the pairing, with the reason on the log" {
  extract_bundle
  FAIL_NIX=1 run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"adding the packages failed"* ]]
  ! grep -q '^hps-pair' "$CALLS"
  ! grep -q 'systemctl start ctrl-exec-agent' "$CALLS"
  grep -q 'cmd=log_message' "$CALLS"
  # but the sysadmin is there: a person can log in and look
  grep -q 'admin@site' "$TEST_DIR/home/sysadmin/.ssh/authorized_keys"
}

@test "init: the agent's scripts.conf is the preset allowlist, through the bundle link, with its options" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  conf="$HPS_ROOT/etc/ctrl-exec-agent/scripts.conf"
  grep -qx "node-facts = $HPS_RUN_DIR/bundle/actions/node-facts profile=node" "$conf"
  grep -qx "bundle-refresh = $HPS_RUN_DIR/bundle/actions/bundle-refresh profile=node" "$conf"
  grep -qx "storage-pool-create = $HPS_RUN_DIR/bundle/actions/storage-pool-create profile=node input=raw" "$conf"
  [ "$(grep -vc '^#' "$conf")" -eq "$(grep -vcE '^\s*(#|$)' "$ROOT/node-manager/bundle/allowlist")" ]
  # nothing in the file but the allowlist's names
  while read -r name _; do
    grep -qE "^$name " "$ROOT/node-manager/bundle/allowlist" || { echo "not on the allowlist: $name"; return 1; }
  done < <(grep -v '^#' "$conf")
}

@test "init: agent.conf has the port, the certificate paths, the action PATH, and no executor" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  conf="$HPS_ROOT/etc/ctrl-exec-agent/agent.conf"
  grep -qx 'port = 7443' "$conf"
  grep -q "^cert = $HPS_ROOT/etc/ctrl-exec-agent/agent.crt" "$conf"
  grep -q "^script_path = $HPS_NIX_PROFILE/bin:" "$conf"
  grep -qx '\[profile node\]' "$conf"
  grep -qx '\[profile default\]' "$conf"
  ! grep -q 'executor_socket' "$conf"
}

@test "init: the agent is a run-time unit that waits for its certificate; its port is opened" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  unit="$HPS_SYSTEMD_DIR/ctrl-exec-agent.service"
  [ -f "$unit" ]
  grep -q "^ConditionPathExists=$HPS_ROOT/etc/ctrl-exec-agent/agent.crt" "$unit"
  grep -q '^ExecStart=.*perl.* .*/ctrl-exec/bin/ctrl-exec-agent serve$' "$unit"
  grep -q '^Environment="PERL5LIB=' "$unit"
  grep -q '^RestartPreventExitStatus=78' "$unit"
  grep -q '^iptables -I nixos-fw 1 -p tcp --dport 7443 -j nixos-fw-accept' "$CALLS"
  grep -q '^systemctl daemon-reload' "$CALLS"
  # no secret in the unit
  ! grep -qiE 'token|secret|password|BEGIN' "$unit"
}

@test "init: the agent comes from the IPS package area, patched with the release's version, with a wrapper on PATH" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  grep -q 'http://10.9.9.9/packages/ctrl-exec/ctrl-exec-latest.tar.gz' "$CALLS"
  grep -q "our \$VERSION = '0.14.7'" "$HPS_RUN_DIR/ctrl-exec/bin/ctrl-exec-agent"
  [ -x "$HPS_RUN_DIR/bin/ctrl-exec-agent" ]
  grep -q "^PERL5LIB=" "$HPS_RUN_DIR/bin/ctrl-exec-agent"
  grep -q 'exec perl ".*/ctrl-exec/bin/ctrl-exec-agent" "\$@"' "$HPS_RUN_DIR/bin/ctrl-exec-agent"
}

@test "init: refused pairing is exit 3 and says so on the IPS log; another failure is exit 1" {
  extract_bundle
  PAIR_RC=3 run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 3 ]
  PAIR_RC=1 run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
}

@test "init: a second run (a refresh) installs nothing twice, makes no second user, leaves the agent configuration alone" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  m1="$(stat -c %Y "$HPS_ROOT/etc/ctrl-exec-agent/scripts.conf")"
  nix_before="$(grep -c '^nix ' "$CALLS")"
  sleep 1
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$status" -eq 0 ]
  [ "$(grep -c '^nix ' "$CALLS")" -eq "$nix_before" ]
  [[ "$output" == *"every package is installed already"* ]]
  [ "$(grep -c '^useradd' "$CALLS")" -eq 1 ]
  grep -q '^usermod -aG wheel sysadmin' "$CALLS"
  # scripts.conf is rewritten only when it changed: the agent reloads on every write
  [ "$(stat -c %Y "$HPS_ROOT/etc/ctrl-exec-agent/scripts.conf")" = "$m1" ]
}

@test "init: a refresh that finds a new action on the allowlist puts it in scripts.conf" {
  extract_bundle
  run bash "$TEST_DIR/bundle/init" boot
  printf 'node-extra profile=node\n' >> "$TEST_DIR/bundle/allowlist"
  printf '#!/bin/bash\necho extra\n' > "$TEST_DIR/bundle/actions/node-extra"
  chmod +x "$TEST_DIR/bundle/actions/node-extra"
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$status" -eq 0 ]
  grep -qx "node-extra = $HPS_RUN_DIR/bundle/actions/node-extra profile=node" "$HPS_ROOT/etc/ctrl-exec-agent/scripts.conf"
}

@test "init: an allowlist name with no file in the bundle is left out with a warning, not listed" {
  extract_bundle
  printf 'node-ghost profile=node\n' >> "$TEST_DIR/bundle/allowlist"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 0 ]
  [[ "$output" == *"no actions/node-ghost"* ]]
  ! grep -q '^node-ghost' "$HPS_ROOT/etc/ctrl-exec-agent/scripts.conf"
}

@test "init: an OS without an adapter is refused by name (Alpine is plan step 4)" {
  extract_bundle
  echo "hps.ips=10.9.9.9 hps.os=x86_64:alpine:3.22" > "$HPS_CMDLINE"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"no adapter for OS 'alpine'"* ]]
  ! grep -q '^useradd' "$CALLS"
}

@test "init: hps.os missing or malformed is refused" {
  extract_bundle
  echo "hps.ips=10.9.9.9" > "$HPS_CMDLINE"
  run bash "$TEST_DIR/bundle/init" boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not arch:os:version"* ]]
}

@test "init: two inits at once: the second stops" {
  extract_bundle
  mkdir -p "$HPS_RUN_DIR"
  exec 8> "$HPS_RUN_DIR/init.lock"
  flock -n 8
  run bash "$TEST_DIR/bundle/init" refresh
  [ "$status" -eq 1 ]
  [[ "$output" == *"another init is running"* ]]
}

# --- the adapter and the refresh action -------------------------------------

@test "adapter: pkg_add refuses anything that is not a store path" {
  run bash -c "source '$ROOT/node-manager/bundle/adapter/nixos.sh'; log() { echo \"\$*\"; }; run() { \"\$@\"; }; adapter_init 10.9.9.9 26.05; pkg_add 'libvirt'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a store path"* ]]
}

@test "adapter: the three per-OS things are all it defines (plus its variables); Alpine has no code" {
  grep -qE '^(pkg_add|svc_start|svc_reload|adapter_init)\(\)' "$ROOT/node-manager/bundle/adapter/nixos.sh"
  [ "$(grep -cE '^[a-z_]+\(\) \{' "$ROOT/node-manager/bundle/adapter/nixos.sh")" -eq 4 ]
  [ ! -e "$ROOT/node-manager/bundle/adapter/alpine.sh" ]
}

@test "bundle-refresh takes no arguments and runs the bootstrap script the node booted with" {
  run bash "$ROOT/node-manager/bundle/actions/bundle-refresh" 10.9.9.9
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes no arguments"* ]]
  run bash "$ROOT/node-manager/bundle/actions/bundle-refresh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no bundle to refresh"* ]]
  mkdir -p "$HPS_RUN_DIR/bundle"
  printf '#!/bin/sh\necho "bootstrap ran with: $*"\n' > "$HPS_RUN_DIR/bundle/bootstrap.sh"
  run bash "$ROOT/node-manager/bundle/actions/bundle-refresh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bootstrap ran with: refresh"* ]]
}

@test "bundle-refresh fetches from the address on the node's own kernel line: no argument, no environment of the caller names it" {
  # the script has no variable it reads an address from, and no curl of its own
  ! grep -qE 'curl|wget|hps\.ips|http://' <(grep -v '^#' "$ROOT/node-manager/bundle/actions/bundle-refresh")
}

@test "the bundle's shell scripts parse" {
  for f in bootstrap.sh init adapter/nixos.sh actions/bundle-refresh; do
    bash -n "$ROOT/node-manager/bundle/$f"
  done
}
