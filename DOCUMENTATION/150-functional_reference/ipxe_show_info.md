### `ipxe_show_info`

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: cbd14427c29a67a77d52cb0fd250b99f45cb94110f4d4b0a3f1123ec4fe219a4

### Function overview

The `ipxe_show_info()` function is mainly used to display different configurations of a particular host. This function pulls up information such as the host's IP, hostname, platform, UUID, serial number, product, cluster configuration, and HPS (High Performance Storage) paths. 

The function achieves this by taking a single argument, which determines the category of information that will be displayed for the host. The categories include `show_ipxe`, `show_cluster`, `show_host`, and `show_paths`. 

### Technical description

- **Name**: `ipxe_show_info()`
- **Description**: This function displays specific information about a host, based on what category is passed as an argument.
- **Globals**: 
  - `HPS_CLUSTER_CONFIG_DIR`: The directory where the cluster configuration is stored
  - `CGI_URL`: Link to CGI (Common Gateway Interface) script which is used to implement the command `process_menu_item`
  - `HPS_CONFIG`: The file where the HPS (High Performance Storage) configuration is stored
- **Arguments**: 
  - `$1: category`: The type of information to display about the host. The options are `show_ipxe`, `show_cluster`, `show_host`, and `show_paths`.
- **Outputs**: Information about the host in the requested category, such as IP address, hostname, platform, UUID, serial and product numbers, and more.
- **Returns**: Does not return a value.
- **Example usage**: `ipxe_show_info show_ipxe`

### Quality and security recommendations

1. Always ensure variable sanitization before using any variable in command substitution. This removes potential harmful commands being hidden as a value for a variable.
2. Always quote the variables. This will prevent word splitting and pathname expansion.
3. Implement error handling for when file reading or command chain replacement fails, or when an unknown item category is passed as an argument.
4. Implement checking for edge cases where the category argument is not passed at all.
5. The `ipxe_show_info` function is essentially storing, processing, and displaying sensitive information about a host. It is recommended to add necessary security measures to protect this sensitive data from potential breaches.
6. Use `printf` instead of `echo` for better string handling, especially while displaying file contents.
7. Consider using local variables. This can help in preventing variable clashing and accidental modification of environment variables which can have impact on how the system functions.

