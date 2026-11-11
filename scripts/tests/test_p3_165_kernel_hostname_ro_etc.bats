#!/usr/bin/env bats
#
# IPS-11 item 5 (lab 2026-11-11): n_set_kernel_hostname sets only the transient
# name when /etc is read-only (a netbooted NixOS node), so systemd-hostnamed
# logs no "Failed to write static hostname".

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-165.XXXXXX")"
  mkdir -p "$T/bin" "$T/etc"
  cat > "$T/bin/hostnamectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HN_LOG"
SH
  chmod +x "$T/bin/hostnamectl"
  export HN_LOG="$T/hn.log" PATH="$T/bin:$PATH"
  source "$ROOT/node-manager/base/n_configure-hostname.sh"
}

teardown() {
  chmod -R u+w "$T" 2> /dev/null || true
  rm -rf "$T"
}

@test "read-only /etc: transient only, no static attempt" {
  : > "$T/etc/hostname"
  chmod a-w "$T/etc/hostname" "$T/etc"
  HPS_ETC_DIR="$T/etc" n_set_kernel_hostname tch-001.lab.hps
  [ "$(cat "$HN_LOG")" = "set-hostname --transient tch-001.lab.hps" ]
}

@test "writable /etc: the static name is set" {
  : > "$T/etc/hostname"
  HPS_ETC_DIR="$T/etc" n_set_kernel_hostname tch-001.lab.hps
  [ "$(cat "$HN_LOG")" = "set-hostname tch-001.lab.hps" ]
}
