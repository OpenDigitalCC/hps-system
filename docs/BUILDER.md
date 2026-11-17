# Image builder

A cluster node that builds the HPS netboot artefact sets (`nix/build.sh`) on
its own local disk, so builds leave the development host and its shared disk.

The builder's disk also holds the **site repository** (`docs/REPOSITORY.md`):
the signed Nix binary cache builds substitute from and write back to, so a
node can be built with no upstream.

| what | value |
| --- | --- |
| host profile (`HOST_PROFILE`) | `BUILDER`, booting image `node-builder` |
| registry role (`TYPE`) | `BLD` (`hps-onboard assign --type BLD`) |
| Nix profile | `nix/modules/profiles/builder.nix` |
| node scripts | `builder-disk-prepare`, `builder-build`, `builder-status`, and the repository's `repo-seed`, `repo-update`, `repo-status` (profile `node`, this image only) |
| boot units | `hps-builder-mount` (mount the disk by label), `hps-builder-http` (serve `out/` on 8090), `hps-repo-http` (serve `repo/` on 8091) |
| build runner | `/etc/hps/hps-builder-run`, started by `builder-build` as the transient unit `hps-builder-build` |
| IPS tools | `hps-cnh-publish --source-only` (the source tarball), `hps-pin-fetch` (pull a pin), `hps-repo` (the repository verbs) |
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
/var/lib/hps-builder/repo       the site repository: nix-cache/ (signed), repo.pub
/var/lib/hps-builder/keys       the repository signing key (0700; never served)
/var/lib/hps-builder/cache      the unsigned file cache of builds before the repository (no longer written)
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
kernel command line, and only for `repo-update` and a build with `--upstream`
(cluster key `repo_upstream`); a plain build uses the site repository alone
and sets no proxy (`docs/REPOSITORY.md`). The proxy: the cluster key `egress_proxy` becomes `hps.proxy=` on
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
builder-build <sha256> [--profiles "a b"] [--input ctrl-exec=<sha256>] [--input ctrl-exec-plugins=<sha256>] [--upstream]
builder-status [--log N]                              # ... BUILDER state=idle last=<id> result=ok pin=<pin> seconds=<n>
# IPS: pull the pin, proved on disk
hps-pin-fetch --from http://<builder>:8090 --pin <pin> [--latest] [--rate 40m]
```

`builder-build` fetches `http://<hps.ips>/packages/cnh/hps-system-<sha16>.tar.gz`
(and each `--input` from `packages/builder/<name>-<sha16>.tar.gz`), refuses a
tarball whose sha256 is not the one given, unpacks it and starts the unit;
one job at a time. The source's own `nix/build.sh` builds it, with the site
repository as its substituter and its cache (`--cache <repo>/nix-cache`,
signed); then everything in the store is signed into the repository.
`hps-repo build` on the IPS is the same call, through the cluster key
`repo_host`.

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

## Local packages

The builder also makes the **local packages** (`docs/BUNDLE.md` "Local packages",
`docs/STARTER.md`): packages the distributions do not have. `nix/build.sh` has a
package mode: `builder-build <source> --profiles "pkg-om3 out-om3-static" [--upstream]`
(the one preset action; the names fit its profile check). A name starting `pkg-` or
`out-` is a package attribute of the flake (`packages.x86_64-linux.<attr>`), built
by name from the same source and lock the images use; nothing else is a pin, and
`latest` is not touched. A mixture with netboot profiles is refused.

| name | result in `out/pkgs/<attr>/` | for |
| --- | --- | --- |
| `pkg-<attr>` | `cache/` (the closure as a Nix binary cache, xz), `pkg.json`, `SHA256SUMS`; the closure is also signed into the site repository | a NixOS node (`hps-starter add-local nixos --from`) |
| `out-<attr>` | `files/` (the output, links resolved), `pkg.json`, `SHA256SUMS` | the Alpine packages |

`--upstream` is needed when the site repository lacks something (the static
toolchain, qemu): the build then substitutes from the NixOS cache through the egress
proxy. A static Go build needs nothing new: its modules are the fixed-output fetch
the dynamic om3 already has (same `vendorHash`).

