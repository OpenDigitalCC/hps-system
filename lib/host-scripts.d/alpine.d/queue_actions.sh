

# queue package installs

# Get networking running correctly
n_queue_add n_configure_minimal_networking
# Force network to started
n_queue_add n_force_network_started

# set up reboot trap/log
n_queue_add n_configure_reboot_logging

# KVM install
n_queue_add n_install_kvm

# 
n_queue_add n_force_start_services

# OpenSVC
n_queue_add n_install_apk_packages_from_ips opensvc-server opensvc-client

