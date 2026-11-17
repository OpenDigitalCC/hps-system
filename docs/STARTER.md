# Stock starter and package repository

The IPS holds, per OS and release, two sets of plain files that it serves over
its own web server: the **starter** (the distribution's own kernel and
initramfs, unmodified, with no HPS logic in it) and a **package repository**
(the applications that go on top). One verb, `hps-starter`, fills both from
upstream while upstream is reachable. After that the IPS needs no upstream to
boot a node or to give it packages. This is step 1 of `plans/PLAN.md`; the
node bundle that uses them is step 2. The site repository of
`docs/REPOSITORY.md` (built images, held on the builder) is a separate thing
and stays until the image profiles are retired.

## Layout

| what | where on the IPS | URL |
| --- | --- | --- |
| starter | `<resources>/starter/<os>/<version>/` | `http://<ips>/starter/<os>/<version>/` |
| package repository | `<resources>/packages/<os>/<version>/` | `http://<ips>/packages/<os>/<version>/` |

`<resources>` is `/srv/hps-resources` on the IPS. `<os>` is `nixos` or `alpine`
(`Alpine`, below) and `<version>` is the OS release (`26.05`, `3.24`), the
same word that ends the host's `os_id` (`x86_64:nixos:26.05`). The `starter/`
tree is aliased by the generated lighttpd configuration, so an IPS must be
restarted (or its web server configuration regenerated) once after this
change; `packages/` was served already.

NixOS starter, `starter/nixos/26.05/`:

| file | what |
| --- | --- |
| `bzImage`, `initrd` | Hydra's stock netboot build of the release job `nixos/release-26.05/nixos.netboot.x86_64-linux`, byte for byte |
| `netboot.ipxe` | Hydra's own boot script, kept as the record of the stock arguments |
| `manifest.json` | see below |

NixOS package repository, `packages/nixos/26.05/`: a plain HTTP Nix binary
cache. `nix-cache-info`, one `<hash>.narinfo` per store path and the
`nar/<hash>.nar.xz` files they name, exactly as `cache.nixos.org` publishes
them, so the upstream signatures stay valid (a node trusts the stock key). It
holds the closure of the packages in `lib/starter/nixos.packages` (libvirt,
QEMU, open-iscsi, mdadm, targetcli-fb, jq, smartmontools, tcpdump, xxd, and om3 as a
local package, perl, the Perl modules and openssl the agent needs); ZFS is already in the starter. Which node gets which package is
`lib/starter/nixos.roles` (`docs/BUNDLE.md`). A node reads the repository with
`--option substituters http://<ips>/packages/nixos/26.05`.

## Manifests

Each directory ends with `manifest.json`, written last, so a directory with a
manifest is complete. It records the upstream release identity
(`26.05.14234.f1e5c356f35d`), when it was synced and, for every file, its size
and sha256. The starter manifest also gives each file's upstream URL, the
Hydra build number, the stock kernel arguments (`cmdline`) and the `init` path.
The repository manifest gives the upstream cache, the store path list it was
resolved from, the package list's sha256 and the store path each package name
resolved to (`roots`); a file's URL is the upstream cache plus its path.

## The verb

```
hps-starter sync <os> [--release V] [--only starter|repository] [--proxy http://HOST:PORT]
                      [--packages FILE] [--store-paths FILE] [--hydra URL] [--releases URL] [--cache URL]
hps-starter list [--json]
hps-starter verify [<os> [--release V]]
```

On the IPS: `docker exec hps-lab-ips /srv/hps-system/bin/hps-starter sync nixos`
(an IPS tool; it writes the resources tree, so it runs as root on the IPS).

`sync`
: Fills the starter and the repository. The proxy is `--proxy`, else the
  cluster key `egress_proxy`, else none. A file that is present with the
  recorded size and sha256 is kept. Anything else goes to a temporary name,
  is checked (the starter against Hydra's record, a nar against its narinfo
  `FileSize` and `FileHash`) and is renamed into place. A second run with an
  unchanged release and package list fetches no nar and no narinfo. When the
  package list changes, what the repository no longer holds is removed. When
  upstream refuses or cannot be reached, `sync` stops with exit 1 and a line
  that names the host, the proxy used and the URL, for example
  `upstream refused or unreachable via proxy http://10.100.1.2:3128: host
  hydra.nixos.org: curl: (56) CONNECT tunnel failed, response 403`.
  `sync alpine` is its own section below (`--alpine URL` names its upstream root).
  `--only starter` or `--only repository` fills one part (the repository
  follows the release of the synced starter). `--hydra`, `--releases` and
  `--cache` replace the three upstream roots with a mirror, or with a
  `file:///dir` laid out the same way (the tests and the first lab trial use
  that: no network).

`list`
: One row per synced starter and repository: OS, release, release identity,
  file count, size, time of the sync.

`verify`
: Reads every file back against its manifest (size and sha256). Last line
  `VERIFY ok sets=2 bad=0`; exit 1 when a file is missing or differs, 4 when
  nothing is synced.

`sync` also keeps the OS registry entry `x86_64:<os>:<release>` that `hps-onboard assign --os`
needs ("OS ... is not in the OS registry" otherwise). It writes name, version, arch, status
`prod`, `hps_types` and `boot` (`manifest` for NixOS, as `os_seed_nixos` makes it, `starter` for
Alpine) every time, over whatever is there, so a hand-made entry becomes the one the sync writes and a
second sync changes nothing. On a host with no IPS configuration (`/srv/hps-config`) it writes none.

### What `sync nixos` needs from the host

