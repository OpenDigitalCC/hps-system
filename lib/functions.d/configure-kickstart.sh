# Define your functions below

configure_kickstart () {

if [[ -z "$1" ]]; then
    echo "[ERROR] Cluster name is required."
    exit 1
fi

CLUSTER_NAME="$1"
KICKSTART_PATH="/srv/hps-config/kickstarts/${CLUSTER_NAME}.ks"

echo "[*] Generating Kickstart file for cluster: $CLUSTER_NAME"

cat > "$KICKSTART_PATH" <<EOF
# Use text mode install
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Network configuration (DHCP)
network --bootproto=dhcp --device=eth0 --onboot=on --activate

# Root password (change this in production)
#rootpw --plaintext changeme
#Root password
rootpw --lock
user --groups=wheel --name=sysadmin --password=password-hash --iscrypted --gecos="sysadmin"

# Use entire disk
clearpart --all --initlabel
autopart --type=plain --fstype=xfs

# Alternatively use manual partitioning (comment above, uncomment below)
# part /boot --fstype=xfs --size=1024
# part swap --size=2048
# part / --fstype=xfs --grow --size=8192

bootloader --location=mbr

# Don't ask for confirmation
reboot
firewall --enabled --service=ssh
authselect --useshadow --enablefingerprint
selinux --enforcing
firstboot --disable
skipx

# Package Selection
%packages
@core
@virtualization
kmod-kvm
qemu-kvm
libvirt
virt-install
virt-manager
zfs
sanoid
targetcli
iscsi-initiator-utils
htop
iotop
sysstat
nmon
vim
screen
%end

# Post-install script
%post --log=/root/ks-post.log

# Enable and start required services
systemctl enable libvirtd
systemctl enable target
systemctl enable sanoid

# Setup sanoid example config
mkdir -p /etc/sanoid
cat > /etc/sanoid/sanoid.conf <<EOF2
[backup]
        use_template = default
        datasets = auto
[template_default]
        daily = 7
        monthly = 3
        hourly = 24
        autosnap = yes
        autoprune = yes
EOF2

# Enable performance tools
sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
systemctl enable sysstat

%end
EOF

echo "[OK] Kickstart file generated at $KICKSTART_PATH"

}
