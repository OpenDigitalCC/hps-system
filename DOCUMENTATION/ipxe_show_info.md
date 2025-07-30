## `ipxe_show_info`

Contained in `lib/functions.d/ipxe-menu-functions.sh`

### Function overview
The `ipxe_show_info` function is designed for displaying various pieces of information about the host system, its configuration and the iPXE boot environment. The function uses a switch-case structure to organise the printing of information into distinct sections such as iPXE info, cluster configuration, host configuration and system paths. All of this information can be valuable for system troubleshooting and administration purposes.

### Technical description
- Name: `ipxe_show_info`
- Description: This function is used to display information about the iPXE environment, the host and the cluster. The information to be displayed is determined by the `category` argument passed to the function.
- Globals: [HPS_CLUSTER_CONFIG_DIR: The directory where the cluster configuration is stored, HPS_CONFIG: The location of the HPS configuration file]
- Arguments: [$1: The category of information to be displayed. Can be one of the following: `show_ipxe`, `show_cluster`, `show_host`, or `show_paths`]
- Outputs: Outputs information in the terminal about the host, iPXE environment, cluster and system paths, based on the chosen category.
- Returns: Does not return a value.
- Example usage: `ipxe_show_info show_cluster`

### Quality and security recommendations
- Consider adding input validation for the `category` argument to ensure that only valid categories are processed.
- When displaying file content, make sure to handle any potential errors (file not found, permission denied, etc.) in a way that maintains the function's stability and security. 
- Avoid disclosing sensitive info (passwords, API keys etc.) within the displayed information. You should regularly review the displayed info to ensure no confidential data is unintentionally exposed.
- The function makes use of several global variables. To improve encapsulation, consider altering the function to accept these values as arguments instead.

