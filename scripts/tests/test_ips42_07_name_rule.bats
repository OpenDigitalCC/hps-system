#!/usr/bin/env bats
#
# IPS-42 row 7: no rename verb; the skill and the docs say plainly that the date
# suffix of a workload name marks "destroy me after this task", and that a VM
# which may live beyond one task is named without the date. The skill lives
# outside this repository, so its half is checked where it is present.

@test "docs/WORKLOADS.md states the date suffix rule and that there is no rename" {
  doc="${BATS_TEST_DIRNAME}/../../docs/WORKLOADS.md"
  grep -q 'date suffix marks "destroy me after this task", not "made on"' "$doc"
  grep -q 'named without the date from the start' "$doc"
  grep -q 'there is no$' "$doc"
  grep -q '^`rename` verb' "$doc"
  run grep -c 'hps-workload rename' "$doc"
  [ "$output" = "0" ]
}

@test "the workload tool has no rename verb" {
  run perl -I"${BATS_TEST_DIRNAME}/../../lib/perl" "${BATS_TEST_DIRNAME}/../../bin/hps-workload" rename a b
  [ "$status" -eq 2 ]
}

@test "the skill says the date means destroy me and names a long-lived VM without it" {
  SKILL="${HPS_SKILL_DIR:-/home/claude/.claude/skills/hps-workloads}"
  [ -f "$SKILL/SKILL.md" ] || skip "no $SKILL/SKILL.md"
  grep -q 'The date suffix means "destroy me after this task"' "$SKILL/SKILL.md"
  grep -q 'named without the date from the start' "$SKILL/SKILL.md"
  grep -q 'cannot be renamed' "$SKILL/SKILL.md"
}
