#!/usr/bin/env bats
#
# CS-2.1: iscsi-export, iscsi-unexport, iscsi-status against a stateful
# targetcli shim. Proves the targetcli sequence, the default portal removal,
# idempotence (a second run issues no create), argument validation, unexport
# deleting the target and its own backstore only.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-35.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zfs
  p2_shim_targetcli
  printf 'lab/enc/t0\nlab/enc/t1\nlab/enc\n' > "$STATE/datasets"
  printf 'lab/enc/t0\nlab/enc/t1\n' > "$STATE/zvols"
  IQN=iqn.2026-11.org.example:lab-t0
  INI=iqn.2026-11.org.example:ips
  PORTAL=10.99.1.20
  ARGS=(lab/enc/t0 --iqn "$IQN" --initiator "$INI" --portal "$PORTAL")
  # shellcheck disable=SC2034
  SCRIPT="$S/iscsi-export"
}

teardown() {
  rm -rf "$TEST_DIR"
}

creates() {
  grep -cE ' (create|delete) ' "$SHIM_LOG" || true
}

@test "all three scripts: executable, env shebang, set -euo pipefail, shellcheck clean" {
  local f
  for f in iscsi-export iscsi-unexport iscsi-status; do
    [ -x "$S/$f" ]
    [ "$(head -1 "$S/$f")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$S/$f"
    shellcheck -S warning "$S/$f"
  done
}

@test "export: backstore, target, lun, acl, portal in that order, default portal removed, saveconfig" {
  run bash "$S/iscsi-export" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -qxF 'targetcli /backstores/block create lab_enc_t0 /dev/zvol/lab/enc/t0' "$SHIM_LOG"
  grep -qxF "targetcli /iscsi create $IQN" "$SHIM_LOG"
  grep -qxF "targetcli /iscsi/$IQN/tpg1/luns create /backstores/block/lab_enc_t0" "$SHIM_LOG"
  grep -qxF "targetcli /iscsi/$IQN/tpg1/acls create $INI" "$SHIM_LOG"
  grep -qxF "targetcli /iscsi/$IQN/tpg1/portals create $PORTAL" "$SHIM_LOG"
  grep -qxF "targetcli /iscsi/$IQN/tpg1/portals delete 0.0.0.0 3260" "$SHIM_LOG"
  grep -qxF 'targetcli saveconfig' "$SHIM_LOG"
  local seq
  seq=$(grep -E ' (create|delete) |saveconfig' "$SHIM_LOG" | awk '{print $2 " " $3}' | tr '\n' ',')
  [ "$seq" = "/backstores/block create,/iscsi create,/iscsi/$IQN/tpg1/luns create,/iscsi/$IQN/tpg1/acls create,/iscsi/$IQN/tpg1/portals create,/iscsi/$IQN/tpg1/portals delete,saveconfig ," ]
}

@test "export: a second identical run changes nothing (idempotent), only saveconfig" {
  run bash "$S/iscsi-export" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/iscsi-export" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(creates)" -eq 0 ]
  run ! grep -E ' (create|delete) ' "$SHIM_LOG"
}

@test "export: a second zvol under the same target adds only its backstore and lun" {
  run bash "$S/iscsi-export" "${ARGS[@]}"
  : > "$SHIM_LOG"
  run bash "$S/iscsi-export" lab/enc/t1 --iqn "$IQN" --initiator "$INI" --portal "$PORTAL"
  [ "$status" -eq 0 ]
  grep -qxF 'targetcli /backstores/block create lab_enc_t1 /dev/zvol/lab/enc/t1' "$SHIM_LOG"
  grep -qxF "targetcli /iscsi/$IQN/tpg1/luns create /backstores/block/lab_enc_t1" "$SHIM_LOG"
  run ! grep -qxF "targetcli /iscsi create $IQN" "$SHIM_LOG"
}

@test "export: argument validation exits 2 / 3 before targetcli" {
  run bash "$S/iscsi-export"
  [ "$status" -eq 2 ]
  run bash "$S/iscsi-export" lab/enc/t0 --iqn "$IQN"
  [ "$status" -eq 2 ]
  run bash "$S/iscsi-export" lab/enc/t0 --iqn bogus --initiator "$INI" --portal "$PORTAL"
  [ "$status" -eq 3 ]
  run bash "$S/iscsi-export" lab/enc/t0 --iqn "$IQN" --initiator bogus --portal "$PORTAL"
  [ "$status" -eq 3 ]
  run bash "$S/iscsi-export" lab/enc/t0 --iqn "$IQN" --initiator "$INI" --portal 0.0.0.0
  [ "$status" -eq 3 ]
  run bash "$S/iscsi-export" lab/enc/t0 --iqn "$IQN" --initiator "$INI" --portal 'a;b'
  [ "$status" -eq 3 ]
  run bash "$S/iscsi-export" '../x' --iqn "$IQN" --initiator "$INI" --portal "$PORTAL"
  [ "$status" -eq 3 ]
  run ! grep -q '^targetcli' "$SHIM_LOG"
}

@test "export: a dataset that is not a zvol, or missing, is refused (3)" {
  run bash "$S/iscsi-export" lab/enc --iqn "$IQN" --initiator "$INI" --portal "$PORTAL"
  [ "$status" -eq 3 ]
  run bash "$S/iscsi-export" lab/enc/nope --iqn "$IQN" --initiator "$INI" --portal "$PORTAL"
  [ "$status" -eq 3 ]
  run ! grep -q '^targetcli' "$SHIM_LOG"
}

@test "export: a backstore name already used for another device is refused" {
  echo "  o- lab_enc_t0 ...... [/dev/zvol/lab/other (1.0GiB) write-thru activated]" > "$STATE/ls/_backstores_block"
  run bash "$S/iscsi-export" "${ARGS[@]}"
  [ "$status" -eq 3 ]
  run ! grep -E ' (create|delete) ' "$SHIM_LOG"
}

@test "unexport: deletes the target and its own backstore, saves, never touches the zvol" {
  run bash "$S/iscsi-export" "${ARGS[@]}"
  : > "$SHIM_LOG"
  run bash "$S/iscsi-unexport" "$IQN"
  [ "$status" -eq 0 ]
  grep -qxF "targetcli /iscsi delete $IQN" "$SHIM_LOG"
  grep -qxF 'targetcli /backstores/block delete lab_enc_t0' "$SHIM_LOG"
  grep -qxF 'targetcli saveconfig' "$SHIM_LOG"
  run ! grep -E '^zfs ' "$SHIM_LOG"
}

@test "unexport: a target that is not there is a no-op (0)" {
  run bash "$S/iscsi-unexport" "$IQN"
  [ "$status" -eq 0 ]
  run ! grep -E ' (create|delete) ' "$SHIM_LOG"
}

@test "unexport: usage 2, bad iqn 3" {
  run bash "$S/iscsi-unexport"
  [ "$status" -eq 2 ]
  run bash "$S/iscsi-unexport" nope
  [ "$status" -eq 3 ]
}

@test "status: read-only, shows backstores and targets" {
  run bash "$S/iscsi-export" "${ARGS[@]}"
  : > "$SHIM_LOG"
  printf '#!/usr/bin/env bash\necho "ss $*" >> "$SHIM_LOG"\n' > "$TEST_DIR/bin/ss"
  chmod +x "$TEST_DIR/bin/ss"
  run bash "$S/iscsi-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lab_enc_t0"* ]]
  [[ "$output" == *"$IQN"* ]]
  run ! grep -E ' (create|delete) |saveconfig' "$SHIM_LOG"
  run bash "$S/iscsi-status" extra
  [ "$status" -eq 2 ]
}
