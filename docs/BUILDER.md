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
| node scripts | `builder-disk-prepare`, `builder-build`, `builder-apk-build`, `builder-status`, and the repository's `repo-seed`, `repo-update`, `repo-status` (profile `node`, this image only) |
| boot units | `hps-builder-mount` (mount the disk by label), `hps-builder-http` (serve `out/` on 8090), `hps-repo-http` (serve `repo/` on 8091) |
| build runner | `/etc/hps/hps-builder-run`, started by `builder-build` as the transient unit `hps-builder-build`; `/etc/hps/hps-apk-build` and `hps-apk-inner`, started by `builder-apk-build` ("Local packages: the Alpine chroot") |
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

**Alpine libvirt with the AppArmor driver** is the one package that needs the Alpine
chroot below: it has to be built from Alpine's own `APKBUILD`, which needs root
(`chroot`, mounts, `apk add`) and a node script to start it. The facts it rests on,
verified from the libvirt 12.3.0 sources and Alpine's 3.24-stable `APKBUILD`
(copies under the step 5 notes): the meson options are `-Dapparmor=enabled
-Dsecdriver_apparmor=enabled`; `apparmor_profiles` is a feature option that defaults to
`auto`, which would install upstream's `usr.sbin.libvirtd`, `usr.lib.libvirt.virt-aa-helper`,
the abstraction `libvirt-qemu` and `libvirt/TEMPLATE.qemu` under `/etc/apparmor.d`, so the
recipe sets it `disabled` (`node-manager/apparmor/` stays the one source of the texts);
the helper is `LIBEXECDIR/virt-aa-helper` and Alpine sets `--libexec=/usr/lib/libvirt`,
so it is `/usr/lib/libvirt/virt-aa-helper`; the profile directory is compiled in as
`sysconfdir/apparmor.d/libvirt` (`/etc/apparmor.d/libvirt/` with `TEMPLATE.qemu`,
`<uuid>`, `<uuid>.files`). The node side follows these paths (adapter answers
`aa_helper_path`, `aa_profile_dir`: "Local packages: the Alpine chroot" and
`docs/BUNDLE.md` "AppArmor").

### Local packages: the Alpine chroot

The preset action `builder-apk-build <source-sha256> <recipe>` (node script, profile `node`,
builder image only) builds an Alpine package set from a **recipe** of the HPS source tree.
The source is the one `builder-build` takes (`hps-cnh-publish --source-only`, fetched from
the IPS, sha256 checked); the recipe name is one word, `[a-z][a-z0-9-]{0,39}`, and must be a
real directory `alpine/recipes/<name>` of that unpacked source (listed and compared, a link
or a directory without `PINS` and `recipe.conf` is refused). No other argument exists: no
path, URL, option or code comes from the caller. The script starts `/etc/hps/hps-apk-build`
as the transient unit `hps-builder-build` (the unit nix builds and the repository jobs use,
so one job at a time and `builder-status` reports it, mode `apk`).

```
HPS_SRC=<tree> bash lab/builder/apk-build.sh libvirt-apparmor          # the lab recipe (plain file)
bash lab/builder/pkg-fetch.sh libvirt-apparmor <dir>                   # builder :8090/pkgs/libvirt-apparmor
bash lab/builder/ips-add-local.sh alpine <dir>/libvirt-apparmor/files  # add-local, sync alpine, verify
```

**A recipe is data.** `alpine/recipes/<name>/` holds `PINS` (everything the build takes from
outside the tree, with sha256 or commit ids; one file), `recipe.conf` (the package set and the
checks) and the patch it names. The runner parses them with a strict reader (no sourcing, each
value matched to a pattern; an unknown key is refused) and executes nothing from them. What
runs is `hps-apk-build` and `hps-apk-inner`, both files of the builder image
(`node-manager/nixos-26/boot/`).

**The job**, in order:

