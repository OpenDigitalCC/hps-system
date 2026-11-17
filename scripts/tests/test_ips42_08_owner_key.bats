#!/usr/bin/env bats
#
# IPS-42 row 8: the skill's render step puts the owner's public key in by default
# (HPS_OWNER_KEY, else ~/.config/hps-workloads/owner.pub), --owner-key replaces it,
# --no-owner-key leaves it out, a missing setting is said, a private key is
# refused. The renderer belongs to the skill (outside this repository); its own
# test checks all of it, so this runs it and skips where it is absent. No
# network, no VM.

bats_require_minimum_version 1.5.0

@test "the renderer adds the owner's key by default and refuses a private key" {
  SKILL="${HPS_SKILL_DIR:-/home/claude/.claude/skills/hps-workloads}"
  [ -f "$SKILL/bin/test-render.sh" ] || skip "no $SKILL/bin/test-render.sh"
  W="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-08.XXXXXX")"
  run bash "$SKILL/bin/test-render.sh" "$W"
  rm -rf "$W"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok   owner key: default from HPS_OWNER_KEY (2 2)"* ]]
  [[ "$output" == *"ok   owner key: default from ~/.config/hps-workloads/owner.pub (2 2)"* ]]
  [[ "$output" == *"ok   owner key: --no-owner-key (1 1)"* ]]
  [[ "$output" == *"ok   owner key: none set is said"* ]]
  [[ "$output" == *"ok   owner key: a private key is refused"* ]]
  [[ "$output" != *"FAIL"* ]]
}
