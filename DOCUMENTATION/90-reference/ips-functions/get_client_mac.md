#### `get_client_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 6b28946d90a3fddf9e18f05fe426e933a15b243f01dde38c4257f73ffa1f64f3

##### Function overview

The `get_client_mac` function is used to get the MAC (Media Access Control) address of a client machine through its IP address. This function makes use of ARP (Address Resolution Protocol) packets to find the MAC address assigned to an IP. If the initial method fails, it attempts to extract the MAC address using `arp` tool.

##### Technical description

- **Name**: `get_client_mac`
- **Description**: The function `get_client_mac` discerns and outputs the MAC address of a client machine given its IP address. It first confirms that the IP address is valid. If not, the function returns 1. If the IP address is valid, an ARP request is triggered via a ping request, forcing the target machine to respond and update the ARP table. The function then uses an `awk`-driven regular expression search within the IP neighbour list to extract the MAC address. On unsuccessful attempts, it tries to extract the MAC address using the `arp` command.
- **Globals**: `VAR` - No global variables used in the function.
- **Arguments**: `$1` - This argument represents the IP address for which the MAC address is to be fetched.
- **Outputs**: The MAC address associated with the given IP.
- **Returns**: If the supplied IP address is empty, the function will return 1. 
- **Example Usage**: `get_client_mac "192.168.1.1"`

##### Quality and security recommendations

1. Input validation should be more robust, ensuring that only valid IP addresses are accepted for further processing to avoid possible abuse or unexpected behavior.
2. To enhance performance, add a check for the MAC address in the local ARP cache before sending a ping request to the client machine.
3. Using `ping` and `arp` tools might be blocked by firewall rules or network policies. Always check if these tools can reach the client machine.
4. Include error detecting mechanisms to check if the ARP update or ping was successful.
5. The code must carefully handle the absence of the `awk` or `arp` commands on some systems. If these commands are not available, the function won't work as expected.

