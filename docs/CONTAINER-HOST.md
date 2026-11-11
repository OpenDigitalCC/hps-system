# Container host (CNH)

A container host is an HPS node whose job is to run containers: podman, om3
membership and the HPS node base, nothing of the storage or compute roles. One
NixOS profile serves metal and guests alike (CS-3.11,
`plans/cs311-container-host.md`). Its first use is to run a cluster's own IPS:
the `hps-container` image on a CNH guest, which is how each cluster of the
scale test gets its IPS (`plans/scale-test.md`, "s<n>-ips (CNH VM)").

Not evaluated or run here: nix is not installed on the development host, so
the profile has not been through `nix flake check`, and the node scripts are
tested against shimmed `blkid`, `mkfs.ext4`, `mount`, `findmnt`, `podman`,
`systemctl`, `systemd-run`, `ip`, `iptables`, `curl` and `sha256sum`. The
first real run is the lab.

## Role, profile and image

| What | Value |
| --- | --- |
| registry role (`TYPE`) | `CNH` (`hps-onboard assign --type CNH`) |
| host profile (`HOST_PROFILE`) | `CONTAINER_HOST` |
| image profile (pin directory) | `node-cnh` (`nixos_image_profile CONTAINER_HOST`) |
| NixOS module | `nix/modules/profiles/container-host.nix` (`hps.roles = "CNH"`) |
| built by | `nix/build.sh` (default profile list) and the flake package `node-cnh` |

The image carries:

- the HPS node base: the ctrl-exec agent and pairing, `hps-node-init`, the
  resource monitor, `hps-net` (DHCP on the boot NIC only), log forwarding to
  the IPS, time from the IPS, the power-off unit;
- om3 (`hps-opensvc.nix`, unchanged), started once the IPS delivers the
  cluster secret;
- podman as root (rootless is a later step), network backend netavark, overlay
  storage in `/var/lib/containers`, no docker socket or alias;
- the units `hps-cnh-mount` and `hps-ips` (below) and the CNH node scripts.

It leaves out libvirt and QEMU, the LIO target and the pool tools, and no ZFS
pool is created or imported. ZFS userland and the module still come with the
common base of every image.

The CNH node scripts are allowlisted in `container-host.nix` itself
(`services.ctrl-exec-agent.scripts` merges with `hps-ctrl-exec.nix`), so they
exist only on the CNH image, under profile `node` like every node script.

## The CNH disk

The root is RAM. Container images and the IPS state persist only on the CNH
disk:

| Mount point | What |
| --- | --- |
| `/var/lib/containers` | the disk itself (ext4, label `hps-cnh`): podman storage, the image archives (`hps-cnh-images/`) |
| `/var/lib/hps-ips` | bind mount of `<disk>/hps-ips` (mode 0700): the IPS state |

`cnh-disk-prepare <device>` makes the filesystem once: only on a device with no
signature at all (`blkid -p`: no filesystem, RAID member, ZFS label or
partition table). A device already carrying ext4 labelled `hps-cnh` is only
mounted. Any other signature is refused. After a reboot `hps-cnh-mount.service`
finds the disk by its label and mounts it; it never formats, and two disks with
the label mount nothing.

## Node scripts

Every script logs each command as `+ <command>` on stderr and prints one result
line last. Exit codes: 0 ok, 2 usage, 3 refused (nothing changed), 1 a command
failed.

| Script | Does | Last line |
| --- | --- | --- |
| `cnh-disk-prepare <device>` | `/dev/vd<x>`, `/dev/sd<x>`, `/dev/md/<name>` or `/dev/disk/by-id/<id>`; ext4 `hps-cnh` on a blank device, then both mounts; idempotent | `CNH-DISK <device> formatted=<yes\|no> containers=<dir> ips=<dir>` |
| `cnh-image-load <url> <sha256>` | fetch an OCI or docker archive over plain http from this node's IPS only (the URL host must be `hps.ips` of the kernel command line, no redirect), verify, keep it as `hps-cnh-images/<sha256>.tar`, `podman load` | `IMAGE <name> <sha256>` |
| `cnh-ips-bootstrap <base> <manifest-sha256>` | fill `/var/lib/hps-ips` from the IPS by manifest (below); every file verified, resumable | `BOOTSTRAP <sha256> files=<n> fetched=<n> present=<n> replaced=<n>` |
| `cnh-ips-cluster-bootstrap <image> <options...>` | run `scripts/cluster-bootstrap.sh` once in the image (entrypoint replaced, the IPS mounts): the inner cluster's registry, keys and CA are made on the CNH | `CLUSTER-BOOTSTRAP done image=<image>` |
| `cnh-ips-run <image> <interface> [<address>/<prefix>]` | write `/var/lib/hps-ips/ips.env` and restart `hps-ips.service` | `IPS running image=<image> iface=<interface> address=<cidr>` |
| `cnh-ips-stop` | stop `hps-ips.service`; rename `ips.env` to `ips.env.stopped` so it stays off after a reboot | `IPS stopped` |
| `cnh-ips-operator-init <address>:7445 <label>` | in the running `hps-ips` container: set `operator_api_listen` to `<address>` (one of the CNH's own, the container shares its network), bring the operator API up on it (`ce_api_bring_up`, then `supervisorctl restart ctrl-exec-api`) and issue the first operator credential `<label>` (`hps-operator issue`), printed on stdout. Allowlisted `output=confidential`: run it synchronously; ctrl-exec never stores its output. A label that already holds a credential is refused; revoke it first (`hps-operator revoke <label>`) | `OPERATOR-INIT done label=<label> url=https://<address>:7445` |

Every podman call from a node script goes through `systemd-run --wait --pipe`,
as a transient unit of the system manager: podman then has root's full
capabilities instead of the executor profile's list (image layers carry device
nodes and file capabilities, and a container run needs more than the profile
grants).

