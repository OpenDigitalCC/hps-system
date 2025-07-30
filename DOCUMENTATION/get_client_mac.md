## `get_client_mac`

Contained in `lib/functions.d/network-functions.sh`

### Function overview
The `get_client_mac` function is designed to retrieve and output the MAC address of a specified client in a network based on its IP address. This function ensures the validness of the stated IP, triggers an Address Resolution Protocol (ARP) update, as well as uses both the `ip neigh` command and `arp -n` command to get and print the MAC address.

### Technical description
```
- Name: get_client_mac
- Description: This function retrieves the Media Access Control (MAC) address of a specified client from the network using its Internet Protocol (IP) address.
- Globals: None.
- Arguments: 
   - $1: IP address of the client whose MAC address needs to be retrieved.
- Outputs: Prints the MAC address of the specified client based on its IP address, if it's found. Otherwise, it'll print nothing.
- Returns: 1, if the IP address is not valid.
- Example usage: get_client_mac 192.168.1.2
```
### Quality and security recommendations
- Implement proper input validation. This code assumes that the input passed is an IP address, but there's no validation to check if the format is correct.
- Check for the existence of required utilities like `ping`, `ip` and `arp`. The code doesn't handle scenarios where these utilities might be absent on the system.
- Be caution about executing `ping` or any other system commands directly from the function. It might open up attacks through command injection.
- Be aware of privacy concerns. Fetching MAC addresses can be seen as intrusive, as MAC addresses are often used to uniquely identify devices on a network.
- Use functions or utilities provided by your language of choice to reduce reliance on system commands. This will also likely improve the robustness and efficiency of your code.
- Regular upgrades and patching of the underlying system are critical to ensure security.

