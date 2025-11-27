### `n_node_information`

Contained in `lib/node-functions.d/common.d/common.sh`

Function signature: 74929d3d0eddb047d5e64379e90dffc1956cc56b3f72b1d2b31d9b0358c73d56

### Function overview

The `n_node_information()` function in Bash is designed to scan a server system's information and display the vital elements in a clean, formatted manner. This includes aspects such as host configuration, IP, Gateway, Domain, Mac address, Uptime, operational services, state of the console, virtualization status and if the system has been recently updated. The function performs error checking on loading the host configuration and if the function fails, it notifies the user with an error message.

### Technical description

- **Name**: `n_node_information`
- **Description**: This function retrieves specific details of a Linux host, formats and visualizes them in a clear and concise manner for the user. It loads the host configuration, collects a series of system and network data, checks the console status, counts active services, clears the screen if running interactively and displays the collected information. The function monitors console status and displays appropriate footers.
- **Globals**: `HOSTNAME`, `TYPE`, `HOST_PROFILE`, `STATE`, `IP`, `NETMASK`, `provisioning_node`, `mac_address`, `dns_domain`, `uptime_display`, `active_count`, `virtualization_status`, `virtualization_type`, `console_status`, `UPDATED`.
- **Arguments**: There are no explicit arguments used in this function.
- **Outputs**: Displays a system's information in the console, formatted in an organized format.
- **Returns**: If it fails to load the host configuration, it returns 1. If all lines of codes are executed correctly, it returns 0.
- **Example usage**: To use this function, simply call it in your script as `n_node_information`

### Quality and Security Recommendations

1. As the function involves displaying sensitive system information, it should adequately handle access permissions and restrict unauthorized access.
2. Check inputs for all externally supplied data to ensure data is as expected and guard against command injection attacks.
3. To enhance readability and maintainability, consider adding more comments to complex code blocks.
4. To ensure quality, consider writing unit tests to cover every possible case.
5. Consider having error checking for each local variable where a remote command is used to fetch system information.
6. Encapsulate echo statements formatting the output within a separate function for maintainability and reuse.

