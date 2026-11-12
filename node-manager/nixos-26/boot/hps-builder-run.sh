#!/usr/bin/env bash
#
# hps-builder-run - run one job on the builder and its site repository
# (docs/BUILDER.md, docs/REPOSITORY.md).
#
# Started by the node scripts builder-build, repo-update and repo-seed as the
# transient unit hps-builder-build (systemd-run, full root); not a node script
# itself. One job at a time: they share the unit.
#
# Usage: hps-builder-run --id ID [--mode build|update|seed]
#          build:  --src DIR [--profiles "a b"] [--input NAME=DIR ...] [--upstream]
#          update: --src DIR [--profiles "a b"] [--input NAME=DIR ...]
#          seed:   --from URL --paths FILE
#
# The build store is /var/lib/hps-builder/root/nix (store URI
# local?root=/var/lib/hps-builder/root), on the builder disk. The netboot
# image's own store is RAM and is registered anew at every boot, so it cannot
# keep a build cache; a disk store can. The runner:
#
#   1. makes the repository's signing key at first use (nix-store
#      --generate-binary-cache-key; secret in /var/lib/hps-builder/keys, mode
#      0600, never served, never sent; public key in repo/repo.pub)
#   2. copies the running system's closure into the disk store (nix copy,
#      local, no download; only what a new image adds is copied), so every
#      tool the job calls exists in it
#   3. re-runs itself in a private mount namespace (unshare -m) in which the
#      disk store is bind-mounted at /nix: there nix sees an ordinary /nix,
#      with the usual /nix/store paths, and runs without the daemon, as root
#   4. the job:
#      build   <src>/nix/build.sh --src <src> --out <disk>/out --cache
#              <repository cache> (the source's own build.sh). Substituters:
#              the repository cache only, trusted by its own public key; with
#              --upstream also the system's (the NixOS cache) through the
#              egress proxy. Without --upstream no proxy is set: nothing leaves
#              the site.
#      update  through the egress proxy, with the repository and the system's
#              substituters: nix build --dry-run of every profile and ipxe;
#              every path nix would fetch is substituted, every fixed-output
#              derivation it would build (sources, Go modules) is built (a
#              fetch); nothing else is built. A fetch that fails is named with
#              the hosts its log names. Then every pinned GitHub input of
#              flake.nix is compared with its newest release tag (GitHub's
#              tags API, through the proxy).
#      seed    nix copy --no-check-sigs --from <URL> of every path in <FILE>
#              (nix checks each NAR against its narinfo NarHash and NarSize
#              on import), then nix store verify --no-trust re-hashes every
#              imported path. --no-check-sigs is used for this import only.
#   5. publishes: every valid path of the disk store (no .drv) is copied into
#      the repository cache (file://, zstd) signed with the repository key;
#      any narinfo there without the key's signature is signed; the job fails
#      if one is left unsigned. This runs after a failed build or update too,
#      so whatever was fetched or built is kept.
#
# Egress: https_proxy from hps.proxy= on the kernel command line (the IPS sets
# it from the cluster key egress_proxy), for update and build --upstream only;
# the IPS (hps.ips=) is reached directly.
#
# Every command is logged to /var/lib/hps-builder/state/build-<id>.log. The
# record /var/lib/hps-builder/state/<id>.json (and last.json, a copy) holds
# id, mode, state (running, ok, failed), started_at, finished_at, seconds, rc,
# pin, src, profiles and detail; builder-status and repo-status read it. An
# update also writes state/inputs.txt (one INPUT line per pinned input).
#
# Overrides for tests: HPS_BUILDER_ROOT (prefix of /var/lib/hps-builder),
# HPS_CMDLINE (file read instead of /proc/cmdline), HPS_BUILDER_SYSTEM
# (instead of /run/current-system), HPS_BUILDER_NO_NS=1 (no namespace and no
# bind mount: the tests' nix is a shim), HPS_GITHUB_API (instead of
# https://api.github.com).

set -euo pipefail

: "${HPS_BUILDER_ROOT:=}"
: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_BUILDER_SYSTEM:=/run/current-system}"
: "${HPS_BUILDER_NO_NS:=0}"
: "${HPS_GITHUB_API:=https://api.github.com}"

