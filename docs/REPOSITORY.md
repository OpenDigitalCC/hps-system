# Site repository

One repository per site holds what nodes are built from, so a node can be
built with no upstream, as of the repository's last update
(`plans/ips-repository.md`, owner decisions of 2026-11-12). It serves every
cluster on the site; inner hosts reach it by routing. The IPS stays small: it
keeps no copy of the build inputs.

**Stage 1: the repository lives on the image builder's disk** (role `BLD`,
`docs/BUILDER.md`), as the site repository role of that node. A separate
repository node can come later; the layout, the verbs and the keys do not
change when it does.

| what | value |
| --- | --- |
| where | the builder disk, `/var/lib/hps-builder/repo/` |
| Nix binary cache | `repo/nix-cache/` (file cache, zstd, every narinfo signed), served read-only as `http://<repository>:8091/nix-cache/` |
| public key | `repo/repo.pub`, served as `http://<repository>:8091/repo.pub`; printed by `repo-status` as `REPO-PUBKEY` |
| signing key | `/var/lib/hps-builder/keys/repo.secret` (directory 0700, file 0600), made on the node at first use; never served, never sent |
| pins | `out/` (as before), served read-only on port 8090 by `hps-builder-http` |
| images, packages | room under `repo/` for later stages |
| node scripts | `repo-seed`, `repo-update`, `repo-status`, and `builder-build` for repo build (builder image only) |
| job runner | `hps-builder-run --mode build\|update\|seed`, the transient unit `hps-builder-build` (one job at a time) |
| server | `hps-repo-http` (darkhttpd, GET only, no listing, a dynamic user, the key directory inaccessible) |
| IPS tool | `hps-repo update\|build\|seed\|status` (an ips-admin script, so it works through `hps-op`) |
| cluster keys | `repo_host` (required), `repo_nix_pubkey`, `repo_upstream` (default `false`), and `egress_proxy` for update |

## Signing and trust

- The first job on a repository makes its key pair with `nix-store
  --generate-binary-cache-key hps-repo-<host>-1`. The secret stays under
  `/var/lib/hps-builder/keys` on the node's own disk; both HTTP servers have
  that directory made inaccessible. Half a key (one file missing) is refused,
  never replaced.
- Everything enters the cache through one route: `nix copy --to
  'file://<cache>?compression=zstd&secret-key=<secret>'`, which signs each
  narinfo as it is written. After every job a sweep finds any narinfo without
  the repository signature (an older `build.sh` writing unsigned) and signs it
  with `nix store sign`; a path left unsigned fails the job.
- `hps-repo status` stores the printed public key as the cluster key
  `repo_nix_pubkey` when that is empty. A different key on the node (a new
  repository, a replaced disk) is reported and exits 3; the stored key is never
  overwritten. To accept a new key, clear `repo_nix_pubkey` and run status
  again.
- **repo build** trusts the repository key alone: `substituters =
  file://<cache>`, `trusted-public-keys = <repository key>`, no proxy. With
  `repo_upstream=true` it also keeps the system's substituters (the NixOS
  cache) and their key, through the egress proxy; the repository comes first
  (its `Priority: 10`).
- **repo update** substitutes from the repository and the system's
  substituters, through the egress proxy.
- **repo seed** is the one import that does not check signatures (`nix copy
  --no-check-sigs --from <cache>`): the IPS's PoC cache is unsigned. Each NAR
  is still checked by nix on import against its narinfo `NarHash` and
  `NarSize` (a mismatch fails the import), then `nix store verify --no-trust`
  hashes every imported path again from disk; only then is it signed into the
  repository. (`--no-check-sigs` also copies the running system's closure into
  the disk store, local to local, as before.)

## Operator actions

```
hps-repo status [--log N] [--json]
hps-repo seed   [--from ips|http://<host>[:port]/<path>] [--paths FILE] [--wait S]
hps-repo update [--source SHA256] [--profiles a,b] [--input NAME=SHA256]... [--wait S]
hps-repo build  [--source SHA256] [--profiles a,b] [--input NAME=SHA256]... [--wait S]
```

