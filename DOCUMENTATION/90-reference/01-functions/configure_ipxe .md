#### `configure_ipxe `

Contained in `lib/functions.d/configure_ipxe.sh`

Function signature: 8be018f219f7bb96b1582cebaa58986ae6fca49645ba4a4141473836d7e5add6

##### Function overview

The `configure_ipxe` function is for setting up the IPXE boot configuration. It constructs an IPXE script file called 'boot.ipxe' that carries out the following operations after booting:

  - Obtains an IP address via DHCP
  - Normalises the MAC address 
  - Attempts to load configuration specific to the host machine from the server.
  - If it is unable to find the configuration, it opens a menu to the user for manual configuration.
  - The function can handle different host configuration types which include Thin Compute Host, Storage Cluster Host, Disaster Recovery Host, and Container Cluster Host.
  
##### Technical description

  - **Name**: `configure_ipxe`
  
  - **Description**: This function is used to create the IPXE boot configuration script file called 'boot.ipxe'.
  
  - **Globals**: 
    - `HPS_MENU_CONFIG_DIR`: The directory in which the ipxe boot file will be created.
    - `DHCP_IP`: The IP for the DHCP server.
  
  - **Arguments**: None
  
  - **Outputs**: An IPXE script file in the directory specified by `HPS_MENU_CONFIG_DIR`.
  
  - **Returns**: Outputs a success message once the 'boot.ipxe' file has been successfully created and written to.
  
  - **Example usage**: `configure_ipxe`
  
##### Quality and Security Recommendations

1. Always validate any form of user inputs or server responses to protect against SQL injection attacks and XSS attacks.
2. To prevent pathname expansion or word splitting, always quote your variables. Inconsistent quoting can lead to vulnerabilities.
3. Error messages should be written to STDERR instead of STDOUT.
4. It is advisable to perform sanity checks before making a directory to ensure that it does not already exist and that you have sufficient permissions.
5. Set stricter permissions to the created ipxe boot configuration file to prevent unauthorised access or modifications.
6. It may be prudent to clean up or limit the logged information to prevent the disclosure of sensitive information.

