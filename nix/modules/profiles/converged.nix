# profiles/converged.nix - storage (SCH) and compute (TCH) roles on one node.
#
# The roles are recorded in /etc/hps/roles via hps.roles. The storage services
# (LIO, the storage script tools) come from storage.nix (phase 2); the compute
# services (libvirt/QEMU/KVM, OVMF) arrive in phase 3 as their own module.
{ ... }:

{
  imports = [ ../hps-node.nix ./storage.nix ];

  hps.roles = "SCH,TCH";
}
