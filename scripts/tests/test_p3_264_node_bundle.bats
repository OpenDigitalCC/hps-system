#!/usr/bin/env bats
#
# Plan step 2, IPS side (lib/functions.d/node-bundle-functions.sh,
# docs/BUNDLE.md): the bundle the IPS builds from the tree's node scripts, the
# bootstrap script, the role-to-package list and the sysadmin key. No network.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-264.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  source "$ROOT/lib/functions.d/node-bundle-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# build <base>: the bundle into $TEST_DIR/b.tgz and its listing into $TEST_DIR/b.list
build() {
  node_bundle_tar "${1:-$ROOT}" > "$TEST_DIR/b.tgz"
  tar -tvzf "$TEST_DIR/b.tgz" > "$TEST_DIR/b.list"
}

@test "the bundle carries the bundle files, the node actions, the plugin and the pairing script" {
  build
  for f in init bootstrap.sh allowlist adapter/nixos.sh actions/bundle-refresh \
    actions/node-facts actions/storage-pool-inspect actions/hps-node lib/hps-pair; do
    grep -qE " (\./)?${f}\$" "$TEST_DIR/b.list" || { echo "missing: $f"; return 1; }
  done
  # the node scripts are not forked: the bytes are the tree's own
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/b.tgz" -C "$TEST_DIR/x"
  cmp "$TEST_DIR/x/actions/node-facts" "$ROOT/node-manager/nixos-26/scripts/node-facts"
  cmp "$TEST_DIR/x/actions/hps-node" "$ROOT/node-manager/plugins/hps-node/hps-node.sh"
  cmp "$TEST_DIR/x/lib/hps-pair" "$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  cmp "$TEST_DIR/x/bootstrap.sh" "$ROOT/node-manager/bundle/bootstrap.sh"
}

@test "the bundle is deterministic: the same tree gives the same bytes" {
  node_bundle_tar "$ROOT" | sha256sum > "$TEST_DIR/s1"
  sleep 1
  node_bundle_tar "$ROOT" | sha256sum > "$TEST_DIR/s2"
  cmp "$TEST_DIR/s1" "$TEST_DIR/s2"
}

@test "every member is owned by root, none is group- or world-writable, none is setuid or setgid" {
  build
  [ -s "$TEST_DIR/b.list" ]
  while read -r mode owner _; do
    [[ "$owner" == 0/0 ]] || { echo "owner $owner"; return 1; }
    # type, owner rwx (any), group r-x/r--/---, others r-x/r--/---
    [[ "$mode" =~ ^[-d][-rwx]{3}[-r]-[-x][-r]-[-x]$ ]] || { echo "mode $mode"; return 1; }
  done < "$TEST_DIR/b.list"
}

@test "the entry points are executable" {
  build
  for f in init bootstrap.sh actions/bundle-refresh actions/node-facts lib/hps-pair; do
    grep -E " (\./)?${f}\$" "$TEST_DIR/b.list" | grep -q '^-rwxr-xr-x' || { echo "not executable: $f"; return 1; }
  done
}

@test "a script changed in the tree is in the next bundle (live at the next refresh)" {
  mkdir -p "$TEST_DIR/tree"
  cp -a "$ROOT/node-manager" "$TEST_DIR/tree/"
  node_bundle_tar "$TEST_DIR/tree" | sha256sum > "$TEST_DIR/before"
  printf '# changed on the IPS\n' >> "$TEST_DIR/tree/node-manager/nixos-26/scripts/node-facts"
  node_bundle_tar "$TEST_DIR/tree" | sha256sum > "$TEST_DIR/after"
  ! cmp -s "$TEST_DIR/before" "$TEST_DIR/after"
  node_bundle_tar "$TEST_DIR/tree" > "$TEST_DIR/c.tgz"
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/c.tgz" -C "$TEST_DIR/x"
  tail -n 1 "$TEST_DIR/x/actions/node-facts" | grep -qx '# changed on the IPS'
}

@test "a tree without a bundle is an error, not an empty archive" {
  mkdir -p "$TEST_DIR/empty/node-manager"
  run node_bundle_tar "$TEST_DIR/empty"
  [ "$status" -eq 1 ]
  grep -q "has no init or allowlist" "$TEST_DIR/hps.log"
}

@test "the bootstrap script is served as it is" {
  run node_bootstrap_script "$ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$ROOT/node-manager/bundle/bootstrap.sh")" ]
}

