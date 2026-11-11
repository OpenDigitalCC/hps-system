# hps-firmware-layer.nix - linux-firmware as a netboot initrd layer of its own.
#
# The audit image needs the whole linux-firmware set (owner ruling: full
# firmware in the audit image only), ~825 MiB. Inside the image's store
# squashfs it was recompressed and repacked on every image build. This layer
# carries it once instead: an uncompressed cpio holding one file,
# /firmware.squashfs, whose root is the firmware tree NixOS would install for
# hardware.firmware = [ linux-firmware ] (each file zstd-compressed, as
# hardware.firmwareCompression = "zstd" does on every kernel >= 5.19).
#
# iPXE loads it as a second initrd after the image's own; the kernel unpacks
# both into the initramfs, and the audit image mounts /firmware.squashfs at
# /run/hps-firmware before udev starts (nix/modules/hps-audit.nix).
#
# The store path depends on linux-firmware and the few tools below only, never
# on the audit configuration: it changes with the firmware (or a nixpkgs bump
# of these tools), and nix/build.sh publishes it once per store path under
# <resources>/nixos/firmware/, shared by every pin.
{ runCommand, squashfsTools, cpio, compressFirmwareZstd, linux-firmware }:

let
  firmware = compressFirmwareZstd linux-firmware;
in
runCommand "hps-firmware-layer-${linux-firmware.version}"
  {
    nativeBuildInputs = [ squashfsTools cpio ];
    __structuredAttrs = true;
    # The layer is self-contained: nothing in it refers back to the store.
    unsafeDiscardReferences.out = true;
    passthru = { inherit firmware; };
  }
  ''
    src=${firmware}/lib/firmware
    # An absolute symlink would point into a store the node does not have
    # (the firmware is no longer in the image's store); NixOS's own firmware
    # tree only has relative ones. Refuse rather than ship dangling links.
    find "$src" -type l -lname '/*' > abs-links
    if [ -s abs-links ]; then
      echo "hps-firmware-layer: absolute symlinks in $src (would dangle on the node):" >&2
      head -n 20 abs-links >&2
      exit 1
    fi

    mkdir -p work "$out"
    # zstd level 6 as the image stores (netboot.squashfsCompression in
    # hps-common.nix); blocks that do not shrink (most firmware is already
    # zstd-compressed) are stored as they are. Flags as nixpkgs make-squashfs:
    # reproducible (SOURCE_DATE_EPOCH=0, -no-hardlinks, -all-root).
    SOURCE_DATE_EPOCH=0 mksquashfs "$src" work/firmware.squashfs \
      -no-hardlinks -all-root -no-xattrs -b 1048576 \
      -comp zstd -Xcompression-level 6 \
      -processors "$NIX_BUILD_CORES" -root-mode 0755
    chmod 0444 work/firmware.squashfs
    touch -h -d @1 work/firmware.squashfs

    # One entry, no directories: concatenated after the image's initrd it adds
    # /firmware.squashfs and changes nothing else in the initramfs.
    (cd work && printf 'firmware.squashfs\0' \
      | cpio --quiet -o -H newc -R +0:+0 --reproducible --null > "$out/firmware.cpio")
    test -s "$out/firmware.cpio"
  ''