## A cluster IPS on a CNH

`hps-ips.service` is static in the image and starts only when
`/var/lib/hps-ips/ips.env` exists (`ConditionPathExists`), after
`hps-cnh-mount`. A unit generated at run time would vanish with the RAM root
on the next boot; the settings on the disk do not. `Restart=always`. Its
launcher, `/etc/hps/hps-ips-launch`, reads `ips.env` (`IMAGE`, `IFACE`,
`ADDRESS`; parsed, never sourced, each value checked again) and:

1. brings the interface up and puts the IPS address on it (`ip addr replace`;
   `hps-net` leaves every non-boot link unmanaged, so networkd keeps off it);
2. inserts `-i <interface> -j nixos-fw-accept` at the top of the NixOS firewall
   chain `nixos-fw`: the IPS owns that network (DHCP, TFTP and its data ports,
   DNS, HTTP, syslog, chrony, ctrl-exec pairing). The boot NIC keeps the CNH's
   own firewall, so the IPS services, which listen on every address under host
   networking, are reachable on the provisioning interface only. `ExecStopPost`
   removes the rule;
3. runs, in the foreground, the shape of the lab IPS (`lab/ips/compose.yml`)
   with host networking:

```
podman run --name hps-ips --replace --rm \
  --privileged --cgroupns=host --network=host --hostname=ips \
  --log-driver=journald --log-opt=tag=hps-ips --stop-timeout=30 \
  --volume /var/lib/hps-ips/srv:/srv \
  --volume /var/lib/hps-ips/hps-system:/srv/hps-system \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  <image>
```

The container's own output goes to the CNH journal and so, with the node's
log, to the IPS that provisions the CNH. The inner IPS's services log to its
own rsyslog under `srv/hps-log`, as on any IPS.

`cnh-ips-run` refuses the CNH's boot NIC (the interface carrying `hps.mac=`):
that network belongs to the IPS that provisions the CNH. A VLAN sub-interface
of the boot NIC is allowed. Without an address it keeps the interface's
current IPv4 address. The interface name is also the inner cluster's
`network_dhcp_iface` (`cnh-ips-cluster-bootstrap --dhcp-iface`).

### Layout of /var/lib/hps-ips

```
ips.env                      written by cnh-ips-run (ips.env.stopped after cnh-ips-stop)
hps-system.tar.gz            from the manifest
hps-system/                  unpacked from it (.hps-cnh-tarball-sha256 marks which)
hps-system.prev/             the tree before the last unpack
srv/                         mounted at /srv in the container
  hps-config/ hps-log/ ctrl-exec/{conf,state}/
  hps-resources/{nixos,packages/ctrl-exec,nix-cache,distros,images}/
bootstrap/manifest-<sha256>.json, bootstrap/applied
```

## The bootstrap manifest

`bin/hps-cnh-publish` (an IPS tool, Perl, `HPS::CnhPublish`) runs on the IPS
that provisions the CNH and writes into `<resources>/packages/cnh/`, which
lighttpd already serves as `/packages/cnh/`:

| File | What |
| --- | --- |
| `hps-system-<sha16>.tar.gz` | the hps-system tree (default `/srv/hps-system`), reproducible: sorted, mtime 0, owner 0, `gzip -n`; `.git`, `tmp/` and `log/` left out |
| `manifest-<sha256>.json` | the manifest, named by its own sha256 |
| `latest` | the sha256 of the newest manifest |

```
hps-cnh-publish --pin PIN [--pin PIN ...] [--package packages/REL ...]
                [--resources DIR] [--system DIR]
```

