# Run once all functions processed

#n_remote_log "$(n_queue_list)"

n_queue_add n_set_hostname_and_hosts
n_queue_add n_configure_motd              # Setup login messages
n_queue_add n_display_info_before_prompt  # Handle console display


# Check if issue file was created
cat /etc/issue

# Check if node_information works
n_node_information


# uncommenting this will disable login
#n_queue_add n_disable_getty_alpine
