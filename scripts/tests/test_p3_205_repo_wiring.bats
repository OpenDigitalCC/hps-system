#!/usr/bin/env bats
#
# Wiring of the site repository (docs/REPOSITORY.md): the read-only server
# and where the signing key lives, the node scripts allowlisted on the builder
# image only, where signatures are and are not checked, the cluster keys, the
# ips-admin tool hps-repo and its gate, and the documentation.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."
SD="$ROOT/node-manager/nixos-26/scripts"
RUNNER="$ROOT/node-manager/nixos-26/boot/hps-builder-run.sh"
BLD="$ROOT/nix/modules/profiles/builder.nix"
REPO_SCRIPTS="repo-seed repo-update repo-status"

nix_code() {
  grep -v '^[[:space:]]*#' "$1"
}

@test "the repository server: darkhttpd on 8091, read-only over repo/, the key directory hidden, started when the repository appears" {
  grep -q '^  repoPort = 8091;' "$BLD"
  block=$(sed -n '/systemd.services.hps-repo-http = {/,/^  };/p' "$BLD")
  [[ "$block" == *'DynamicUser = true;'* ]]
  [[ "$block" == *'ProtectSystem = "strict";'* ]]
  [[ "$block" == *'ReadOnlyPaths = [ "/var/lib/hps-builder/repo" ];'* ]]
  [[ "$block" == *'InaccessiblePaths = [ "-/var/lib/hps-builder/keys" ];'* ]]
  [[ "$block" == *'darkhttpd /var/lib/hps-builder/repo --port ${toString repoPort} --no-listing'* ]]
  [[ "$block" == *'ConditionPathIsMountPoint = "/var/lib/hps-builder";'* ]]
  sed -n '/systemd.services.hps-builder-http = {/,/^  };/p' "$BLD" | grep -qF 'InaccessiblePaths = [ "-/var/lib/hps-builder/keys" ];'
  sed -n '/systemd.paths.hps-repo-http = {/,/^  };/p' "$BLD" | grep -qF 'PathExists = "/var/lib/hps-builder/repo/nix-cache/nix-cache-info";'
  grep -q 'networking.firewall.allowedTCPPorts = \[ httpPort repoPort \];' "$BLD"
}

@test "the signing key: made on the node, the secret under keys/ (0700, 0600), outside the served tree; only the public key in repo/" {
  nix_code "$RUNNER" | grep -q '^KEYS="\$MNT/keys"$'
  nix_code "$RUNNER" | grep -q '^SIGNING_KEY="\$KEYS/repo.secret"$'
  nix_code "$RUNNER" | grep -q '^PUBLIC="\$REPO/repo.pub"$'
  nix_code "$RUNNER" | grep -q 'run install -d -m 0700 -- "\$KEYS"'
  nix_code "$RUNNER" | grep -q 'run chmod 0600 -- "\$SIGNING_KEY.tmp"'
  nix_code "$RUNNER" | grep -q 'nix-store --generate-binary-cache-key'
  # the secret is read by nix only, never printed or copied
  run ! bash -c "grep -v '^[[:space:]]*#' '$RUNNER' | grep -E '(cat|cp|curl|echo|printf)[^|]*\\\$SIGNING_KEY'"
  for s in $REPO_SCRIPTS; do
    run ! grep -q 'repo.secret\|/keys' "$SD/$s"
  done
}

@test "signatures: --no-check-sigs only for the system closure copy and the seed import; builds trust the repository key" {
  [ "$(nix_code "$RUNNER" | grep -c -- '--no-check-sigs')" -eq 2 ]
  nix_code "$RUNNER" | grep -- '--no-check-sigs' | grep -q 'copy --no-check-sigs --to "local?root=\$STORE_ROOT" "\$HPS_BUILDER_SYSTEM"'
  nix_code "$RUNNER" | grep -- '--no-check-sigs' | grep -q 'copy --no-check-sigs --from "\$FROM" --stdin < "\$PATHS"'
  nix_code "$RUNNER" | grep -A1 -- 'copy --no-check-sigs --from' >/dev/null
  nix_code "$RUNNER" | grep -q 'store verify --no-trust --stdin < "\$PATHS"'
  nix_code "$RUNNER" | grep -q '^trusted-public-keys = \$pub$'
  nix_code "$RUNNER" | grep -q '^ *export NIX_CONFIG="substituters = file://\$CACHE_DIR$'
  nix_code "$RUNNER" | grep -q 'copy --to "file://\$CACHE_DIR?compression=zstd&secret-key=\$SIGNING_KEY" --stdin'
  run ! bash -c "grep -v '^[[:space:]]*#' '$RUNNER' | grep -E 'require-sigs|trusted-users|--option'"
}

@test "the repository node scripts are allowlisted under profile node on the builder image only" {
  local s
  for s in $REPO_SCRIPTS; do
    [ -x "$SD/$s" ]
    grep -qxF "      $s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$BLD"
    grep -qxF "      $s.options.profile = \"node\";" "$BLD"
    run ! grep -q "$s" "$ROOT/nix/modules/hps-ctrl-exec.nix"
    run ! grep -q "$s" "$ROOT/nix/modules/profiles/container-host.nix"
  done
  # read-only status: it writes nothing
  local writes='(^|[ (])(mkdir|rm|mv|cp|install|tee|systemd-run|nix|curl)[ ]|(^|[^-2&])>{1,2} *["$/a-z]'
  run ! grep -E "$writes" <(nix_code "$SD/repo-status")
}