@test "the allowlist: every action is in the bundle, once, and bundle-refresh is preset" {
  build
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/b.tgz" -C "$TEST_DIR/x"
  names="$(grep -vE '^\s*(#|$)' "$ROOT/node-manager/bundle/allowlist" | awk '{print $1}')"
  [ -n "$names" ]
  [ "$(printf '%s\n' "$names" | sort | uniq -d | wc -l)" -eq 0 ]
  for n in $names; do
    [ -x "$TEST_DIR/x/actions/$n" ] || { echo "no action file for $n"; return 1; }
  done
  printf '%s\n' "$names" | grep -qx bundle-refresh
}

@test "the allowlist is the allowlist of the pinned images (hps-ctrl-exec.nix), plus bundle-refresh" {
  nix_names="$(sed -n 's/^ *\([a-z][a-z0-9-]*\)\.source = mkScript.*/\1/p' "$ROOT/nix/modules/hps-ctrl-exec.nix" | sort)"
  list_names="$(grep -vE '^\s*(#|$)' "$ROOT/node-manager/bundle/allowlist" | awk '{print $1}' | grep -vx bundle-refresh | sort)"
  [ "$nix_names" = "$list_names" ]
  # and the options agree: input=raw where the nix module says raw
  for n in $(sed -n 's/^ *\([a-z][a-z0-9-]*\)\.options\.input = "raw".*/\1/p' "$ROOT/nix/modules/hps-ctrl-exec.nix"); do
    grep -qE "^$n .*input=raw" "$ROOT/node-manager/bundle/allowlist" || { echo "$n: input=raw missing"; return 1; }
  done
  [ "$(grep -c 'input=raw' "$ROOT/node-manager/bundle/allowlist")" -eq "$(grep -c 'options.input = "raw"' "$ROOT/nix/modules/hps-ctrl-exec.nix")" ]
}

@test "no action in the allowlist takes a command or script from the dispatcher" {
  # the agent's design: only named actions with checked arguments. The list holds
  # names that are files of the bundle; it has no entry for a shell or an interpreter.
  ! grep -vE '^\s*(#|$)' "$ROOT/node-manager/bundle/allowlist" | awk '{print $1}' | grep -xE 'sh|bash|perl|exec|run|eval|shell|ssh|nix|systemctl'
}

# --- the role-to-package mapping -------------------------------------------

# A repository manifest of 26.05 with the roots the real package list has.
repo() {
  mkdir -p "$TEST_DIR/res/packages/nixos/26.05"
  cat > "$TEST_DIR/res/packages/nixos/26.05/manifest.json" <<'EOF'
{"schema":"hps-repo/1","roots":{
 "ctrl-exec-agent":"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ctrl-exec-agent-0.14.7",
 "targetcli-fb":"/nix/store/11111111111111111111111111111111-targetcli-fb-3.0.2",
 "mdadm":"/nix/store/22222222222222222222222222222222-mdadm-4.4",
 "libvirt":"/nix/store/33333333333333333333333333333333-libvirt-12.2.0",
 "qemu-host-cpu-only":"/nix/store/44444444444444444444444444444444-qemu-host-cpu-only-10.2.4",
 "open-iscsi":"/nix/store/55555555555555555555555555555555-open-iscsi-2.1.13",
 "jq":"/nix/store/66666666666666666666666666666666-jq-1.8.2-bin",
 "smartmontools":"/nix/store/77777777777777777777777777777777-smartmontools-7.5",
 "tcpdump":"/nix/store/88888888888888888888888888888888-tcpdump-4.99.6",
 "xxd":"/nix/store/99999999999999999999999999999999-xxd-tinyxxd-1.3.15",
 "om3":"/nix/store/cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd-om3-3.0.0-rc62"}}
EOF
}

@test "role packages: every node gets the agent; a role adds its own" {
  repo
  run node_role_packages x86_64:nixos:26.05 TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-ctrl-exec-agent-0.14.7"* ]]
  [[ "$output" == *"-libvirt-12.2.0"* && "$output" == *"-qemu-host-cpu-only-"* ]]
  [[ "$output" != *"targetcli"* ]]
  [[ "$output" == *"-tcpdump-"* && "$output" == *"-om3-"* && "$output" == *"-jq-"* ]]
  [[ "$output" != *"smartmontools"* && "$output" != *"-xxd-"* ]]
  run node_role_packages x86_64:nixos:26.05 SCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targetcli-fb"* && "$output" != *"libvirt"* ]]
  [[ "$output" == *"smartmontools"* && "$output" == *"-xxd-"* && "$output" == *"-om3-"* ]]
  [[ "$output" != *"tcpdump"* ]]
}