MNT="$HPS_BUILDER_ROOT/var/lib/hps-builder"
STORE_ROOT="$MNT/root"
STATE_DIR="$MNT/state"
REPO="$MNT/repo"
CACHE_DIR="$REPO/nix-cache"
KEYS="$MNT/keys"
SIGNING_KEY="$KEYS/repo.secret"
PUBLIC="$REPO/repo.pub"
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
ID=""
MODE=build
SRC=""
PROFILES=""
INPUTS=()
UPSTREAM=0
FROM=""
PATHS=""
INNER=0
DETAIL=""

log() {
  printf '[hps-builder-run] %s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

cmdline_value() {
  local key="$1" word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

usage_fail() {
  echo "hps-builder-run: $*" >&2
  exit 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) ID=$2; shift 2 ;;
      --mode) MODE=$2; shift 2 ;;
      --src) SRC=$2; shift 2 ;;
      --profiles) PROFILES=$2; shift 2 ;;
      --input) INPUTS+=("$2"); shift 2 ;;
      --upstream) UPSTREAM=1; shift ;;
      --from) FROM=$2; shift 2 ;;
      --paths) PATHS=$2; shift 2 ;;
      --inner) INNER=1; shift ;;
      *) usage_fail "unknown argument $1" ;;
    esac
  done
  [[ "$ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || usage_fail "--id must be <yyyymmdd>T<hhmmss>Z"
  case "$MODE" in
    build | update)
      [[ -f "$SRC/nix/build.sh" ]] || usage_fail "no nix/build.sh under '$SRC'"
      ;;
    seed)
      [[ "$FROM" =~ ^(http://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._-]+)*/?|file:///[A-Za-z0-9._/-]+)$ && "$FROM" != *..* ]] ||
        usage_fail "--from must be http://<host>[:port]/<path> or file:///<path>"
      [[ -f "$PATHS" ]] || usage_fail "--paths must name a file"
      ;;
    *) usage_fail "--mode must be build, update or seed" ;;
  esac
  if [[ "$MODE" != build && $UPSTREAM -eq 1 ]]; then
    usage_fail "--upstream is for build only"
  fi
}

# record <state> [rc] [pin]: write <id>.json and last.json.
record() {
  local state="$1" rc="${2:-}" pin="${3:-}" now
  now=$(date -u +%s)
  jq -n --arg id "$ID" --arg mode "$MODE" --arg state "$state" --arg src "$SRC" --arg profiles "$PROFILES" \
    --arg rc "$rc" --arg pin "$pin" --arg detail "$DETAIL" --argjson now "$now" --argjson t0 "${T0:-$now}" \
    '{id: $id, mode: $mode, state: $state, src: $src, profiles: $profiles,
      started_at: ($t0 | todate),
      finished_at: (if $state == "running" then null else ($now | todate) end),
      seconds: ($now - $t0),
      rc: (if $rc == "" then null else ($rc | tonumber) end),
      pin: (if $pin == "" then null else $pin end),
      detail: (if $detail == "" then null else $detail end)}' > "$STATE_DIR/$ID.json.tmp"
  mv -f "$STATE_DIR/$ID.json.tmp" "$STATE_DIR/$ID.json"
  cp -f "$STATE_DIR/$ID.json" "$STATE_DIR/last.json.tmp"
  mv -f "$STATE_DIR/last.json.tmp" "$STATE_DIR/last.json"
}

# ensure_key: the repository signing key, made once on this node's disk.
ensure_key() {
  local name
  if [[ -s "$SIGNING_KEY" && -s "$PUBLIC" ]]; then
    return 0
  fi
  if [[ -s "$SIGNING_KEY" || -s "$PUBLIC" ]]; then
    log "one half of the repository key is missing ($SIGNING_KEY, $PUBLIC): refusing to make a new key over it"
    return 1
  fi
  name="hps-repo-$(uname -n | cut -d. -f1)-1"
  run install -d -m 0700 -- "$KEYS" || return 1
  run install -d -m 0755 -- "$REPO" || return 1
  run rm -f -- "$SIGNING_KEY.tmp" "$PUBLIC.tmp" || return 1
  (umask 077; run nix-store --generate-binary-cache-key "$name" "$SIGNING_KEY.tmp" "$PUBLIC.tmp") || return 1
  run chmod 0600 -- "$SIGNING_KEY.tmp" || return 1
  run chmod 0644 -- "$PUBLIC.tmp" || return 1
  run mv -f -- "$SIGNING_KEY.tmp" "$SIGNING_KEY" || return 1
  run mv -f -- "$PUBLIC.tmp" "$PUBLIC" || return 1
  log "repository signing key made: $(cat "$PUBLIC") (the secret stays in $KEYS)"
}

