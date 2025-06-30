__guard_source || return
# Define your functions below

generate_ks() {
  local macid="$1"
  local type="$2"
  CLNAME=$(cluster_config get CLUSTER_NAME)
  hps_log info "[$macid]" "Requesting kickstart for $macid $type"

#  host_config "$macid" || {
#    hps_log debug "[x] Failed to load host config for $macid"
#    return 1
#  }

hps_log info "${FUNCNAME[1]}"

  cgi_header_plain
  ks_common
#  ks_type_${type}

}

ks_common () {

hps_log debug "called from ${FUNCNAME[1]}"

#TODO: extract the networking data from the host configuration

HOST_IP=$(host_config "$macid" get IP)
HOST_NETMASK=$(host_config "$macid" get NETMASK)
HOST_NAME=$(host_config "$macid" get HOSTNAME)
HOST_GATEWAY="$(cluster_config get DHCP_IP)"
HOST_DNS="$(cluster_config get DHCP_IP)"

host_config "$macid" set STATE "INSTALLING"

ks_file_base
ks_file_prepdisk
ks_file_options
ks_file_pre
ks_file_packages
ks_file_post

}


ks_file_base () {

cat <<EOF

# Function: ${FUNCNAME[0]}

#install

# Locale
lang en_GB.UTF-8
keyboard uk
timezone UTC --utc

# Network
network --bootproto=static --ip=${HOST_IP} --netmask=${HOST_NETMASK} --gateway=${HOST_GATEWAY} --nameserver=${HOST_DNS} --hostname=${HOST_NAME} --activate
firewall --disabled

# Authentication
rootpw --plaintext changeme
#authconfig --enableshadow --passalgo=sha512

# Hardening
selinux --enforcing
#services --enabled=sshd

EOF
}


ks_file_options () {
cat <<EOF
# Function: ${FUNCNAME[0]}
reboot
EOF
}


ks_file_prepdisk () {
cat <<EOF
# Function: ${FUNCNAME[0]}
# Disk / boot

zerombr
clearpart --all --initlabel
autopart --nohome --nolvm
bootloader --location=mbr

# If you prefer manual partitioning, uncomment below and comment 'autopart' above:
# clearpart --all --initlabel
# part biosboot --fstype=biosboot --size=1
# part /boot --fstype=xfs --size=512
# part swap --size=2048
# part / --fstype=xfs --grow --size=1024
#part / --fstype=ext4 --size=10240

EOF
}

ks_file_pre () {
true
cat <<EOF
# Function: ${FUNCNAME[0]}
%pre --interpreter /bin/bash
DISK=\$(lsblk -ndo NAME,TYPE | awk '\$2=="disk" {print "/dev/"\$1; exit}')
if lsblk -n "\${DISK}" | awk '\$6=="part"' | grep -q .; then
    echo "ERROR: Disk \${DISK} has existing partitions." > /dev/ttyS0
    echo "Aborting installation." > /dev/ttyS0
    exit 1
fi
echo "Disk check..." > /dev/console
echo "\${DISK}" > /dev/ttyS0
sleep 60
%end

EOF
}

ks_file_packages () {
true
cat <<EOF
# Function: ${FUNCNAME[0]}
%packages
@^minimal-environment
@core
openssh-server
%end
EOF
}

ks_file_post () {
true
cat <<EOF

# Function: ${FUNCNAME[0]}

%post --log=/root/ks-post.log --nochroot
echo "Hardening install..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
passwd -l root
systemctl enable sshd
#systemctl disable firewalld NetworkManager
#systemctl mask firewalld NetworkManager
nmcli connection modify "Wired connection 1" connection.autoconnect yes
curl -X POST "http://${HOST_GATEWAY}/cgi-bin/boot_manager.sh?mac=$macid&cmd=set_status&status=INSTALLED"
%end

EOF
}

ks_type_TCH () {
# TCH Thin Compute Host
cat <<EOF

# Function: ${FUNCNAME[0]}

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

ks_type_DRH () {
# DRH Disaster Recovery Host
cat <<EOF

# Function: ${FUNCNAME[0]}

# ignoredisk --only-use=sda
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

# Function: ${FUNCNAME[0]}

#ignoredisk --only-use=sda
clearpart --all --initlabel
part / --fstype=ext4 --size=10240

%packages
@^minimal-environment
openssh-server
%end

EOF
}