1. Read the recipe. A value of `RECORD-ME` in `PINS` means it was never recorded: the job then
   fetches what the pins name, prints every value it saw as `PIN-OBSERVED` lines in the build log
   (`builder-status --log 60`), says whether each equals what is pinned, uses none of it and ends
   with exit 4. A person compares the values with Alpine's own listing and the aports commit,
   writes them into `PINS`, commits and publishes a new source. Only a recipe whose pins are all
   recorded builds.
2. Fetch, through the egress proxy only (`hps.proxy=`; no proxy on the kernel line is a refusal)
   and over https only: the Alpine minirootfs of the pinned release (sha256 pinned), and each file
   of the pinned aports commit's directory by commit id (`raw/<commit>/community/libvirt/<file>`,
   each sha256 pinned). The libvirt tarball is fetched inside the chroot, with `curl`, from the URL in the
   (patched) `APKBUILD` (https only; abuild's own fetcher, busybox wget, cannot use an https proxy: the proxy
   answers "405 Only CONNECT") into abuild's distfiles directory, and `abuild` checks it against the sha512
   that `APKBUILD` carries.
3. The chroot lives on the builder disk, `apk/chroot/<release>-<sha12>`, made once from the
   verified minirootfs and kept (the packages it installs and the source cache are kept with it). Every
   run enters it through `unshare --mount --pid --fork --ipc --uts`: a tmpfs `/dev` with six device
   nodes (the host's `/dev` is never mounted in), the PID namespace's own `/proc`, the host's
   `resolv.conf`, the Alpine repositories of the pinned release, and an environment of nothing but
   `PATH`, `HOME` and the proxy variables.
4. As root in the chroot: `apk add bash curl alpine-sdk` (Alpine's signed packages; apk verifies them with
   the keys of the minirootfs, `--allow-untrusted` is never used), then `hps-apk-inner prepare`: the
   unprivileged user `builder` (uid 1000, group `abuild`), a clean build tree, the staged aports
   files, the recipe's patch applied by `builder` with no fuzz (a patch that does not fit the pinned
   `APKBUILD` fails the job), and the `makedepends` of the PATCHED `APKBUILD` (read by `builder`)
   installed with apk as root, so
   that the network is reached with the proxy variables and not through abuild's sudo helper. A
   dependency on the package's own name (libvirt's `depends_dev`) is left out. Last, `prepare` makes the
   job's throwaway abuild key as `builder` (`abuild-keygen -a -n`) and puts its public half in the chroot's
   `/etc/apk/keys`, because abuild reads the packages back to make the index and refuses ones it does not
   trust. The runner removes both halves when the job ends, success or failure (and the next `prepare`
   does, should a job have been killed); the key never leaves the chroot, and HPS adds no signing layer:
   nodes install local packages with `--allow-untrusted` from the IPS's local repository.
5. As `builder`: `hps-apk-inner build` fetches the sources (above) and runs `abuild -d` (sha512 check,
   unpack, build, package, index).
6. Select the recipe's `parts` from what was built (the split is Alpine's: `libvirt`, `-client`,
   `-daemon`, `-daemon-openrc`, `-libs`, `-qemu`, `-common-drivers`), build the meta package
   `libvirt-apparmor` whose `depends` are those packages at the version-release read from the built
   files (nothing is written down: a different release is followed), and verify (below).
7. Publish `out/pkgs/<recipe>/files/*.apk`, `pkg.json` (packages with sha256, aports commit, minirootfs
   sha256), `SHA256SUMS`: the layout `lab/builder/pkg-fetch.sh` and `hps-starter add-local` take unchanged.
   The directory is replaced whole; a failed job leaves the previous one.

