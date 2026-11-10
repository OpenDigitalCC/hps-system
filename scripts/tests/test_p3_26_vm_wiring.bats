#!/usr/bin/env bats
#
# CS-3.3: wiring and hygiene of the VM-lifecycle scripts: allowlist entries,
# no real values, --force and virsh destroy only where documented.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SD="$ROOT/node-manager/nixos-26/scripts"
SCRIPTS="image-fetch vm-define vm-image-write vm-start vm-stop vm-status vm-undefine vm-console-log vm-confinement-report"
NIX="$ROOT/nix/modules/hps-ctrl-exec.nix"

# code <script>: the script without comment lines.
code() {
  grep -v '^[[:space:]]*#' "$SD/$1"
}

@test "every script is allowlisted under profile node, after a # CS-3.3 comment that follows the CS-3.2 block" {
  local s
  grep -q '# CS-3.3' "$NIX"
  [ "$(grep -n '# CS-3.3' "$NIX" | head -1 | cut -d: -f1)" -gt "$(grep -n 'mirror-detach-leg.options.profile' "$NIX" | cut -d: -f1)" ]
  for s in $SCRIPTS; do
    grep -qF "$s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$NIX"
    grep -qF "$s.options.profile = \"node\";" "$NIX"
    [ "$(grep -cF "$s.source" "$NIX")" -eq 1 ]
  done
}

@test "none of the CS-3.3 scripts reads an approval document, so none takes raw input" {
  local s
  for s in $SCRIPTS; do
    run ! grep -F "$s.options.input" "$NIX"
  done
}

@test "every script is executable, env shebang, set -euo pipefail, shellcheck clean, no library sourcing" {
  local s
  for s in $SCRIPTS; do
    [ -x "$SD/$s" ]
    [ "$(head -1 "$SD/$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$SD/$s"
    shellcheck -S warning "$SD/$s"
    run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  done
}

@test "no script holds a real host name, an IP address, a password or a key" {
  local s
  for s in $SCRIPTS; do
    run ! grep -nE 'password|PRIVATE KEY|secret=' "$SD/$s"
    run ! grep -nE '(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$SD/$s"
    run ! grep -nEi '[a-z0-9-]+\.(com|net|org|io|eu|uk|lan|local|internal)([^a-z]|$)' "$SD/$s"
  done
}

@test "--force appears in code only in vm-image-write and vm-stop" {
  local s
  for s in $SCRIPTS; do
    case "$s" in
      vm-image-write | vm-stop) code "$s" | grep -q -- '--force' ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -- '--force'" ;;
    esac
  done
}

@test "virsh destroy and undefine each appear in one script only, and destroy only behind --force" {
  local s
  for s in $SCRIPTS; do
    case "$s" in
      vm-stop) ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'virsh.* destroy'" ;;
    esac
    case "$s" in
      vm-undefine) ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'virsh.* undefine'" ;;
    esac
  done
  code vm-stop | grep -B6 'run virsh -c qemu:///system destroy' | grep -q 'FORCE == 0'
}

@test "only the disk-writing script runs qemu-img, only image-fetch runs curl, nothing here touches zpool, mdadm, wipefs or dd; zfs only in image-fetch (its images dataset)" {
  local s
  for s in $SCRIPTS; do
    run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])(zpool|mdadm|wipefs|dd|mkfs[.a-z0-9]*)[ ]'"
    case "$s" in
      image-fetch) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])zfs ' | grep -vE 'zfs (list|create|get|set|mount) |command -v zfs '" ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])zfs '" ;;
    esac
    case "$s" in
      vm-image-write) ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'qemu-img'" ;;
    esac
    case "$s" in
      image-fetch) ;;
      *) run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E '(^|[ (])curl '" ;;
    esac
  done
}

@test "the read-only scripts call no virsh verb that changes state" {
  local s
  for s in vm-status vm-console-log vm-confinement-report; do
    run ! bash -c "grep -v '^[[:space:]]*#' '$SD/$s' | grep -E 'virsh.* (start|shutdown|destroy|define|undefine|reboot|suspend|resume)'"
  done
}

@test "the documented docs exist and name every script" {
  local s
  [ -f "$ROOT/docs/VM-LIFECYCLE.md" ]
  for s in $SCRIPTS; do
    grep -q "$s" "$ROOT/docs/VM-LIFECYCLE.md"
  done
  grep -q 'Node script: vm-confinement-report' "$ROOT/docs/CONFINEMENT.md"
}
