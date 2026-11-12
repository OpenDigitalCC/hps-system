# Helpers for the site repository tests (test_p3_204_*, test_p3_205_*).
# Load after p2_30_helpers, p3_171_helpers and p3_202_helpers. p3_204_setup
# adds a nix and a nix-store shim that keep a fake store and a fake file
# binary cache:
#   store              the local store's valid paths (nix path-info --all)
#   upstream-signed    paths whose narinfo also carries an upstream signature
#   dry.<attr>         what nix build --dry-run <src>#<attr> prints (stderr)
#   drvshow.json       what nix derivation show prints
#   fod-fail           derivations whose build (a fetch) fails, naming hosts
# FAKE_UNSIGNED_COPY=1: a copy into a file cache writes no signature (an older
# build.sh); FAKE_SIGN_FAIL=1: nix store sign signs nothing;
# FAKE_VERIFY_RC, FAKE_REALISE_RC, FAKE_COPY_FROM_RC: exit statuses.

p3_204_setup() {
  p3_202_setup
  p3_204_curl
  export HPS_BUILDER_NO_NS=1
  export HPS_BUILDER_SYSTEM="$TEST_DIR/system"
  export HPS_GITHUB_API="http://gh.test"
  : > "$STATE/store"
  cat > "$TEST_DIR/bin/nix-store" <<'SHIM'
#!/usr/bin/env bash
echo "nix-store $*" >> "$SHIM_LOG"
case "$1" in
  --generate-binary-cache-key)
    echo "$2:c2VjcmV0" > "$3"
    echo "$2:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$4"
    ;;
  --realise)
    shift
    printf '%s\n' "$@" >> "$STATE/realised"
    exit "${FAKE_REALISE_RC:-0}"
    ;;
esac
SHIM
  cat > "$TEST_DIR/bin/nix" <<'SHIM'
