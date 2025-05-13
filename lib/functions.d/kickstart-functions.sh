__guard_source || return
# Define your functions below


generate_ks_tch() {
  local macid="$1"

  host_config "$macid" || {
    echo "[✗] Failed to load host config for $macid" >&2
    return 1
  }

  cat <<EOF
#version=RHEL9
install
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=static --ip=${HOST_IP} --netmask=${HOST_NETMASK} --gateway=${HOST_GATEWAY} --nameserver=${HOST_DNS} --hostname=${HOST_NAME} --device=eth0 --activate
rootpw --plaintext changeme
firewall --disabled
authconfig --enableshadow --passalgo=sha512

# iSCSI boot disk
iscsi --target=${ISCSI_TARGET_IP}:3260 --portal=${ISCSI_IQN}
ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

bootloader --location=mbr
reboot

%packages
@^minimal-environment
kvm
qemu-kvm
libvirt
virt-install
virt-manager
openssh-server
%end

%post --log=/root/ks-post.log
echo "Hardening TCH install..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl enable sshd
systemctl disable firewalld NetworkManager
%end
EOF
}



