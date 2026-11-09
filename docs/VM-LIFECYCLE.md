# VM lifecycle node scripts

The scripts the IPS calls (through ctrl-exec, profile `node`) to put a guest on a
compute node, run it and take it away again. One script per action; each logs
every command as `+ <command>` on stderr and prints one result line last on
stdout. Everything runs as root on `$NODE`. Names: `$VM` is
`^[a-z0-9][a-z0-9-]{0,31}$`; `$POOL` is the node's ZFS pool.

Not unit-tested against real libvirt or QEMU: the tests use shimmed `virsh`,
`qemu-img`, `curl` and `sha256sum` (none are on the development host). The
first real run is the lab runsheet.

## Order

For a new guest the IPS calls:

1. `image-fetch` – the base qcow2 into the images dataset of `$POOL` (once per image).
2. `mirror-create` (CS-3.2) – the guest's disk mirror, `/dev/md/<name>`.
3. `vm-image-write` – base image onto the fresh mirror.
4. `vm-define` – the libvirt domain.
5. `vm-start`.

Taking it away: `vm-stop`, then `vm-undefine`. Data (zvols, mirrors, images) is
removed by the IPS's `hps-workload destroy` with an approval, never by these
scripts. `vm-status`, `vm-console-log` and `vm-confinement-report` are read-only
and can run at any time.

## Scripts

| Script | Does | Exit codes |
| --- | --- | --- |
| `image-fetch <name> --from http://<ips>/<path> --sha256 <hex> --dest <dir>` | curl (http only, no redirects) to `<dir>/<name>.qcow2.part`, checks sha256, renames. File present with the right hash: no download. Last line `IMAGE <name> <sha256> <path>` | 0 ok, 2 usage, 3 refused (scheme/host/URL shape, bad name or hash, sha256 mismatch), 1 command failed |
| `vm-define <vm> --memory <MiB> --vcpus <n> --disk <dev> --net <bridge>... --image <qcow2> [--serial-log <path>] [--replace]` | Renders the domain XML (q35, OVMF, raw virtio disk on `<dev>`, virtio NIC per bridge, serial console to a log, no graphics) and `virsh define`s it. Same definition again: no change. A different one: refused unless `--replace` (guest must be shut off). Never reads or copies `--image` (recorded in the metadata only). Last line `VM <vm> defined` | 0, 2, 3 refused (bad argument, different definition, running with `--replace`), 1 |
| `vm-image-write <vm> --disk <dev> --image <qcow2> [--force]` | `qemu-img convert -f qcow2 -O raw` onto the disk, only if its first 512 bytes are zero (or `--force`) and the guest is not running. Logs the image sha256. Last line `IMAGE <vm> <sha256> written` | 0, 2, 3 refused (data in first sector, guest in use, bad argument), 1 |
| `vm-start <vm>` | `virsh start`, waits up to 30 s for running. Running already: no-op. Last line `VM <vm> running` | 0, 2, 3 (paused or other odd state), 4 not defined, 1 not running in time |
| `vm-stop <vm> [--timeout 60] [--force]` | `virsh shutdown`, waits. `virsh destroy` only with `--force` after the timeout. Last line `VM <vm> shut off` | 0, 2, 4 not defined, 1 still running |
| `vm-status [<vm>]` | Read-only: `virsh list --all`, `dominfo`, `domblklist`. Last line per guest `VM <vm> <state>`, or `no VMs` | 0, 2, 4 |
| `vm-undefine <vm>` | `virsh undefine --nvram` of a shut-off guest. Not defined: no-op. Does not touch disks, mirrors or images. Last line `VM <vm> undefined` | 0, 2, 3 (not shut off), 1 |
| `vm-console-log <vm> [--lines 200]` | Read-only tail of `/var/log/libvirt/qemu/<vm>-serial.log` | 0, 2, 4 no log |
| `vm-confinement-report [<vm>]` | Read-only confinement checks; see `CONFINEMENT.md`. Last line `CONFINEMENT model=... qemu_user=... seccomp=... apparmor_kernel=... label=...` | 0, 2 |

## Repeating a call

Every script can be run twice with the same arguments and the second run changes
nothing: `image-fetch`, `vm-define`, `vm-start`, `vm-stop` and `vm-undefine`
succeed with a no-op; `vm-image-write` refuses (3) because the disk is no longer
fresh.

## Assumptions to confirm in the lab

* OVMF firmware: `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` and
  `edk2-i386-vars.fd` (the files the nixpkgs 26.05 libvirtd module links);
  `HPS_OVMF_CODE` and `HPS_OVMF_VARS` override them.
* The guest's QEMU user (`qemu-libvirtd`) can write the serial log under
  `/var/log/libvirt/qemu/` (libvirt's DAC driver relabels it).
* `virsh`, `qemu-img` and `curl` are on the ctrl-exec script path of the node.