# ensure_cache: the repository cache directory and its nix-cache-info
# (Priority 10: preferred to the NixOS cache's 40).
ensure_cache() {
  run mkdir -p -- "$CACHE_DIR" || return 1
  if [[ ! -f "$CACHE_DIR/nix-cache-info" ]]; then
    printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 10\n' > "$CACHE_DIR/nix-cache-info.tmp" || return 1
    run mv -f -- "$CACHE_DIR/nix-cache-info.tmp" "$CACHE_DIR/nix-cache-info" || return 1
  fi
}

key_name() {
  cut -d: -f1 "$PUBLIC"
}

set_egress() {
  local proxy ips
  proxy=$(cmdline_value hps.proxy || true)
  ips=$(cmdline_value hps.ips || true)
  export no_proxy="${ips:+$ips,}localhost,127.0.0.1"
  export NO_PROXY="$no_proxy"
  if [[ "$proxy" =~ ^http://[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$ ]]; then
    export https_proxy="$proxy" HTTPS_PROXY="$proxy" http_proxy="$proxy" HTTP_PROXY="$proxy"
    log "egress through $proxy (no_proxy $no_proxy)"
  else
    log "no hps.proxy= on the kernel command line: no proxy set"
  fi
}

no_egress() {
  unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY
  log "no upstream: no proxy set"
}

# substituters <upstream 0|1>: NIX_CONFIG for the job. The repository first;
# the system's own substituters (the NixOS cache) only with upstream.
substituters() {
  local pub
  pub=$(cat "$PUBLIC")
  if [[ "$1" -eq 1 ]]; then
    export NIX_CONFIG="extra-substituters = file://$CACHE_DIR
extra-trusted-public-keys = $pub
fallback = false"
    log "substituters: the repository (file://$CACHE_DIR) and the system's; trusted: $pub and the system's"
  else
    export NIX_CONFIG="substituters = file://$CACHE_DIR
trusted-public-keys = $pub
fallback = false"
    log "substituters: the repository only (file://$CACHE_DIR); trusted: $pub"
  fi
}

flake_flags() {
  local i name dir
  FLAKE_FLAGS=()
  if [[ ! -f "$SRC/flake.lock" ]]; then
    FLAKE_FLAGS+=(--no-write-lock-file)
  fi
  unset CTRL_EXEC_FLAKE CTRL_EXEC_PLUGINS_FLAKE
  for i in "${INPUTS[@]}"; do
    name=${i%%=*}
    dir=${i#*=}
    case "$name" in
      ctrl-exec) export CTRL_EXEC_FLAKE="path:$dir"; FLAKE_FLAGS+=(--override-input ctrl-exec "path:$dir") ;;
      ctrl-exec-plugins) export CTRL_EXEC_PLUGINS_FLAKE="path:$dir"; FLAKE_FLAGS+=(--override-input ctrl-exec-plugins "path:$dir") ;;
      *) usage_fail "unknown input $name" ;;
    esac
    log "input $name -> path:$dir"
  done
}

# publish: every valid path of the store (no .drv) into the repository cache,
# signed. Returns 1 when a narinfo is left without the repository signature.
publish() {
  local name list unsigned n
  name=$(key_name)
  list="$TMPDIR/publish.paths"
  if ! run nix "${NIX_FLAGS[@]}" path-info --all > "$list.all"; then
    log "FAILED: cannot list the store"
    return 1
  fi
  grep -v '\.drv$' "$list.all" > "$list" || true
  n=$(wc -l < "$list")
  log "publishing $n store paths to the repository (signed by $name)"
  if ! run nix "${NIX_FLAGS[@]}" copy --to "file://$CACHE_DIR?compression=zstd&secret-key=$SIGNING_KEY" --stdin < "$list"; then
    log "FAILED: copying into the repository cache"
    return 1
  fi
  unsigned="$TMPDIR/unsigned.paths"
  unsigned_paths "$name" > "$unsigned"
  if [[ -s "$unsigned" ]]; then
    log "$(wc -l < "$unsigned") narinfo(s) in the repository lack the signature $name: signing them"
    run nix "${NIX_FLAGS[@]}" store sign --store "file://$CACHE_DIR" --key-file "$SIGNING_KEY" --stdin < "$unsigned" || true
    unsigned_paths "$name" > "$unsigned"
    if [[ -s "$unsigned" ]]; then
      log "FAILED: $(wc -l < "$unsigned") path(s) in the repository are still unsigned"
      return 1
    fi
  fi
  PUBLISHED=$n
  return 0
}

