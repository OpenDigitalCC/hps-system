### `get_network_interfaces`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 5f860b3e71cc7a8b5a1076bb49f656f0d7ddd17d0a523e3e4173aba7dffe4dc9

### Function Overview

This Bash function, named `get_network_interfaces`, is designed to retrieve information about all the network interfaces connected to your machine excluding the localhost. For each interface, it reports the interface name, associated IPv4 CIDR notation address, and the default gateway, if it exists. The three data points are concatenated into a string and piped through each iteration. If at least one interface is found and processed, the function returns 0, indicating success. Otherwise, it returns 1, indicating failure.

### Technical Description

**Function name**: `get_network_interfaces`

**Description**: This function scans and retrieves information about all network interfaces on the machine, excluding localhost. The information includes interface name, IP address and gateway details for each interface.

**Globals**: None

**Arguments**: None

**Outputs**: Outputs a string per network interface, structured as "`interface_name`|`ip_address`|`gateway`".

**Returns**: `0` if at least one network interface is found and processed, `1` otherwise.

**Example usage**:
```bash
get_network_interfaces
```

The function will print to stdout each non-loopback network interface on the local machine, along with relevant information.

### Quality and Security Recommendations

1. To reduce the risk of errors, consider validating and sanitizing command outputs before assigning them to local variables.
2. Be aware of the line `local ip_cidr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1)`. If the `ip` command or `awk` is not specified correctly, the line could fail silently because of `2>/dev/null`.
3. The function currently uses a `found` variable as a flag to check if any interfaces are found. This works as expected but can potentially be refactored to address potential edge cases. For example, if the call to `ip` command fails for some reason, the function may still return 0.
4. For increased robustness, consider handling errors in a more systematic way. This means capturing and handling potential error messages from the `ip` command.
5. Be aware of potential security implications. Since this command parses command-line output, it may be vulnerable to command injection. Recommend codifying precautionary measures against such attacks.

