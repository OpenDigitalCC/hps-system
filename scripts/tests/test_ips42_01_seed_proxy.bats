#!/usr/bin/env bats
#
# IPS-42 row 1: the workload flavours' seeds give the lab proxy to services as
# well as login shells: the systemd manager's DefaultEnvironment (system and
# user), /etc/gitconfig, and for the container host flavours the podman and
# docker service drop-ins. The flavours and their renderer belong to the
# hps-workloads skill (outside this repository); its own test renders every
# flavour and checks the seed, so this runs it and skips where it is absent.
# No network, no VM.

bats_require_minimum_version 1.5.0

@test "every flavour renders a seed that sets the proxy for services, git and the container tools" {
  SKILL="${HPS_SKILL_DIR:-/home/claude/.claude/skills/hps-workloads}"
  [ -f "$SKILL/bin/test-render.sh" ] || skip "no $SKILL/bin/test-render.sh"
  W="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-01.XXXXXX")"
  run bash "$SKILL/bin/test-render.sh" "$W"
  rm -rf "$W"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/etc/systemd/system.conf.d/hps-proxy.conf carries DefaultEnvironment with both cases"* ]]
  [[ "$output" == *"/etc/gitconfig sets http.proxy"* ]]
  [[ "$output" == *"/etc/systemd/system/docker.service.d/hps-proxy.conf carries Environment"* ]]
  [[ "$output" != *"FAIL"* ]]
}
