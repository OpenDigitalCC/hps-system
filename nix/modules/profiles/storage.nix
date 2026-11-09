# profiles/storage.nix - the storage-controller (SCH) role.
#
# ZFS is already on in hps-common.nix (boot.supportedFilesystems, forceImportRoot
# and forceImportAll off). This module adds what the storage scripts call: the
# LIO SCSI target (services.target restores /etc/target/saveconfig.json at boot;
# iscsi-export writes it with targetcli-fb saveconfig), targetcli, mdadm,
# smartmontools, util-linux (lsblk, blkid, wipefs), xxd (raw key conversion) and
# jq/openssl (approval verification) on the scripts' path.
#
# No pool is imported by NixOS: boot.zfs.extraPools stays empty because HPS
# imports the pool with the allowlisted storage-pool-import script (never -f),
# unlocks it with dataset-unlock once the node has paired, and exports zvols
# with iscsi-export. Nothing here holds a pool name, a disk or a key.
{ config, lib, pkgs, ... }:

{
  hps.roles = lib.mkDefault "SCH";

  services.target.enable = true;

  boot.zfs.extraPools = [ ];

  environment.systemPackages = with pkgs; [
    targetcli-fb
    mdadm
    smartmontools
    util-linux
    unixtools.xxd
    jq
    openssl
    config.boot.zfs.package
  ];
}
