### `get_host_mac_by_keyvalue`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 4e6ce4d36c6772f4c729ca17b2e92f175a648b408ef7b40a3be7b78ad7931ede

### Function overview
The `get_host_mac_by_keyvalue` function is used to find and echo the MAC address of a host based on a provided key-value pair. If the key-value pair is found in any of the host configuration files in the active cluster hosts directory, the function will echo the name of the file (which is the MAC address of the host) and return with success. 

The function performs a case-insensitive search and will also clean up any quotes present in the value. If either the search key or value is not provided, the function will return an error.

### Technical description
Definition block for `get_host_mac_by_keyvalue`:

- **Name**: `get_host_mac_by_keyvalue`
- **Description**: Searches through the configuration files in the active cluster `hosts` directory for a specified key-value pair. If found, the function will echo the filename (which corresponds to the MAC address of that host).
- **Globals**: 
  - `VAR: desc`: None
- **Arguments**: 
  - `$1: search_key`: The key to search for. It is converted to uppercase for a case-insensitive match.
  - `$2: search_value`: The value to be matched with the search key. It is converted to lowercase for a case-insensitive match.
- **Outputs**: 
  - If a match is found, the function echoes the filename (which corresponds to the MAC address of the host).
- **Returns**: 
  - `0`: Success, if a match is found.
  - `1`: Error, if a match is not found or any of the search parameters are missing.
- **Example usage**:
  ```bash
  get_host_mac_by_keyvalue "HOSTNAME" "myhost"
  ```

### Quality and security recommendations
1. Instead of executing the function in the current shell environment, consider using a subshell to encapsulate the variables and limit their scope, enhancing security.
2. Implement logging to record function usage and errors for easier debugging and tracking of potential security issues.
3. Validate the inputs to prevent injection attacks or to handle special characters properly.
4. Add more error checks and provide clear error messages for easier debugging and better user experience.
5. Consider handling more edge cases, such as when there are multiple matches found.

