#!/usr/bin/env bats
#
# CS-3.5: lab/osvc-rig-1.sh and lab/osvc-rig-2.sh against a fake hps-run.sh that
# models the node scripts: the rig scripts report PASS when no peer instance
# appears, FAIL (exit 1) when a command starts one on the peer, and restore the
# frozen state and delete rig0.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-76.XXXXXX")"
  export ST="$T/state"
  mkdir -p "$ST" "$T/bin"
  export HPS_RUN="$T/hps-run.sh"
  export RIG_WAIT=2 RIG_POLL=1
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
  chmod +x "$T/bin/sleep"
  export PATH="$T/bin:$PATH"
  cat > "$HPS_RUN" <<'SH'
#!/usr/bin/env bash
# fake hps-run.sh <host> <script> [args]; hosts: owner (own-1), peer (peer-1)
host=$1; script=$2; shift 2
echo "run $host $script $*" >> "$ST/calls"
name=own-1; [[ "$host" == peer ]] && name=peer-1
av() { [[ -f "$ST/avail_$1" ]] && cat "$ST/avail_$1" || echo absent; }
inst() { local a; a=$(av "$1"); if [[ "$a" == absent ]]; then echo '{}'; else echo "{\"rig0\":{\"status\":{\"avail\":\"$a\"}}}"; fi; }
case "$script" in
  osvc-status)
    fr=no; [[ -f "$ST/frozen" ]] && fr=yes
    echo "== om daemon status --format json"
    echo "{\"cluster\":{\"node\":{\"own-1\":{\"instance\":$(inst own)},\"peer-1\":{\"instance\":$(inst peer)}}}}"
    echo "== om mon --format json"
    echo "{}"
    echo "OSVC $name peers=1 beating=1 stale=- frozen=$fr" ;;
  osvc-object-set) echo down > "$ST/avail_own" ;;
  osvc-object-start) echo up > "$ST/avail_own" ;;
  osvc-object-stop) echo down > "$ST/avail_own" ;;
  osvc-object-delete) rm -f "$ST/avail_own" "$ST/avail_peer" ;;
  osvc-freeze) touch "$ST/frozen" ;;
  osvc-thaw) rm -f "$ST/frozen" ;;
  osvc-rig-probe)
    case "$1" in
      drain) touch "$ST/frozen"; echo down > "$ST/avail_own"
             [[ "${BAD:-}" == drain ]] && echo up > "$ST/avail_peer" ;;
      thaw-cluster) [[ "${BAD:-}" == thaw ]] && echo up > "$ST/avail_own" ;;
      plain-start) echo up > "$ST/avail_own"
             [[ "${BAD:-}" == plain-start ]] && echo up > "$ST/avail_peer" ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$HPS_RUN"
}

teardown() {
  rm -rf "$T"
}

@test "rig 1 passes on a node that behaves, deletes rig0 and thaws what it froze" {
  run -0 bash "$ROOT/lab/osvc-rig-1.sh" owner
  [[ "$output" == *"PASS: start --local succeeds on a frozen node"* ]]
  [[ "$output" == *"PASS: rig0 is up after the --local start (frozen node)"* ]]
  [[ "$output" == *"PASS: thawing the node does not start rig0"* ]]
  [[ "$output" != *"FAIL:"* ]]
  [ ! -e "$ST/avail_own" ]
  [ ! -e "$ST/frozen" ]
}

@test "rig 1 leaves a node that was frozen before the test frozen" {
  touch "$ST/frozen"
  run -0 bash "$ROOT/lab/osvc-rig-1.sh" owner
  [[ "$output" == *"SKIP: thaw check"* ]]
  [ -e "$ST/frozen" ]
}

@test "rig 1 fails when the object does not come up under freeze" {
  sed -i 's/osvc-object-start) echo up/osvc-object-start) echo down/' "$HPS_RUN"
  run -1 bash "$ROOT/lab/osvc-rig-1.sh" owner
  [[ "$output" == *"FAIL: rig0 is up after the --local start"* ]]
}

@test "rig 2 passes with a peer when nothing starts there" {
  run -0 bash "$ROOT/lab/osvc-rig-2.sh" owner peer
  [[ "$output" == *"PASS: after drain: rig0 never up on the peer"* ]]
  [[ "$output" == *"PASS: after cluster thaw: rig0 never up on the peer"* ]]
  [[ "$output" == *"PASS: after a plain start: rig0 never up on the peer"* ]]
  [[ "$output" != *"FAIL:"* ]]
  [ ! -e "$ST/avail_own" ]
  [ ! -e "$ST/frozen" ]
}

@test "rig 2 fails, naming the finding's text, when a plain start puts an instance on the peer" {
  BAD=plain-start run -1 bash "$ROOT/lab/osvc-rig-2.sh" owner peer
  [[ "$output" == *"FAIL: after a plain start: rig0 never up on the peer"* ]]
  [[ "$output" == *"started a service on a peer"* ]]
}

@test "rig 2 fails when drain puts an instance on the peer" {
  BAD=drain run -1 bash "$ROOT/lab/osvc-rig-2.sh" owner peer
  [[ "$output" == *"FAIL: after drain"* ]]
}

@test "rig 2 fails when a cluster thaw restarts the object on the owner" {
  BAD=thaw run -1 bash "$ROOT/lab/osvc-rig-2.sh" owner peer
  [[ "$output" == *"FAIL: cluster thaw does not restart rig0"* ]]
}

@test "rig 2 without a peer skips the peer checks and says so" {
  run -0 bash "$ROOT/lab/osvc-rig-2.sh" owner
  [[ "$output" == *"SKIP: after drain (no peer given)"* ]]
}

@test "the rig scripts call only allowlisted node scripts" {
  run -0 bash "$ROOT/lab/osvc-rig-2.sh" owner peer
  local s
  for s in $(awk '{print $3}' "$ST/calls" | sort -u); do
    grep -qF "$s.source = mkScript" "$ROOT/nix/modules/hps-ctrl-exec.nix" || { echo "not allowlisted: $s"; return 1; }
  done
}
