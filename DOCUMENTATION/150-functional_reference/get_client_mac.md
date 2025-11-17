### `get_client_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 8cf7b608ec665ff47f16996d542d5d3ed0c9392116e453e8abfcc00eab616973

### Function Overview

The function `get_client_mac` is used to extract the MAC address corresponding to a given IP address in a local network. It sends a ping to trigger an ARP update, which is then parsed for the required MAC address. If the initial method does not succeed, it uses the `arp` command as a fallback and returns a normalized MAC address.

### Technical Description

- **Name:** get_client_mac
- **Description:** This function uses IP address to get its corresponding MAC address from the Address Resolution Protocol (ARP) cache. 
- **Globals:** None
- **Arguments:** 
    - `$1`: The IP address of the client. 
- **Outputs:** Normalized MAC address related to the IP address if found. 
- **Returns:**
    - `1` if the IP address is not valid or MAC address is not found.
    - MAC address corresponding to given IP address in normalized form.
- **Example Usage:**
    - `get_client_mac 192.168.1.1`
    - `MAC_ADDRESS=$(get_client_mac 192.168.1.1)`

### Quality and Security Recommendations

1. Ensure the user has required permissions to run the `ping`, `ip neigh` and `arp` commands to avoid permission denied errors.
2. Include error handling for cases where ARP does not contain an entry for the given IP address, emitting appropriate error messages.
3. Consider including a validation check for the normalized MAC address before returning it.
4. Use secure command execution to prevent injection attacks.
5. Consider returning a standardized error value, such as a null address or a specific error string, if the MAC cannot be found.

