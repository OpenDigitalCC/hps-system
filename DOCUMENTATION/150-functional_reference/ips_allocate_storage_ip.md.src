### `ips_allocate_storage_ip`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 7dcadc01ce4c2633c148412e7ddeaa6b83b7f1be5339d9afcd614f25a2171b25

### Function Overview
The `ips_allocate_storage_ip` function is designed for allocating storage IP addresses in a given network storage environment. It takes two arguments: `storage_index` and `source_mac`. The function validates these arguments and also checks if the storage network is properly configured. If all checks are successful, it calculates the VLAN ID and validates the configuration. If an IP allocation already exists for the source_mac, it returns the existing allocation, otherwise, it looks for the next available IP to allocate.

### Technical Description
- **Name**: `ips_allocate_storage_ip`
- **Description**: Allocates storage IP addresses in a storage environment where multiple VLANs are used for traffic segregation.
- **Globals**: None.
- **Arguments**: 
  - `$1 (storage_index)`: Index of the storage to allocate IP address.
  - `$2 (source_mac)`: The MAC address of the source requesting the IP allocation.
- **Outputs**: Prints VLAN, IP, Netmask, Gateway, MTU details if successful or error messages during failures.
- **Returns**: Returns 0 if a new IP address was successfully allocated or an existing allocation was found; returns 1 in case of errors such as missing or invalid arguments, uninitialized storage network, unavailable IPs, failed subnet parsing, etc.
- **Example usage**: `ips_allocate_storage_ip 0 "00:11:22:33:44:55"`

### Quality and Security Recommendations
1. There is a chance of IP address exhaustion since the function starts searching for available IP addresses at `.100` and stops at `.250`. Consider implementing a more robust method for allocating IP addresses to prevent exhaustion, e.g., using DHCP.
2. Consider setting up detailed logging at every step, so that errors and issues can be tracked down more easily.
3. Implement input sanitization to prevent potential security issues resulting from unexpected or malicious input.
4. Proper error handling steps should be followed to ensure that the function fails gracefully in case of errors.
5. Implement helper function testing to ensure consistency and reliability of helper functions used in the main function.
6. The allocation process uses recursion which could lead to stack overflows if not handled properly. Ensure that potential recursive errors are anticipated and handled.