Each pin is verified with `HPS::Pins` first (a pin that does not verify, or one
holding a symlink, is refused) and every regular file under `nixos/<pin>/` is
listed. `--package` defaults to `packages/ctrl-exec/ctrl-exec-latest.tar.gz`,
the tarball the IPS installs its dispatcher from. Last line:
`MANIFEST <sha256> <url path> files=<n>`.

Schema `hps-cnh-manifest/1` (canonical JSON):

```json
{
  "schema": "hps-cnh-manifest/1",
  "created_at": "2026-11-11T12:00:00Z",
  "source": {"hps_system_commit": "<40 hex or unknown>", "pins": ["<pin>"]},
  "files": [
    {"path": "hps-system.tar.gz", "url": "packages/cnh/hps-system-<sha16>.tar.gz",
     "sha256": "<64 hex>", "size": 1234},
    {"path": "srv/hps-resources/nixos/<pin>/node-base/bzImage",
     "url": "nixos/<pin>/node-base/bzImage", "sha256": "<64 hex>", "size": 1234},
    {"path": "srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz",
     "url": "packages/ctrl-exec/ctrl-exec-latest.tar.gz", "sha256": "<64 hex>", "size": 1234}
  ]
}
```

`path`
:   where the file goes under `/var/lib/hps-ips`: `hps-system.tar.gz` or a path
    under `srv/hps-resources/nixos/` or `srv/hps-resources/packages/`, no `.`,
    `..` or empty component. Nothing else (no `hps-config`, no keys).

`url`
:   its path under the IPS base URL; a plain relative path.

`cnh-ips-bootstrap http://<ips> <sha256>` fetches
`<base>/packages/cnh/manifest-<sha256>.json`, checks it against the given hash
and checks every entry before the first download (a bad path, url, hash, size,
a duplicate or a missing `hps-system.tar.gz` refuses the whole manifest). Then
per file: present with the right hash, skipped; present with another hash,
replaced and the replacement logged with both hashes; fetched to `<path>.part`
(resumed with a range request), renamed only once its sha256 matches. A
mismatch removes the `.part`; a transfer error keeps it for the next run. Any
failure exits 1 after the rest were tried, and nothing is unpacked until every
file verifies. The tarball is unpacked when its hash differs from the one last
unpacked; the previous tree stays as `hps-system.prev` (a running IPS uses its
old tree until it is restarted). Last, the `srv/` skeleton of
`lab/ips/setup.sh` is created.

## Bringing up a cluster IPS on a CNH

With `$CNH` the CNH's MAC or host name on the outer IPS, `$IPS` the outer IPS
address, `$PIN` a pin built with `node-cnh`:

1. On the outer IPS: the IPS image archive in `hps-resources/packages/cnh/`
   (`podman save` / `docker save` of the hps-container image) and its sha256;
   `hps-cnh-publish --pin $PIN` prints the manifest sha256.
2. The CNH boots from the outer IPS, is held, and is assigned:
   `hps-onboard assign $CNH --type CNH --profile CONTAINER_HOST --os x86_64:nixos:26.05 --pin $PIN`.
   It reboots into `node-cnh` and pairs.
3. `cnh-disk-prepare /dev/disk/by-id/<id>` (or `/dev/vd<x>`).
4. `cnh-ips-bootstrap http://$IPS <manifest sha256>`.
5. `cnh-image-load http://$IPS/packages/cnh/<archive> <sha256>`.
6. `cnh-ips-cluster-bootstrap <image> --name <cluster> --dhcp-iface <interface> --network <cidr> --ips-ip <address> --dhcp-range <a>-<b> --dns-domain <domain> [--network-add ...]`.
7. `cnh-ips-run <image> <interface> <address>/<prefix>`.
8. `cnh-ips-operator-init <address>:7445 <operator>` (synchronously): the
   operator's credential file is the run's output; save it mode 0600 for
   `hps-op --cred` (`docs/OPERATOR.md`). Every later step goes through that
   cluster's own operator API.

From then on the inner IPS is its own cluster's; the outer HPS keeps only its
CNH node (power, the node scripts above).

## Hazards

- Host networking: the IPS container and the CNH share ports. The CNH has the
  ctrl-exec agent (7443) and om3 (1215, 10000); the IPS has the dispatcher
  pairing port (7444), the API (7445, local) and, if the image ever carries
  `om`, an om3 daemon on 1215 and 10000, which would clash with the CNH's own.
  The hps-container image carries no `om` today.
- The firewall step expects the iptables backend of the NixOS firewall (the
  `nixos-fw` chain). With `networking.nftables` on, it finds no chain, logs it
  and adds no rule, and the IPS services stay closed on the provisioning
  interface.