- `curl`, and for the repository `xz` (the package `xz-utils`) to read the
  release's `store-paths.xz`. Without `xz`, `--store-paths FILE` names the list
  already decompressed (`xz -dc store-paths.xz > store-paths.txt`).
- Upstream hosts, all HTTPS on port 443: `hydra.nixos.org` (the starter),
  `releases.nixos.org` (the release's store path list) and `cache.nixos.org`
  (the repository). A proxy that allowlists hosts must allow these three.

### How a package name becomes a store path

The IPS has no Nix. The release publishes `store-paths.xz`, every store path of
the release for every system. A line of `lib/starter/nixos.packages` such as
`libvirt` matches `libvirt-<version>` in it; the release's x86_64 copy is the
candidate whose closure holds the starter's own glibc. The closure is walked
over HTTP through the `References:` lines of the narinfo files. Two x86_64
candidates for one name (openssl, which the release holds in several versions)
are refused, not guessed; a pure-Perl module cannot be told from its other
systems this way. For those a line of the list can be `NAME /nix/store/<hash>-<name>`:
the store path is the root as it stands, with no search (the list names the
`JSON` module that the starter already holds, and the bin output of the
starter's own openssl; `docs/BUNDLE.md`).

## Alpine

`hps-starter sync alpine` (release `3.24`, Alpine 3.24.4) makes two sets from ONE
snapshot of Alpine's repository, plain files like the NixOS ones:

| what | where on the IPS | holds |
| --- | --- | --- |
| starter | `starter/alpine/3.24/` | `vmlinuz-lts`, `initramfs-lts`, `manifest.json` |
| repository | `packages/alpine/3.24/{main,community}/x86_64/` | Alpine's own `APKINDEX.tar.gz` and the `.apk` files of the closure, byte for byte |
| local repository | `packages/alpine/3.24/local/x86_64/` | the local packages and an unsigned index, only when there are some |

The index is read once, `lib/starter/alpine.packages` is resolved in it (depends, provides,
`install_if`: the `-openrc` subpackages), and every package is proved against its index line
(size and the control-stream checksum `C:`). A package that pins another exactly (`zfs-lts`
needs `linux-lts=6.18.63-r0`) must find that version in the set, else the sync refuses:
the repository is not one snapshot, and a ZFS module loads only into the kernel it was built
for. Alpine's signatures are kept as they are; `apk` on the node checks them with the stock
keys. HPS signs nothing.

**The matched starter.** The netboot kernel of a point release lags the repository (3.24.4 shipped
6.18.60, the repository has 6.18.63 and `zfs-lts` only for that). When they are the same, the stock
`vmlinuz-lts` and `initramfs-lts` are used byte for byte. When they differ, the starter is
`boot/vmlinuz-lts` of the repository's `linux-lts` package (the file the netboot tree is made of) and
the stock initramfs with its module directory replaced by the repository kernel's: the same module
names, their dependencies from `modules.dep`, and the kernel's own module index files, so the
initramfs loads its drivers. Everything else in it, `init` included, is the stock file; a test
compares them. The manifest says `assembled`, the two kernel releases, and the sha256 of both stock
files. Nothing is compiled and nothing is built from source: the assembly is a gzip and a cpio.

**No modloop.** The stock netboot loads a 290 MiB squashfs of modules and firmware into RAM; that
file cannot be rebuilt without breaking its signature. The starter runs with `modloop=none` and the
node installs `linux-lts` from the repository (signed) into RAM with `apk`, without scripts,
`linux-firmware-none` satisfying the kernel's firmware dependency (the 108 firmware packages, 930 MiB
of the repository the feasibility check measured, are not held or sent).

**Local packages.** A line `NAME local` in the list names a package that Alpine does not have
(`ctrl-exec-agent`, `om3`, `nagios-check`, `hps-nagios-plugins`). `hps-starter add-local alpine --from DIR
FILE.apk...` copies built `.apk` files to `local/alpine/3.24/`; `sync` puts them in the repository's
`local/` directory with an index it writes itself (`HPS::Apk`, plain Perl). They carry no Alpine
signature and a node installs them knowing so (`--allow-untrusted`, from the local repository only).
Until a package is added, `sync` ends with `missing_local=...` and says so; a role that names it is
refused by the package list (`node_role_packages`), never silently left out. The four are built
on the builder and packed on the IPS side (`docs/BUILDER.md` "Local packages"): the static executor
and the static `om`, then `HPS::Apk::pack_apk`; `add-local alpine` then `sync alpine` and `verify`
are the same two steps for any further local package.

`verify` and `list` cover Alpine as they do NixOS. `--only starter` is refused (the starter is made
from the repository); `--only repository` is the same as no `--only`.

## Booting a host from the starter

Assign the host the profile `STARTER` and no pin, from a held host:

```
hps-onboard assign <mac> --type TCH --profile STARTER --os x86_64:nixos:26.05
```

Its iPXE script then loads `starter/nixos/26.05/bzImage` and `initrd` with the
stock kernel arguments from the manifest, `console=ttyS0,115200`, and (plan
step 2) the arguments the node bundle needs: a hook that makes the unmodified
starter fetch one script from the IPS, and `hps.ips`, `hps.mac`, `hps.os`,
`hps.profile` and `hps.domain` (`docs/BUNDLE.md`). There is no pin and nothing
of HPS in the image: the node boots to the distribution's login, and from the
IPS it gets the sysadmin user, its packages, the ctrl-exec agent and its
pairing. The boot opens the pairing window as a pinned boot does. Every other
profile maps to a built image and a pin exactly as before. `hps-onboard repin`
refuses a starter host. The starter must have been synced first; without it
the host gets the iPXE error screen and the IPS log says to run `hps-starter
sync nixos`.
