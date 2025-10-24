
# n_queue_add n_enable_console_output 

n_queue_add n_start_modloop

# Get networking running correctly
n_queue_add n_configure_minimal_networking

# Force network to started
n_queue_add n_force_network_started

# get hostnames etc running
n_queue_add n_set_hostname_and_hosts

# Start base services - required for syslog etc
n_queue_add n_start_base_services

# start syslog
n_queue_add n_configure_syslog

# auto_load_network_modules
#n_queue_add n_setup_network_modules_alpine
n_queue_add n_auto_load_network_modules_safe

# configure storage
n_queue_add n_storage_provision


# KVM install
n_queue_add n_install_kvm

# 
#n_queue_add n_force_start_services

# queue package installs
# OpenSVC
n_queue_add n_install_apk_packages_from_ips opensvc-server opensvc-client

n_queue_add n_osvc_start
n_queue_add n_initialise_opensvc_cluster

# set up reboot trap/log
n_queue_add n_configure_reboot_logging