Each verb runs on the host the cluster key `repo_host` names (a registry
HOSTNAME or MAC); with no `repo_host` every verb is refused. Through the
operator API: `hps-op --cred FILE hps-repo status`. `seed`, `update` and
`build` outlast a ctrl-exec call: the node script starts the unit and
returns (`REPO-STARTED mode=<verb> id=<id> host=<host>`); follow it with
`hps-repo status`, or wait with `--wait S` (local use). Through ips-admin
arguments are tokens: `--profiles a,b`, and `seed` only from the IPS's own
cache (a URL has a `/`).

- **hps-repo status** (`repo-status`): the public key, the cache (paths,
  signed, unsigned, NAR bytes), every package HPS built itself (`PACKAGE
  <name> <version> <store path> signed=<yes|no>`: a path with no upstream
  signature whose name is HPS's own, `om3*` with its Go modules, `ctrl-exec-agent-*`, `hps-nagios-plugins`,
  `hps-netboot-*`, `hps-ipxe-*`, `hps-firmware-layer-*`; the NixOS-generated files are not listed), the pins, the last job and the `INPUT` lines of the last update.
  Last line `REPO state= key= paths= signed= unsigned= packages= pins=
  last=<mode>:<id>:<result> newer=<n>`.
- **hps-repo seed** (`repo-seed`): import a binary cache. `--from ips` (the
  default) is this IPS's `/nix-cache/`; hps-repo lists its store paths from
  `<resources>/nix-cache/*.narinfo` into
  `packages/repo/seed-<sha16>.txt`, and the node fetches that list straight
  from the IPS and checks its sha256 and every line. Another cache needs
  `--paths FILE` (its store paths). This is how a repository is filled on a
  site with no egress, and how the lab repository got om3 (step 2 below).
- **hps-repo update** (`repo-update`): fill the repository from upstream for
  a source tree, through the site's egress (`https_proxy` from
  `egress_proxy`). For every profile of the source's `build.sh` and `ipxe`
  it runs `nix build --dry-run`, substitutes every path nix would fetch, and
  builds every fixed-output derivation nix would build (sources, om3's Go
  modules: fetches); it builds no image. Everything in the store is then
  signed into the repository. A fetch that fails names the hosts its log
  names (`UPDATE-FETCH-FAILED <drv>: hosts its log names: ...`): om3's Go
  modules come from `proxy.golang.org`, which redirects to
  `storage.googleapis.com`, a host the lab proxy does not allow. Then each
  GitHub input of `flake.nix` pinned to a release tag (om3-src,
  ctrl-exec-plugins; ctrl-exec follows its branch, so it is `unpinned`) is
  compared with its newest release tag from GitHub's tags API, through the
  proxy: `INPUT github:<owner>/<repo> pinned=<tag> newest=<tag>
  <current|NEWER|unpinned|unknown>`, kept in `state/inputs.txt` and shown by
  status. A bump is a source change (`flake.nix` and om3's `vendorHash`),
  never made by update.
- **hps-repo build** (`builder-build`, plus `--upstream` when
  `repo_upstream` is true): the source's `nix/build.sh` with the repository
  and the builder's store as the only substituters, its copies into the
  repository signed (`BUILD_CACHE_PARAMS`). After the build, ok or not, every
  path in the store (no `.drv`) is signed into the repository, so whatever it
  built or fetched is kept: om3, its Go modules, the ctrl-exec builds, the
  images. The pin is in `out/` (port 8090), from which the IPS pulls it:
  `hps-pin-fetch --from http://<repository>:8090 --pin <pin> [--latest]`.

The source tree is this IPS's own hps-system, published with `hps-cnh-publish
--source-only` (or `--source SHA256` for one already in `packages/cnh/`).
`--input ctrl-exec=<sha256>` and `ctrl-exec-plugins=<sha256>` take tarballs
from `packages/builder/`, as `builder-build` does.

## What moved out of the IPS

- Builds substitute from the site repository and write back to it, signed;
  the builder's unsigned file cache (`/var/lib/hps-builder/cache`) is no
  longer written, and no builder ever reads the IPS's `/nix-cache/`.
- The IPS's `hps-resources/nix-cache` (the unsigned PoC cache that dev-host
  builds fill) stays served at `/nix-cache/` for now, as a seed source only.
  The Alpine/yum mirroring in `lib/functions.d/repo-functions.sh` is
  untouched. Retiring both is a later stage.

## Lab

`lab/builder/repo-build.sh` (in the lab tree): seed the builder's repository
from the lab IPS's cache, then one repo build, then `hps-pin-fetch` into the
lab IPS.
