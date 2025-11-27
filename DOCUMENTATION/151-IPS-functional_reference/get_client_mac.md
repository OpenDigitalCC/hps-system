### `get_client_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: e78a1e2a6af41211f58dd51387958635e90d617e0529987a019dab359db2e31c

### Function overview
The `get_client_mac()` function is a bash script function that extracts the MAC address of a client machine on the network. It receives the client's IP address as an argument and initiates an ARP (Address Resolution Protocol) update to ensure the network recognize the existing machine. The script uses regular expressions to extract the MAC address from the returned ARP data and returns the resulting MAC address. It is noted that there is a fallback mechanism to use the 'arp' command if the 'ip neigh' command does not capture the MAC address. However, this part of the code is commented out in the provided example.

### Technical description
Definition block for Pandoc:

- Name: `get_client_mac`
- Description: This function attempts to obtain the MAC address of a client given its IP address.
- Globals: None
- Arguments: 
  - $1: IP address of the client machine.
- Outputs: The MAC address corresponding to the given IP address.
- Returns: 1 if the IP address is not provided, 0 otherwise.
- Example usage: 
  ```bash
  get_client_mac 192.168.1.1
  ```
  Output will be the MAC address linked to the IP `192.168.1.1`

### Quality and security recommendations
1. Un-comment the block of code that falls back to ARP if the `ip neigh` command does not return a MAC address. This would serve as a backup way of obtaining the MAC address.
2. Include error handling for undesired input such as non-IP formatted strings.
3. Consider including more return codes to specify different kinds of errors to make the function usage and debugging easier.
4. Users should avoid exposing the MAC address retrieved by this function as MAC addresses are unique, and malicious entities can use them to track the network activity of the target machine.
5. It might be safer and recommended to use secure shell protocol (SSH) for any network-commuting commands or utilities.