Flake attributes: `ctrl-exec-agent`, `om3`, `om3-static` (`om3.nix` with `static = true`:
`CGO_ENABLED=0`), `ctrl-exec-executor-static` (`nix/pkgs/ctrl-exec-executor-static.nix`:
`pkgsStatic`, musl, static libcap, `-static`), `qemu-host-cpu-only` and `qemu-headless`.

Lab recipes (`lab/builder/`, plain files; they refuse quiet hours and take the
`tmp/dl360-build.lock`):

```
HPS_SRC=<tree> bash lab/builder/pkg-build.sh [--upstream] pkg-om3 pkg-ctrl-exec-agent   # NixOS, by name
bash lab/builder/pkg-fetch.sh <attr> <dir>        # builder :8090/pkgs/<attr> -> <dir>/<attr>, every file hashed
bash lab/builder/ips-add-local.sh nixos <dir> om3 ctrl-exec-agent
HPS_SRC=<tree> bash lab/builder/pkg-build.sh --upstream out-ctrl-exec-executor-static out-om3-static
bash lab/builder/alpine-apks.sh <dir> <apk-dir>   # HPS::Apk::pack_apk (alpine-apks.pl), `file` must say static
bash lab/builder/ips-add-local.sh alpine <apk-dir>   # add-local, sync alpine, verify
```

**NixOS.** `ctrl-exec-agent` and `om3` built by name give the store paths the package
list already names (`s9s4irf4...-ctrl-exec-agent-0.14.7`, `icpkmfz7...-om3-3.0.0-rc62`),
so no list line changes.

**Alpine.** The executor and `om` are static (musl, no libc). The apks (`root:root`,
unsigned, no install script): `ctrl-exec-agent` (`/usr/bin/ctrl-exec-agent`, `cea`,
`/usr/bin/ctrl-exec-executor`, `/usr/lib/ctrl-exec`, the patches `nix/package.nix`
makes; depends perl, perl-json, perl-io-socket-ssl, perl-net-ssleay, openssl), `om3`
(`/usr/bin/om`), `nagios-check` (`/usr/bin/nagios-check`; perl) and `hps-nagios-plugins`
(`/usr/lib/hps-nagios-plugins`: `check_mem` and REAL COPIES of `check_disk`, `check_load`,
`check_procs` from Alpine's `monitoring-plugins`, which it depends on, because
`nagios-check` refuses a plugin that resolves outside its directory). The executor
runs as root from its own service on both systems; the NixOS package sets no file
capability either, so the apk carries none.

**Headless QEMU.** `qemu-headless` is `qemu-host-cpu-only` with GTK, SDL, OpenGL,
audio, SPICE, USB redirection, smartcard, curses and the manual off (VNC, iSCSI,
io_uring and the guest agent stay). Closure on the builder 2026-11-17: `qemu-host-cpu-only`
1,558,838,312 bytes (1,486.6 MiB), `qemu-headless` 578,369,480 bytes (551.6 MiB). The
package list is not switched to it; the owner decides after a node measurement.

**Not possible with the present builder: Alpine libvirt with the AppArmor driver.** It
needs an Alpine chroot with `abuild`, i.e. root (`chroot`, mounts, `apk add`) and a
node script to start it; the builder's allowlist has none and its image would change.
Verified from libvirt 12.3.0 and Alpine's 3.24-stable `APKBUILD`: the meson options
are `-Dapparmor=enabled -Dsecdriver_apparmor=enabled` (`apparmor_profiles` optional);
the helper is `LIBEXECDIR/virt-aa-helper` (Alpine sets `--libexec=/usr/lib/libvirt`,
the adapter looks in `/usr/libexec`), and the profile directory is compiled as
`sysconfdir/apparmor.d/libvirt` (`/etc/apparmor.d/libvirt/TEMPLATE.qemu`, `<uuid>`,
`<uuid>.files`), where the role step writes to `/var/lib/apparmor.d/libvirt`.
