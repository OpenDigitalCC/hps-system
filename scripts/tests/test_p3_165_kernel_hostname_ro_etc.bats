#!/usr/bin/env bats
#
# IPS-11 item 5 (lab 2026-11-11): n_set_kernel_hostname sets only the transient
# name only (the NixOS path; /etc/hostname is a link into the read-only store),
# so systemd-hostnamed logs no "Failed to write static hostname".

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

@test "the NixOS kernel hostname is the transient name only, never a static attempt" {
  n_set_kernel_hostname tch-001.lab.hps
  [ "$(cat "$HN_LOG")" = "set-hostname --transient tch-001.lab.hps" ]
}

@test "without hostnamectl: hostname(1)" {
  rm "$T/bin/hostnamectl"
  printf '#!/usr/bin/env bash\nprintf "hostname %%s\\n" "$*" >> "$HN_LOG"\n' > "$T/bin/hostname"
  chmod +x "$T/bin/hostname"
  PATH="$T/bin:/usr/bin:/bin" n_set_kernel_hostname tch-001.lab.hps
  [ "$(cat "$HN_LOG")" = "hostname tch-001.lab.hps" ]
}
