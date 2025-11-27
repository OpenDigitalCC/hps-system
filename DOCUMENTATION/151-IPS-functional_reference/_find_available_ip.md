### `_find_available_ip`

Contained in `lib/functions.d/host-functions.sh`

Function signature: f21c0add962ad9b971cdda7e66770a3e4925154b0c1a68a3eb1f09996cf1d293

### Function overview

The `_find_available_ip` function is intended to find an available IP for a host in a cluster. It takes three arguments: the MAC address of the host (`mac`), the start IP of the DHCP server (`dhcp_ip`), and the range of IPs the DHCP server can assign (`dhcp_rangesize`). The function scans across the range of possible IPs to find one that is not currently in use by a host in the cluster.

### Technical description

- **name**: `_find_available_ip`
- **description**: This function computes the available IP for a MAC address provided there is an available slot within the DHCP server range.
- **globals**: None
- **arguments**: [ `$1`: MAC address of the host machine, `$2`: IP address of the DHCP (`dhcp_ip`), `$3`: size of the IP range that can be assigned (`dhcp_rangesize`) ]
- **outputs**: Outputs an available IP address if one is found.
- **returns**: Returns 0 if an available IP was found; Returns 1 if no available IP was found.
- **example usage**: `_find_available_ip "00:0a:95:9d:68:16" "192.168.1.1" "254"`

### Quality and security recommendations

1. Consider sanitizing the inputs to the function to protect against potential injection attacks.
2. Incorporate error handling mechanisms to handle unexpected function behavior such as inability to convert IP to integer or failing to get host configuration.
3. Implement check for extreme edge cases like negative range size and unformatted MAC or IP address.
4. Consider implementing function timeouts to prevent hung processes from halting the system.
5. Be sure to adequately secure the system which houses this data, as malicious access to MAC addresses and knowledge of their associated IP addresses can compromise the security of the network.