#!/usr/bin/env bash
echo "nix $*" >> "$SHIM_LOG"
while [[ "${1:-}" == --extra-experimental-features ]]; do shift 2; done
sub=$1
shift
narinfo() { # <dir> <path> <sig name|"">
  local base=${2#/nix/store/} f
  f="$1/${base%%-*}.narinfo"
  printf 'StorePath: %s\nURL: nar/x.nar.zst\nFileSize: 100\n' "$2" > "$f"
  [[ -z "$3" ]] || echo "Sig: $3:x" >> "$f"
  if grep -qxF "$2" "$STATE/upstream-signed" 2> /dev/null; then echo "Sig: cache.nixos.org-1:y" >> "$f"; fi
}
case "$sub" in
  copy)
    from="" to="" stdin=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from) from=$2; shift 2 ;;
        --to) to=$2; shift 2 ;;
        --stdin) stdin=1; shift ;;
        *) shift ;;
      esac
    done
    [[ "$to" == local\?root=* ]] && exit "${FAKE_COPY_RC:-0}"
    [[ $stdin -eq 1 ]] || exit 0
    if [[ -n "$from" ]]; then
      [[ "${FAKE_COPY_FROM_RC:-0}" -eq 0 ]] || exit "$FAKE_COPY_FROM_RC"
      cat >> "$STATE/store"
      exit 0
    fi
    dir=${to#file://}
    dir=${dir%%\?*}
    key=$(printf '%s\n' "$to" | sed -n 's/.*secret-key=\([^&]*\).*/\1/p')
    name=""
    [[ -z "$key" || "${FAKE_UNSIGNED_COPY:-0}" == 1 ]] || name=$(cut -d: -f1 "$key")
    while IFS= read -r p; do
      [[ -n "$p" ]] && narinfo "$dir" "$p" "$name"
    done
    ;;
  path-info)
    cat "$STATE/store"
    ;;
  store)
    op=$1
    shift
    case "$op" in
      verify) exit "${FAKE_VERIFY_RC:-0}" ;;
      sign)
        dir="" key=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --store) dir=${2#file://}; shift 2 ;;
            --key-file) key=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        [[ "${FAKE_SIGN_FAIL:-0}" == 1 ]] && exit 1
        name=$(cut -d: -f1 "$key")
        while IFS= read -r p; do
          base=${p#/nix/store/}
          echo "Sig: $name:z" >> "$dir/${base%%-*}.narinfo"
        done
        ;;
    esac
    ;;
  build)
    attr="" drv="" dry=0
    for a in "$@"; do
      case "$a" in
        --dry-run) dry=1 ;;
        path:*'#'*) attr=${a##*#} ;;
        /nix/store/*'^*') drv=${a%^*} ;;
      esac
    done
    if [[ $dry -eq 1 ]]; then
      [[ -f "$STATE/dry.$attr" ]] && cat "$STATE/dry.$attr" >&2
      exit 0
    fi
    if [[ -n "$drv" ]]; then
      echo "$drv" >> "$STATE/fod-built"
      if grep -qxF "$drv" "$STATE/fod-fail" 2> /dev/null; then
        echo 'go: github.com/x/y@v1: Get "https://storage.googleapis.com/proxy-golang-org-prod/x": Forbidden'
        echo 'go: reading https://proxy.golang.org/github.com/x/y/@v/v1.zip: 403'
        exit 1
      fi
    fi
    ;;
  derivation)
    cat "$STATE/drvshow.json"
    ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/nix" "$TEST_DIR/bin/nix-store"
}

# p3_204_key: a repository key on the fake disk (name hps-repo-test-1).
p3_204_key() {
  mkdir -p "$MNT/keys" "$MNT/repo/nix-cache"
  echo "hps-repo-test-1:c2VjcmV0" > "$MNT/keys/repo.secret"
  chmod 0600 "$MNT/keys/repo.secret"
  echo "hps-repo-test-1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" > "$MNT/repo/repo.pub"
}

# p3_204_src: a source tree under src/s1 with a flake.nix of pinned inputs.
p3_204_src() {
  mkdir -p "$MNT/src/s1/nix"
  cat > "$MNT/src/s1/flake.nix" <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    ctrl-exec = {
      url = "github:OpenDigitalCC/ctrl-exec";
    };
    om3-src = {
      url = "github:opensvc/om3/v3.0.0-rc60"; # rev
      flake = false;
    };
    ctrl-exec-plugins = {
      url = "github:OpenDigitalCC/ctrl-exec-plugins/v0.3.11";
      flake = false;
    };
  };
}
EOF
  cat > "$MNT/src/s1/nix/build.sh" <<'EOF'
#!/bin/bash
PROFILES="node-base node-builder"
echo "build.sh $*" >> "$SHIM_LOG"
echo "env https_proxy=${https_proxy:-} BUILD_CACHE_PARAMS=${BUILD_CACHE_PARAMS:-}" >> "$SHIM_LOG"
printf 'NIX_CONFIG<<\n%s\n>>\n' "${NIX_CONFIG:-}" >> "$SHIM_LOG"
echo /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-om3-3.0.0-rc60 >> "$STATE/store"
[[ "${FAKE_BUILD_RC:-0}" -eq 0 ]] || exit "$FAKE_BUILD_RC"
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == --out ]] && out=$2; shift; done
mkdir -p "$out/nixos-26.05-20261112-0123456-abcdef0"
echo nixos-26.05-20261112-0123456-abcdef0 > "$out/latest"
EOF
}

# p3_204_tags <owner/repo> <tag...>: what the fake GitHub API lists (one page).
p3_204_tags() {
  local repo="$1" t json="["
  shift
  for t in "$@"; do
    json+="{\"name\":\"$t\"},"
  done
  json="${json%,}]"
  mkdir -p "$STATE/www/repos/$repo"
  printf '%s' "$json" > "$STATE/www/repos/$repo/tags?per_page=100&page=1"
}

# p3_204_curl: the p3_171 curl shim, also writing to stdout when no --output.
p3_204_curl() {
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
out="" url="${@: -1}"
while [[ $# -gt 0 ]]; do
  [[ "$1" == --output ]] && { out=$2; shift; }
  shift
done
path="${url#http://*/}"
src="$STATE/www/$path"
[[ -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
SHIM
  chmod +x "$TEST_DIR/bin/curl"
}
