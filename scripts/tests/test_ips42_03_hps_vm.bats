#!/usr/bin/env bats
#
# IPS-42 row 3: hps-vm, the hps-workloads skill's helper that runs a local script
# on a workload VM (optionally as another user) and copies a container image into
# it. It belongs to the skill (outside this repository); its own test uses a stub
# ssh wrapper and stub docker and podman and checks every argument pattern, the
# remote commands and what reaches stdin. This runs it, and skips where the skill
# is absent. No network, no VM.

bats_require_minimum_version 1.5.0

@test "hps-vm checks every argument and runs the fixed remote commands" {
  SKILL="${HPS_SKILL_DIR:-/home/claude/.claude/skills/hps-workloads}"
  [ -f "$SKILL/bin/test-vm.sh" ] || skip "no $SKILL/bin/test-vm.sh"
  W="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-03.XXXXXX")"
  run bash "$SKILL/bin/test-vm.sh" "$W"
  rm -rf "$W"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL OK"* ]]
  [[ "$output" != *"FAIL"* ]]
  [[ "$output" == *"refused (load-image, a shell word)"* ]]
  [[ "$output" == *"hps-ssh without arguments is still usage (2)"* ]]
}
