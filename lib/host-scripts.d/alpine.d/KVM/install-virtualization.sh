install_virtualization() {
  echo "[HPS] Installing virtualization packages..."
  apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    libvirt \
    libvirt-daemon
  
  rc-update add libvirtd default
  rc-service libvirtd start
}


