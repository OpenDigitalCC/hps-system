# profiles/converged.nix - storage (SCH) and compute (TCH) roles on one node.
#
# Phase 1 records the roles only (/etc/hps/roles via hps.roles). The storage
# services (ZFS pool import, LIO) arrive in phase 2 and the compute services
# (libvirt/QEMU/KVM, OVMF) in phase 3; each lands here as its own module.
{ ... }:

{
  imports = [ ../hps-node.nix ];

  hps.roles = "SCH,TCH";
}
