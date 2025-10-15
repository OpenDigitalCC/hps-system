### `get_interface_network_info`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 4e173360adff11eb87d4f357c81a5a4827f74ea723adff69c69fd4d1c4dcae15

### Function overview
The `get_interface_network_info` function is designed to gather network interface information on a Linux system. The function accepts a network interface as an argument and retrieves several essential parameters such as interface's IP Address, CIDR notation, IP/CIDR combination, network address. It then outputs this information in a formatted string. The function uses external utility `ipcalc` to calculate network subnet from the IP/CIDR combination. If the network interface does not have an IPv4 address or the `ipcalc` tool is not installed or the network subnet couldn't be calculated, the function logs an error message via `hps_log` function and returns `1`.

### Technical description
- **Name:** `get_interface_network_info`
- **Description:** This function retrieves important networking information related to a specified network interface and outputs it in the following format: `interface|ipaddress|cidr|ip_cidr|network`
- **Globals:** None
- **Arguments:** 
  - `$1`: Name of a network interface
- **Outputs:** A string formatted as `interface|ipaddress|cidr|ip_cidr|network`
- **Returns:** `0` on successful execution; `1` when the network interface does not have an IPv4 address, `ipcalc` utility is not installed, or calculation of network subnet fails.
- **Example usage:** `get_interface_network_info eth0` 
This will output the eth0 interface details in the specified format if successful or log an error message and return `1` if unsuccessful.

### Quality and Security Recommendations
1. Error Handling: Continue to use explicit error messages to ensure that failures due to misconfigurations, missing dependencies, or out-of-resource conditions are understood and addressed promptly.
2. Dependence on External Utilities: Currently, this function depends on `ipcalc` utility. If it's absent, the function fails. To improve this, consider including a fallback mechanism when `ipcalc` is not available or implement its functionality within the script avoiding the dependency altogether.
3. Validation of Input: Add robust validation for the input parameter. Ensure the network interface exists on the system before proceeding with the function.
4. Code Comments: Maintain good commenting practice throughout the code for better readability and maintainability. Comments should explain why something is done, not what is done.
5. Return Codes: Stick to conventional meanings to Unix return codes. These are useful for chaining commands or for using in scripts. For complex failures, consider providing more detailed status information via a different mechanism (e.g., logging or a status file).
6. Security: Sanitize all inputs to prevent command injection vulnerabilities when the input is being used to construct shell command.