**What is verified** (the job fails otherwise, nothing is published): every part exists and has the same
version, with a release of at least `min_pkgrel` (100: the patch took effect; apk prefers `-r100` to
Alpine's `-r0` of the same version); `usr/lib/libvirt/virt-aa-helper` is in a package of the set; a
library under `usr/lib` of the set carries the string `/usr/lib/libvirt/virt-aa-helper` (the security
driver compiles the helper's path in as a constant, so a build without the driver has none; the stock
build does not); no package holds a file under `etc/apparmor.d`; every dependency on one of the
set's own names is an exact version-release of a package in the set.

**Package naming and the node.** The rebuilt packages keep Alpine's names, at release 100.
`lib/starter/alpine.packages` names only `libvirt-apparmor local`. `hps-starter sync alpine` takes
every apk in `local/alpine/<release>/` as a candidate that replaces the snapshot's package of
the same name in the resolution (the roots are the names the list marks `local`; the others join
when something depends on them), so the closure holds the whole rebuilt set in the local repository
and **no stock `libvirt-*` package**: the stock daemon is neither fetched nor held, and a role
that names `libvirt-apparmor` cannot get it. The local index carries `install_if`, provider priority and origin
as abuild wrote them. The role's refusal is unchanged: `role_apparmor` fails the compute step when
`/usr/lib/libvirt/virt-aa-helper` is missing.

**What the builder gains.** (The statement for the owner; the same text is in the CHANGELOG.)

- *New action:* `builder-apk-build <source-sha256> <recipe>`, preset, profile `node`, builder image only.
  The action itself only fetches the tarball from the IPS (never through the proxy), checks its sha256
  and starts a transient unit.
- *What runs as root:* the unit `hps-builder-build` runs `hps-apk-build` as root, as it already does for
  `hps-builder-run`: `unshare` (new mount, PID, IPC and UTS namespaces), `mount` (tmpfs `/dev`, `proc`) and
  `mknod` of six nodes inside them, `tar` of the verified minirootfs, `chroot`, and inside the chroot as
  root `apk add` of Alpine's signed packages and the makedepends (whose install scripts run as root
  there). The compilation and `abuild` run as an unprivileged user in the chroot.
- *What it can fetch:* over https, through the egress proxy only, from the hosts the recipe's `PINS` and
  the (patched) `APKBUILD` name, which the proxy must allow for the builder: `dl-cdn.alpinelinux.org`
  (minirootfs, apk repositories), `gitlab.alpinelinux.org` (the pinned commit's files; and the commit
  lookup in record mode), `download.libvirt.org` (the tarball). Each pinned file is verified by sha256
  before use; the packages by apk's signatures; the tarball by the `APKBUILD`'s sha512.
- *What an attacker who controls only the dispatcher could do with it:* start the build of a recipe that
  the IPS's source tarball holds (today `libvirt-apparmor`), as often as he likes, one at a time. Each run
  costs the builder disk space, CPU and proxy traffic and replaces `out/pkgs/<recipe>/` with a build of the
  same pinned inputs. He cannot choose a URL, a path, a package name, an option or a script, and cannot
  make the builder fetch from a host the recipe's pins do not name (or from one the proxy does not allow).
- *What it adds if he also controls the IPS:* nothing that `builder-build` does not already give him.
  `builder-build` runs the served source's `nix/build.sh` as root, so whoever can publish a source tarball
  already has root on the builder. A recipe in such a tarball is data (pins and a patch), but the pins and
  the patch are his too: he can make the chroot build whatever Alpine's mirror and the tarball hosts serve,
  and the root part of that is `apk add` of Alpine-signed packages inside the chroot. The action is a
  second route to the same trust (the source tarball and its sha256), not a wider one.
- *What it cannot do:* it does not write outside the builder disk's `apk/`, `tmp/`, `state/` and
  `out/pkgs/<recipe>/`; it does not touch `out/<pin>` or `latest`, the site repository or its key; it does
  not accept an argument beyond the two; the chroot is not a security boundary against a hostile root
  inside it (a package install script or a compromised pinned tarball that reached root there could leave
  the chroot), which is why everything that reaches root there is signed by Alpine or pinned by hash, and
  the build itself runs unprivileged. The build has the builder's network (no network namespace: the
  proxy is reached from the chroot), so a compromised build can reach the cluster LAN as the builder can.
