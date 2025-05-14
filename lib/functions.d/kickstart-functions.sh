__guard_source || return
# Define your functions below

generate_ks() {
  local macid="$1"
  local type="$2"

  host_config "$macid" || {
    echo "[✗] Failed to load host config for $macid" >&2
    return 1
  }
hps_log info "[$macid]" "Requesting kickstart for $type"

ks_common
ks_host_${type}

}

ks_type_TCH () {
# TCH Thin Compute Host
cat <<EOF

# iSCSI boot disk
iscsi --target=${ISCSI_TARGET_IP}:3260 --portal=${ISCSI_IQN}
ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

%packages
@^minimal-environment
kvm
qemu-kvm
libvirt
virt-install
virt-manager
openssh-server
%end

EOF
}

ks_type_SCH () {
# SCH Storage Cluster Host
cat <<EOF

ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

%packages
@^minimal-environment
openssh-server
%end

EOF
}


ks_type_DRH () {
# DRH Disaster Recovery Host
cat <<EOF

ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

%packages
@^minimal-environment
openssh-server
%end

EOF
}

ks_type_CCH () {
# CCH Container Cluster Host
cat <<EOF

ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

%packages
@^minimal-environment
openssh-server
%end

EOF
}


ks_common () {

#TODO: extract the networking data from the host configuration

HOST_IP=$(host_config "$macid" get IP)
HOST_NETMASK=$(host_config "$macid" get NETMASK)
HOST_NAME=$(host_config "$macid" get HOSTNAME)
HOST_GATEWAY="${DHCP_IP}"
HOST_DNS=${DHCP_IP}
host_config "$macid" set STATE "INSTALLING"

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

bootloader --location=mbr
reboot

%post --log=/root/ks-post.log
echo "Hardening TCH install..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl enable sshd
systemctl disable firewalld NetworkManager
curl -X POST http://${${DHCP_IP}/cgi-bin/boot_manager.sh?mac=$macid&cmd=mark_installed
%end

EOF

}





