### `build_dhcp_addresses_file`

Contained in `lib/functions.d/dns-dhcp-functions.sh`

Function signature: 1e8517f7be98ca6ca266e569111938c53137ee61efbb1a3efc44cb18aa3f3d52

### Function overview

The Bash function `build_dhcp_addresses_file` is utilized to generate a DHCP addresses file which includes the Mac, IP, and hostname of each host in a cluster. If the services directory does not already exist, it is created. The function fetches a list of all hosts vis `list_cluster_hosts`, and validates the IP address and hostname for each host before appending it to the DHCP addresses file.

### Technical description

- **Name:** build_dhcp_addresses_file
- **Description:** This function produces a DHCP addresses file which lists the Mac, IP, and hostname for each of the hosts in the cluster. If the directory does not exist, the function will create one.
- **Globals:** 
  - HPS_CLUSTER_CONFIG_DIR: The configuration directory for the cluster.
- **Arguments:** None
- **Outputs:** A file, dhcp_addresses, is created. If the directory does not exist, the function creates it. For every host in the cluster, the function adds entries into the file. The entry includes the formatted MAC address, IP, and hostname of the host.
- **Returns:** Returns 0 on executing successfully. Returns 1 in case of any error.
- **Example usage:** 

 To use this function, it should be called from the script in following manner: 
 ```bash
 build_dhcp_addresses_file
 ```
### Quality and security recommendations

1. Ensure that the HPS_CLUSTER_CONFIG_DIR is set with the correct permissions, allowing only necessary privileges.
2. Ensure that the list of hosts being processed is reliable, avoiding the risk of processing malicious or compromised hosts.
3. Validate the HOSTNAME and IP that is fetched, to avoid possible injection attacks.
4. Avoid logging sensitive data in error messages or logs which can be read by users with lower privileges.
5. Consider using a temporary directory when creating temporary files to avoid potential security issues.
6. Cleaning up or securely erasing the temporary file after moving its content to destination file.