# unsigned_paths <key name>: StorePath of every narinfo without a Sig by <name>.
unsigned_paths() {
  find "$CACHE_DIR" -maxdepth 1 -name '*.narinfo' -print0 |
    xargs -0 -r awk -v k="Sig: $1:" '
      FNR == 1 { if (p != "" && !s) print p; p = ""; s = 0 }
      /^StorePath: / { p = $2 }
      index($0, k) == 1 { s = 1 }
      END { if (p != "" && !s) print p }'
}

#--- the jobs (inside the namespace) ------------------------------------------------

job_build() {
  local rc
  flake_flags
  if [[ $UPSTREAM -eq 1 ]]; then
    set_egress
  else
    no_egress
  fi
  substituters "$UPSTREAM"
  # build.sh signs what it copies into the repository (BUILD_CACHE_PARAMS);
  # publish signs anything an older build.sh left unsigned.
  export BUILD_CACHE_PARAMS="compression=zstd&secret-key=$SIGNING_KEY"
  local -a bargs=(--src "$SRC" --out "$MNT/out" --cache "$CACHE_DIR")
  [[ -z "$PROFILES" ]] || bargs+=(--profiles "$PROFILES")
  set +e
  run bash "$SRC/nix/build.sh" "${bargs[@]}"
  rc=$?
  set -e
  if ! publish; then
    [[ $rc -ne 0 ]] || rc=1
  fi
  DETAIL="upstream=$([[ $UPSTREAM -eq 1 ]] && echo yes || echo no) published=${PUBLISHED:-0}"
  printf '%s\n' "$DETAIL" > "$TMPDIR/detail"
  return "$rc"
}

# dry_run <attr> <built file> <fetched file>: what nix would build and fetch.
dry_run() {
  local attr="$1" built="$2" fetched="$3" out="$TMPDIR/dry-$1.txt"
  if ! run nix "${NIX_FLAGS[@]}" build --dry-run --no-link "${FLAKE_FLAGS[@]}" "path:$SRC#$attr" 2> "$out"; then
    cat "$out" >&2
    return 1
  fi
  cat "$out" >&2
  awk -v b="$built" -v f="$fetched" '
    /will be built:?$/ { sect = "b"; next }
    /will be fetched/ { sect = "f"; next }
    /^  \/nix\/store\// { if (sect == "b") print $1 >> b; else if (sect == "f") print $1 >> f; next }
    { sect = "" }' "$out"
}