@test "the repository cluster keys are catalogued: repo_host, repo_nix_pubkey (<name>:<base64>), repo_upstream (bool, default false)" {
  run perl -I"$ROOT/lib/perl" -MHPS::ClusterConfig -e '
    my $h = HPS::ClusterConfig::question("repo_host") or die "repo_host\n";
    my $k = HPS::ClusterConfig::question("repo_nix_pubkey") or die "repo_nix_pubkey\n";
    my $u = HPS::ClusterConfig::question("repo_upstream") or die "repo_upstream\n";
    die "default\n" unless $u->{default} eq "false";
    for my $ok ("bld-001", "bld-001.lab.hps", "52:54:00:0d:22:4e", "") {
      my $e = HPS::ClusterConfig::validate_value($h, $ok); die "refused $ok: $e\n" if defined $e;
    }
    die "accepted a host with a space\n" unless defined HPS::ClusterConfig::validate_value($h, "a b");
    my $pub = "hps-repo-bld-001-1:" . ("A" x 43) . "=";
    die "refused the key\n" if defined HPS::ClusterConfig::validate_value($k, $pub);
    for my $bad ("x", "a:b", "hps:" . ("A" x 44), "a b:" . ("A" x 43) . "=") {
      die "accepted $bad\n" unless defined HPS::ClusterConfig::validate_value($k, $bad);
    }
    die "bool\n" unless defined HPS::ClusterConfig::validate_value($u, "yes");
    print "ok\n";'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  local k
  for k in repo_host repo_nix_pubkey repo_upstream; do
    grep -q "'$k', 'cluster'" "$ROOT/lib/perl/HPS/Registry/Keys.pm"
    grep -q "^| \`$k\` |" "$ROOT/docs/REGISTRY-KEYS.md"
    grep -q "^| \`$k\` |" "$ROOT/docs/CLUSTER-CONFIG.md"
  done
}

@test "hps-repo is an ips-admin tool: allowlisted, a wrapper, open in the gate, named by hps-op and OPERATOR.md" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [[ " ${IPS_ADMIN_SCRIPTS[*]} " == *" hps-repo "* ]]
  [[ " ${IPS_ADMIN_RAW_SCRIPTS[*]} " != *" hps-repo "* ]]
  [ -x "$ROOT/ips-admin/hps-repo" ]
  grep -qxF 'exec "${0%/*}/ips-admin-exec" hps-repo "$@"' "$ROOT/ips-admin/hps-repo"
  grep -qE '^  hps-onboard \| .*\| hps-repo\)$' "$ROOT/ips-admin/ips-admin-exec"
  grep -q 'hps-repo' "$ROOT/bin/hps-op"
  grep -q '^| `hps-repo` | `bin/hps-repo` |' "$ROOT/docs/OPERATOR.md"
  [ -x "$ROOT/bin/hps-repo" ]
}

@test "the ips-admin gate: hps-repo takes tokens (--profiles a,b, --input NAME=SHA), never a URL or a file" {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-205.XXXXXX")"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  printf 'HPS_SYSTEM_BASE=%s\n' "$TEST_DIR/sys" > "$TEST_DIR/hps.conf"
  printf '#!/bin/bash\necho "tool=${0##*/} args=$*"\n' > "$TEST_DIR/sys/bin/hps-repo"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/sys/bin/hps-repo" "$TEST_DIR/bin/logger"
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-repo" build --profiles node-base,node-builder --input "ctrl-exec=$(printf 'a%.0s' {1..64})"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-repo args=build --profiles node-base,node-builder --input ctrl-exec="* ]]
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-repo" seed --from http://10.0.0.9:8091/nix-cache
  [ "$status" -eq 2 ]
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-repo" seed --paths /etc/passwd
  [ "$status" -eq 2 ]
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-repo" seed
  [ "$status" -eq 0 ]
  rm -rf "$TEST_DIR"
}

@test "hps-repo: --help names every verb; bad verbs and options are usage" {
  run perl "$ROOT/bin/hps-repo" --help
  [ "$status" -eq 0 ]
  local v
  for v in status update build seed repo_host repo_nix_pubkey repo_upstream; do
    [[ "$output" == *"$v"* ]]
  done
  run perl "$ROOT/bin/hps-repo" wipe
  [ "$status" -eq 2 ]
  run perl "$ROOT/bin/hps-repo" build --wait 0
  [ "$status" -eq 2 ]
  run perl "$ROOT/bin/hps-repo" status --profiles x
  [ "$status" -eq 2 ]
}

@test "the documentation names the role, the verbs, the scripts, the key arrangement and the ports" {
  local s
  [ -f "$ROOT/docs/REPOSITORY.md" ]
  for s in $REPO_SCRIPTS builder-build hps-builder-run hps-repo-http hps-repo repo_host repo_nix_pubkey repo_upstream \
    'hps-repo update' 'hps-repo build' 'hps-repo seed' 'hps-repo status' --no-check-sigs 8091 8090 hps-pin-fetch \
    /var/lib/hps-builder/keys BUILD_CACHE_PARAMS storage.googleapis.com; do
    grep -qF -- "$s" "$ROOT/docs/REPOSITORY.md"
  done
  grep -qF 'docs/REPOSITORY.md' "$ROOT/docs/BUILDER.md"
  grep -q 'hps-repo' "$ROOT/CHANGELOG.md"
}