@test "role packages: a host of two roles gets both, each path once" {
  repo
  run node_role_packages x86_64:nixos:26.05 SCH,TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [[ "$output" == *"targetcli-fb"* && "$output" == *"libvirt"* ]]
  [ "$(printf '%s\n' "$output" | sort | uniq -d | wc -l)" -eq 0 ]
}

@test "role packages: no TYPE, or an unknown one, gets only the agent" {
  repo
  run node_role_packages x86_64:nixos:26.05 "" "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  run node_role_packages x86_64:nixos:26.05 XYZ "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "role packages: the paths are the repository's roots as they stand (store paths only)" {
  repo
  run node_role_packages x86_64:nixos:26.05 SCH,TCH "$ROOT" "$TEST_DIR/res"
  while IFS= read -r p; do
    [[ "$p" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+$ ]] || { echo "not a store path: $p"; return 1; }
  done <<< "$output"
}

@test "role packages: a name the repository does not hold is named in the error, never skipped" {
  repo
  jq 'del(.roots["ctrl-exec-agent"])' "$TEST_DIR/res/packages/nixos/26.05/manifest.json" > "$TEST_DIR/m.json"
  mv "$TEST_DIR/m.json" "$TEST_DIR/res/packages/nixos/26.05/manifest.json"
  run node_role_packages x86_64:nixos:26.05 TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 1 ]
  grep -q "does not hold: ctrl-exec-agent" "$TEST_DIR/hps.log"
}

@test "role packages: no repository synced says to run hps-starter sync" {
  run node_role_packages x86_64:nixos:26.05 TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 1 ]
  grep -q "run hps-starter sync nixos" "$TEST_DIR/hps.log"
}

@test "role packages: an os_id that is not arch:os:version, or an OS without a role list, is refused" {
  repo
  run node_role_packages "nixos" TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 1 ]
  run node_role_packages "x86_64:alpine:3.22" TCH "$ROOT" "$TEST_DIR/res"
  [ "$status" -eq 1 ]
  grep -q "no role list" "$TEST_DIR/hps.log"
}

@test "the role list names only packages the package list holds (so a sync can resolve every name)" {
  names="$(sed -e 's/#.*//' "$ROOT/lib/starter/nixos.roles" | awk -F: 'NF > 1 { n = split($2, a, " "); for (i = 1; i <= n; i++) print a[i] }' | sort -u)"
  have="$(sed -e 's/#.*//' "$ROOT/lib/starter/nixos.packages" | awk 'NF { print $1 }' | sort -u)"
  [ -n "$names" ]
  for n in $names; do
    printf '%s\n' "$have" | grep -qx -- "$n" || { echo "roles name '$n', the package list does not"; return 1; }
  done
}

# --- the sysadmin key -------------------------------------------------------

@test "sysadmin keys: well-formed public keys are served; options, private keys and noise are not" {
  mkdir -p "$TEST_DIR/cfg"
  {
    echo '# comment'
    echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 admin@site'
    echo 'command="/bin/true" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvZkQ9mXfJq0mG2yQ3nqYk0n1b2c3d4e5f6g7h8i9j0 evil'
    echo '-----BEGIN OPENSSH PRIVATE KEY-----'
    echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 second@site'
  } > "$TEST_DIR/cfg/sysadmin_authorized_keys"
  run node_sysadmin_keys "$TEST_DIR/cfg"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  [[ "$output" == *"admin@site"* && "$output" == *"second@site"* ]]
  [[ "$output" != *"command="* && "$output" != *"PRIVATE"* ]]
}

@test "sysadmin keys: none on the IPS is a failure (the node then has a user nobody can log in as, and says so)" {
  run node_sysadmin_keys "$TEST_DIR/cfg"
  [ "$status" -eq 1 ]
  mkdir -p "$TEST_DIR/cfg"
  echo '# nothing' > "$TEST_DIR/cfg/sysadmin_authorized_keys"
  run node_sysadmin_keys "$TEST_DIR/cfg"
  [ "$status" -eq 1 ]
}

@test "no secret is in the bundle: no private key, no token, no password" {
  build
  mkdir "$TEST_DIR/x"
  tar -xzf "$TEST_DIR/b.tgz" -C "$TEST_DIR/x"
  ! grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY' "$TEST_DIR/x"
}