# fixed_output <drv list file>: the fixed-output derivations among them.
fixed_output() {
  run nix "${NIX_FLAGS[@]}" derivation show --stdin < "$1" |
    jq -r '(if has("derivations") then .derivations else . end) | to_entries[]
      | select(([.value.outputs[]? | .hash // empty] | length > 0) or ((.value.env.outputHash // "") != ""))
      | .key | if startswith("/") then . else "/nix/store/" + . end'
}

# hosts_in <log>: the host names the URLs of a log name.
hosts_in() {
  grep -oE 'https?://[A-Za-z0-9.-]+' "$1" | sed 's|^https\{0,1\}://||' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

job_update() {
  local attr built fetched fods drv flog rc failed=0 nfetch=0 nfod=0 nleft=0 hosts profiles
  flake_flags
  set_egress
  substituters 1
  profiles=$PROFILES
  if [[ -z "$profiles" ]]; then
    profiles=$(sed -n 's/^PROFILES="\(.*\)"$/\1/p' "$SRC/nix/build.sh" | head -1)
  fi
  built="$TMPDIR/built.drvs"
  fetched="$TMPDIR/fetched.paths"
  : > "$built"
  : > "$fetched"
  for attr in $profiles ipxe; do
    if ! dry_run "$attr" "$built.all" "$fetched.all"; then
      log "UPDATE: cannot evaluate $attr (the flake inputs need egress: see above)"
      failed=1
    fi
  done
  [[ -f "$built.all" ]] && sort -u "$built.all" > "$built"
  [[ -f "$fetched.all" ]] && sort -u "$fetched.all" > "$fetched"
  nfetch=$(wc -l < "$fetched")
  if [[ $nfetch -gt 0 ]]; then
    log "substituting $nfetch path(s)"
    if ! run xargs -r -n 200 nix-store --realise < "$fetched" > /dev/null; then
      log "UPDATE: some paths could not be substituted (see above)"
      failed=1
    fi
  fi
  fods="$TMPDIR/fod.drvs"
  : > "$fods"
  if [[ -s "$built" ]]; then
    fixed_output "$built" > "$fods" || failed=1
  fi
  nfod=$(wc -l < "$fods")
  nleft=$(( $(wc -l < "$built") - nfod ))
  log "$nfod fixed-output derivation(s) to fetch; $nleft derivation(s) left for repo build"
  while IFS= read -r drv; do
    [[ -n "$drv" ]] || continue
    flog="$TMPDIR/fod.log"
    set +e
    run nix "${NIX_FLAGS[@]}" build --no-link -L "$drv^*" > "$flog" 2>&1
    rc=$?
    set -e
    cat "$flog" >&2
    if [[ $rc -ne 0 ]]; then
      hosts=$(hosts_in "$flog")
      log "UPDATE-FETCH-FAILED ${drv#/nix/store/*-}: hosts its log names: ${hosts:-none} (is each allowed by the site's egress?)"
      failed=1
    fi
  done < "$fods"
  publish || failed=1
  check_releases || true
  DETAIL="fetched=$nfetch fixed_output=$nfod left_to_build=$nleft published=${PUBLISHED:-0}"
  printf '%s\n' "$DETAIL" > "$TMPDIR/detail"
  log "REPO-UPDATE $([[ $failed -eq 0 ]] && echo ok || echo FAILED) $DETAIL"
  return "$failed"
}

# newest_tag <owner/repo>: the newest release tag (vX.Y.Z, vX.Y.Z-rcN, -betaN or
# -alphaN), from GitHub's tags API. Within one version: alpha < beta < rc <
# final, then the number (2026-11-12: om3 v3.0.0-alpha111 was reported as
# newer than v3.0.0-rc62).
newest_tag() {
  local repo="$1" page tags="$TMPDIR/tags.json"
  : > "$tags"
  for page in 1 2 3 4 5; do
    run curl --fail --silent --show-error --max-time 30 --proto =https \
      "$HPS_GITHUB_API/repos/$repo/tags?per_page=100&page=$page" > "$tags.page" || return 1
    [[ "$(jq 'length' "$tags.page")" -gt 0 ]] || break
    jq -r '.[].name' "$tags.page" >> "$tags"
    [[ "$(jq 'length' "$tags.page")" -eq 100 ]] || break
  done
  jq -R -s -r '
    def key: capture("^v?(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-(?<p>[a-z]+)\\.?(?<n>[0-9]+))?$")
      | [(.a|tonumber), (.b|tonumber), (.c|tonumber),
         (if .p == null then 3 elif .p == "rc" then 2 elif .p == "beta" then 1 else 0 end),
         ((.n // "0")|tonumber)];
    split("\n") | map(select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[a-z]+\\.?[0-9]+)?$")))
    | if length == 0 then empty else max_by(key) end' "$tags"
}

# check_releases: one INPUT line per GitHub input of flake.nix (nixpkgs, a
# branch, is not a release) into state/inputs.txt and the log.
check_releases() {
  local out="$STATE_DIR/inputs.txt.tmp" line repo ref newest verdict
  : > "$out"
  while IFS= read -r line; do
    repo=$(printf '%s\n' "$line" | sed -n 's|.*url = "github:\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)\(/[^"]*\)\{0,1\}".*|\1|p')
    ref=$(printf '%s\n' "$line" | sed -n 's|.*url = "github:[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*/\([^"]*\)".*|\1|p')
    [[ -n "$repo" && "$repo" != NixOS/nixpkgs ]] || continue
    newest=$(newest_tag "$repo") || newest=""
    if [[ -z "$newest" ]]; then
      verdict=unknown
      newest=unknown
    elif [[ -z "$ref" || ! "$ref" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      verdict=unpinned
    elif [[ "$ref" == "$newest" ]]; then
      verdict=current
    else
      verdict=NEWER
    fi
    printf 'INPUT github:%s pinned=%s newest=%s %s\n' "$repo" "${ref:-none}" "$newest" "$verdict" | tee -a "$out" >&2
  done < <(grep -E '^[[:space:]]*url = "github:' "$SRC/flake.nix")
  mv -f "$out" "$STATE_DIR/inputs.txt"
}

job_seed() {
  local n
  no_egress
  unset NIX_CONFIG
  n=$(wc -l < "$PATHS")
  log "seeding $n store path(s) from $FROM (signatures not checked for this import only; each NAR is checked against its narinfo hash)"
  run nix "${NIX_FLAGS[@]}" copy --no-check-sigs --from "$FROM" --stdin < "$PATHS"
  log "re-hashing every imported path against its recorded NarHash"
  run nix "${NIX_FLAGS[@]}" store verify --no-trust --stdin < "$PATHS"
  publish || return 1
  DETAIL="seeded=$n verified=$n from=$FROM published=${PUBLISHED:-0}"
  printf '%s\n' "$DETAIL" > "$TMPDIR/detail"
  log "REPO-SEED ok $DETAIL"
}

# inner: inside the private mount namespace.
inner() {
  local rc
  if [[ "$HPS_BUILDER_NO_NS" != 1 ]]; then
    run mount --make-rprivate / || return 1
    run mount --bind "$STORE_ROOT/nix" /nix || return 1
  fi
  export PATH="$HPS_BUILDER_SYSTEM/sw/bin:$PATH"
  export TMPDIR="$MNT/tmp/$ID"
  export XDG_CACHE_HOME="$MNT/tmp/xdg-cache"
  export NIX_REMOTE=local
  run mkdir -p -- "$TMPDIR" "$XDG_CACHE_HOME" || return 1
  ( set -e; "job_$MODE" )
  rc=$?
  # errexit stays off: main reads the status, then sets it again
  [[ ! -f "$TMPDIR/detail" ]] || DETAIL=$(cat "$TMPDIR/detail")
  run rm -rf -- "$TMPDIR"
  return "$rc"
}

outer() {
  local rc pin="" log_file
  T0=$(date -u +%s)
  log_file="$STATE_DIR/build-$ID.log"
  run mkdir -p -- "$STATE_DIR"
  exec >> "$log_file" 2>&1
  log "job $ID: mode $MODE src ${SRC:--} profiles '${PROFILES:-build.sh default}'${FROM:+ from $FROM}"
  record running
  run mkdir -p -- "$STORE_ROOT" "$MNT/out" "$MNT/tmp"
  set +e
  ensure_key && ensure_cache
  rc=$?
  if [[ $rc -eq 0 ]]; then
    run nix "${NIX_FLAGS[@]}" copy --no-check-sigs --to "local?root=$STORE_ROOT" "$HPS_BUILDER_SYSTEM"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      if [[ "$HPS_BUILDER_NO_NS" == 1 ]]; then
        "$0" --inner "${ARGV[@]}"
      else
        run unshare --mount --propagation private -- "$0" --inner "${ARGV[@]}"
      fi
      rc=$?
    else
      log "copying the system closure into the disk store failed (exit $rc)"
    fi
  else
    log "the repository key or cache could not be made"
  fi
  set -e
  [[ ! -f "$STATE_DIR/$ID.detail" ]] || DETAIL=$(cat "$STATE_DIR/$ID.detail")
  rm -f -- "$STATE_DIR/$ID.detail"
  if [[ $rc -eq 0 && "$MODE" == build && -f "$MNT/out/latest" ]]; then
    pin=$(cat "$MNT/out/latest")
    record ok 0 "$pin"
    log "job $ID ($MODE) ok: pin $pin ($(( $(date -u +%s) - T0 )) s)"
  elif [[ $rc -eq 0 && "$MODE" != build ]]; then
    record ok 0
    log "job $ID ($MODE) ok ($(( $(date -u +%s) - T0 )) s)"
  else
    record failed "$rc"
    log "job $ID ($MODE) FAILED: exit $rc ($(( $(date -u +%s) - T0 )) s)"
  fi
  return "$rc"
}

main() {
  ARGV=("$@")
  parse_args "$@"
  if [[ $INNER -eq 1 ]]; then
    local rc
    set +e
    inner
    rc=$?
    set -e
    # the detail line crosses back to the outer process through the disk
    printf '%s\n' "$DETAIL" > "$STATE_DIR/$ID.detail"
    return "$rc"
  else
    outer
  fi
}

main "$@"
