## `generate_dhcp_range_simple`

Contained in `lib/functions.d/network-functions.sh`

### Function overview
The `generate_dhcp_range_simple` function is a Bash script designed to generate a range of IP addresses within a specified network, usually for DHCP (Dynamic Host Configuration Protocol) use. The function utilises the `ipcalc` utility to extract the network and broadcast range of the specified network.

### Technical description
**Function**: `generate_dhcp_range_simple()`

- **Name**: generate_dhcp_range_simple
- **Description**: This function is used to generate a range of IP addresses in a certain network. It does so by using a network CIDR block and gateway IP as inputs, as well as an optional count for the range.
- **Globals**: None
- **Arguments**: 
  - `$1`: network_cidr - A network CIDR block (e.g. 192.168.50.0/24)
  - `$2`: gateway_ip - An IP address for the network's gateway (e.g. 192.168.50.1)
  - `$3`: count - Optional argument. Specifies the number of IP addresses to include in the range. If not specified, a default value of 20 is used.
- **Outputs**: The function generates a list of IP addresses, which can be used as a DHCP range.
- **Returns**: The function echoes the range of IP addresses.
- **Example usage**: `generate_dhcp_range_simple "192.168.50.0/24" "192.168.50.1" 25`

### Quality and security recommendations
1. Including input validation to ensure that the network CIDR block, gateway IP, and count (if specified) are in the correct format would improve function quality.
2. The use of a dedicated IP address manipulation library or utility would improve the function's reliability and accuracy.
3. The script should check that ipcalc utility is available in the system before execution. If it's not, it should provide a meaningful error message.
4. Consider handling edge cases such as network CIDR blocks that don't have a suitable range for the specified count.
5. Implement error handling to deal with potential issues that may arise during calculation (e.g., inability to parse the network CIDR block or gateway IP, failure to convert IPs to integers, etc).
6. To improve security, sanitize all inputs to avoid potential code injection attacks.

