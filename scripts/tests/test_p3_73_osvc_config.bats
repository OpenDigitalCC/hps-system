#!/usr/bin/env bats
#
# CS-3.5: boot/hps-osvc-config.sh - cluster.conf, node.conf and the unit
# environment written from a shim IPS reply.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-73.XXXXXX")"
  GEN="$ROOT/node-manager/nixos-26/boot/hps-osvc-config.sh"
  export HPS_RUN_DIR="$T/run/hps"
  export OSVC_ETC="$T/etc/opensvc"
  export HPS_CMDLINE="$T/cmdline"
  export HPS_HOSTNAME=sch-001.lab.example
  export SHIM_LOG="$T/shim.log"
  export KEYS="$T/keys"
  mkdir -p "$T/bin" "$HPS_RUN_DIR" "$KEYS"
  echo "console=tty0 hps.ips=192.0.2.1 hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  # Shim IPS: cmd=cluster_nodes prints $KEYS/nodes; cmd=cluster_variable&name=K
  # prints $KEYS/K or fails like curl -f on a 404 (exit 22).
  cat > "$T/bin/curl" <<'SH'
#!/usr/bin/env bash
url=${*: -1}
echo "curl $url" >> "$SHIM_LOG"
[[ -n "${FAKE_CURL_RC:-}" ]] && exit "$FAKE_CURL_RC"
case "$url" in
  *cmd=cluster_nodes*) cat "$KEYS/nodes" ;;
  *cmd=cluster_variable*name=*)
    name=${url##*name=}
    [[ -f "$KEYS/$name" ]] || exit 22
    cat "$KEYS/$name" ;;
esac
SH
  chmod +x "$T/bin/curl"
  export PATH="$T/bin:$PATH"
  printf 'cluster lab\nnode sch-001.lab.example 192.0.2.11\nnode tch-001.lab.example 192.0.2.12\n' > "$KEYS/nodes"
  # a fake 32-character secret, as delivered by osvc-secret-set
  printf '%s\n' "$(printf 'ab%.0s' {1..16})" > "$HPS_RUN_DIR/osvc-cluster-secret"
}

teardown() {
  rm -rf "$T"
}

@test "defaults: cluster.conf names the cluster, the nodes and the delivered secret" {
  run -0 bash "$GEN"
  grep -qx '\[cluster\]' "$OSVC_ETC/cluster.conf"
  grep -qx 'name = lab' "$OSVC_ETC/cluster.conf"
  grep -qx 'nodes = sch-001.lab.example tch-001.lab.example' "$OSVC_ETC/cluster.conf"
  grep -qx "secret = $(printf 'ab%.0s' {1..16})" "$OSVC_ETC/cluster.conf"
}

@test "defaults: node.conf has listener 1215 and unicast hb 5s/15s with one addr per node" {
  run -0 bash "$GEN"
  grep -qx 'port = 1215' "$OSVC_ETC/node.conf"
  grep -qx 'type = unicast' "$OSVC_ETC/node.conf"
  grep -qx 'interval = 5' "$OSVC_ETC/node.conf"
  grep -qx 'timeout = 15' "$OSVC_ETC/node.conf"
  grep -qx 'addr@sch-001.lab.example = 192.0.2.11' "$OSVC_ETC/node.conf"
  grep -qx 'addr@tch-001.lab.example = 192.0.2.12' "$OSVC_ETC/node.conf"
}

@test "the osvc_* cluster keys override the defaults" {
  echo 1300 > "$KEYS/osvc_listener_port"
  echo 3 > "$KEYS/osvc_hb_interval"
  echo 20 > "$KEYS/osvc_hb_timeout"
  run -0 bash "$GEN"
  grep -qx 'port = 1300' "$OSVC_ETC/node.conf"
  grep -qx 'interval = 3' "$OSVC_ETC/node.conf"
  grep -qx 'timeout = 20' "$OSVC_ETC/node.conf"
  [[ "$output" == *"firewall opens 1215 only"* ]]
}

@test "multicast writes no per-node addresses" {
  echo multicast > "$KEYS/osvc_hb_type"
  run -0 bash "$GEN"
  grep -qx 'type = multicast' "$OSVC_ETC/node.conf"
  run ! grep -q 'addr@' "$OSVC_ETC/node.conf"
}

@test "log level debug adds --debug to the unit environment; info adds nothing" {
  echo debug > "$KEYS/osvc_log_level"
  run -0 bash "$GEN"
  [ "$(cat "$HPS_RUN_DIR/opensvc.env")" = "OSVC_DAEMON_ARGS=--debug" ]
  echo warn > "$KEYS/osvc_log_level"
  run -0 bash "$GEN"
  [ "$(cat "$HPS_RUN_DIR/opensvc.env")" = "OSVC_DAEMON_ARGS=" ]
}

@test "the config files are root-only and no temp file is left" {
  run -0 bash "$GEN"
  [ "$(stat -c %a "$OSVC_ETC/cluster.conf")" = 600 ]
  [ "$(stat -c %a "$OSVC_ETC/node.conf")" = 600 ]
  run ! ls "$OSVC_ETC"/*.tmp
}

@test "no delivered secret: refused (3), nothing written" {
  rm "$HPS_RUN_DIR/osvc-cluster-secret"
  run -3 bash "$GEN"
  [ ! -e "$OSVC_ETC/cluster.conf" ]
}

@test "a secret that is not hex is refused" {
  echo 'not hex' > "$HPS_RUN_DIR/osvc-cluster-secret"
  run -3 bash "$GEN"
  [ ! -e "$OSVC_ETC/cluster.conf" ]
}

@test "a 64-character secret is refused: om3 uses the string as an AES key" {
  printf '%s\n' "$(printf 'ab%.0s' {1..32})" > "$HPS_RUN_DIR/osvc-cluster-secret"
  run -3 bash "$GEN"
  [ ! -e "$OSVC_ETC/cluster.conf" ]
}

@test "this node missing from the IPS list is refused" {
  printf 'cluster lab\nnode tch-001.lab.example 192.0.2.12\n' > "$KEYS/nodes"
  run -3 bash "$GEN"
  [[ "$output" == *"not in the IPS node list"* ]]
}

@test "an empty node list and a bad value are refused" {
  printf 'cluster lab\n' > "$KEYS/nodes"
  run -3 bash "$GEN"
  printf 'cluster lab\nnode sch-001.lab.example 192.0.2.11\n' > "$KEYS/nodes"
  echo 'ha' > "$KEYS/osvc_hb_type"
  run -3 bash "$GEN"
  [ ! -e "$OSVC_ETC/cluster.conf" ]
}

@test "no registry hostname yet is refused" {
  HPS_HOSTNAME=localhost run -3 bash "$GEN"
}

@test "an IPS read failure is exit 1" {
  FAKE_CURL_RC=7 run -1 bash "$GEN"
}

@test "the IPS address comes from hps.ips and every command is logged" {
  run -0 bash "$GEN"
  grep -q 'curl http://192.0.2.1/cgi-bin/boot_manager.sh?cmd=cluster_nodes' "$SHIM_LOG"
  [[ "$output" == *"+ curl"* ]]
}

@test "the secret value is never logged" {
  run -0 bash "$GEN"
  [[ "$output" != *"$(printf 'ab%.0s' {1..16})"* ]]
}
