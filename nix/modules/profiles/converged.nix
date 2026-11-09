# profiles/converged.nix - storage (SCH) and compute (TCH) roles on one node.
#
# The roles are recorded in /etc/hps/roles via hps.roles. The storage services
# (LIO, the storage script tools) come from storage.nix (phase 2); the compute
# services (libvirt/QEMU/KVM, OVMF, open-iscsi, mdadm, guest confinement) come
# from compute.nix (phase 3). The two modules stay separate roles: each can be
# imported alone, and they share nothing but the kernel.
{ ... }:

{
  imports = [ ../hps-node.nix ./storage.nix ./compute.nix ];

  hps.roles = "SCH,TCH";
}
