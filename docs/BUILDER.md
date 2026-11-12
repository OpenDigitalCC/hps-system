# Image builder

A cluster node that builds the HPS netboot artefact sets (`nix/build.sh`) on
its own local disk, so builds leave the development host and its shared disk.
The IPS stays in control: it serves the builder the source, and it pulls each
finished pin, proving every file on its own disk before publishing it.

| what | value |
| --- | --- |
| host profile (`HOST_PROFILE`) | `BUILDER`, booting image `node-builder` |
| registry role (`TYPE`) | `BLD` (`hps-onboard assign --type BLD`) |
| Nix profile | `nix/modules/profiles/builder.nix` |
| node scripts | `builder-disk-prepare`, `builder-build`, `builder-status` (profile `node`, this image only) |
| boot units | `hps-builder-mount` (mount the disk by label), `hps-builder-http` (serve `out/`) |
| build runner | `/etc/hps/hps-builder-run`, started by `builder-build` as the transient unit `hps-builder-build` |
| IPS tools | `hps-cnh-publish --source-only` (the source tarball), `hps-pin-fetch` (pull a pin) |
| cluster key | `egress_proxy` (`http://<host>:<port>`), passed as `hps.proxy=` |

## The disk and the store

The node runs from RAM like every HPS node. Its one persistent disk carries an
ext4 filesystem labelled `hps-builder`, made once by `builder-disk-prepare`
on a device with no signature (anything else is refused, nothing written) and
mounted at every boot at `/var/lib/hps-builder` by `hps-builder-mount`, which
never formats:

```
/var/lib/hps-builder/root/nix   the build store (store URI local?root=.../root)
/var/lib/hps-builder/out        published pins, as build.sh --out writes them
/var/lib/hps-builder/cache      the file binary cache (build.sh --cache)
/var/lib/hps-builder/src        unpacked sources, one per sha256
/var/lib/hps-builder/inputs     unpacked flake inputs (ctrl-exec, ctrl-exec-plugins)
/var/lib/hps-builder/state      <id>.json, last.json, build-<id>.log
/var/lib/hps-builder/tmp        build directories, nix's fetch cache
```

The netboot image's own store is a squashfs with a RAM upper layer whose
database is registered anew at every boot; a build cache there would be lost
at each reboot and fill RAM. The build store is a second Nix store on the
disk. `hps-builder-run` copies the running system's closure into it (local,
no download; only a new image's paths are copied), then re-runs itself in a
private mount namespace (`unshare -m`) with the disk store bind-mounted at
`/nix`. There `build.sh` sees an ordinary `/nix` with the usual `/nix/store`
paths, so the NixOS binary cache applies, and nix runs as root without the
daemon. The image's `nix-daemon` stays on the RAM store and builds nothing.
The build runs in a transient unit (full root) rather than in the node
script, because nix's sandbox needs namespaces and the build users, which the
executor's `node` profile does not give, and because a build outlasts a
ctrl-exec call.

## Egress

The builder reaches the internet only through the proxy the IPS names on its
kernel command line: the cluster key `egress_proxy` becomes `hps.proxy=` on
the `node-builder` image only (a value that is not `http://<host>:<port>` is
logged and left out). `hps-builder-run` sets `https_proxy` (and `http_proxy`)
from it for nix and the build; `no_proxy` holds the IPS address. Fetches from
the IPS (`builder-build`) never use a proxy. Nothing in the image names a
proxy or an address.

A build needs `cache.nixos.org`, GitHub (`github.com`, `codeload.github.com`,
`api.github.com`, `objects.githubusercontent.com`) and, for the om3 Go
modules (not in the NixOS cache), `proxy.golang.org` and `sum.golang.org`.

## A build

```
# IPS: the source tarball (no manifest; latest untouched)
hps-cnh-publish --source-only                         # SOURCE <sha256> packages/cnh/hps-system-<sha16>.tar.gz
# builder: fetch, check, unpack, start
builder-build <sha256> [--profiles "a b"] [--input ctrl-exec=<sha256>] [--input ctrl-exec-plugins=<sha256>]
builder-status [--log N]                              # ... BUILDER state=idle last=<id> result=ok pin=<pin> seconds=<n>
# IPS: pull the pin, proved on disk
hps-pin-fetch --from http://<builder>:8090 --pin <pin> [--latest] [--rate 40m]
```

`builder-build` fetches `http://<hps.ips>/packages/cnh/hps-system-<sha16>.tar.gz`
(and each `--input` from `packages/builder/<name>-<sha16>.tar.gz`), refuses a
tarball whose sha256 is not the one given, unpacks it and starts the unit;
one build at a time. The source's own `nix/build.sh` builds it.

## Publishing: the IPS pulls

`hps-builder-http` (darkhttpd, GET only, no listing, read-only, a dynamic
user) serves `out/` on port 8090. `hps-pin-fetch` on the IPS:

1. fetches `<pin>/SHA256SUMS`, each profile's `boot.json` and `ipxe/ipxe.json`
   into a staging directory and reads them back with O_DIRECT; every hash the
   JSON files record must equal the SHA256SUMS line, and every SHA256SUMS
   path must be `<profile>/<file>`, `ipxe/<file>` or `../firmware/<file>`;
2. fetches every listed file and reads it back with O_DIRECT
   (`dd iflag=direct`, past the page cache) until it gives the listed sha256
   (3 tries by default); a firmware layer already published with that content
   is kept;
3. renames the staging directory to `nixos/<pin>`, reads every file back with
   O_DIRECT once more (re-fetching into place on a mismatch), and requires
   `hps-pins verify`;
4. sets `latest` only with `--latest`.

A pin that never proves is moved aside to `nixos/.failed-<pin>-<time>` and
the command fails; `latest` is untouched. A pin already published with the
same SHA256SUMS (the same content built elsewhere) is proved and accepted.

The hashes come from the store: `nix/build.sh` reads each store original and
each published copy with O_DIRECT and rewrites a copy that differs; boot.json,
ipxe.json and SHA256SUMS record that proved hash, never a new read of the
copy (IPS-33 #3, #3b). The same applies to builds on the development host.

## Bring-up

```
hps-workload create builder; hps-workload start builder     # boot: network; audited, HELD
hps-onboard assign <mac> --type BLD --profile BUILDER --os x86_64:nixos:26.05 --pin <pin> --storage "builder disk"
hps-run.sh <builder> builder-disk-prepare /dev/disk/by-id/virtio-<vm>-d1
```

The disk is formatted only by the explicit `builder-disk-prepare` call and
only when it is blank; after a reboot the same disk and store are used again.
Outputs are not pruned yet: `builder-status` shows disk use.
