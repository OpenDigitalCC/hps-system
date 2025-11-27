### `get_host_os_version`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 56ca07cdef820435f1b11fd42dcbf53229c722f8fa266f2cee5b4b33679d6167

### Function overview
The `get_host_os_version` function in Bash is utilized as a method to determine the version of the operating system on a specified host machine. It does this by first using the `get_host_os_id` function to pull the OS ID based on the machine's MAC address, then the `os_config` function to retrieve the version for that OS ID.

### Technical description

- **Name:** `get_host_os_version`
- **Description:** This function utilizes the MAC address of a target host machine to retrieve its OS ID and, subsequently, its OS version. Specifically, it uses the `get_host_os_id` function to get the OS ID from a given MAC address and passes this ID to `os_config` function together with the "get" and "version" arguments.
- **Globals:** None used in this function.
- **Arguments:**
  - `$1: Host machine's MAC address. The MAC address identifies a specific machine in the network.`
  - `$2: Not used in this function.`
- **Outputs:** If successful, it will output the OS version of the host. Action is undefined if the OS ID cannot be retrieved from the MAC address.
- **Returns:** Returns `1` if there is any error (i.e., if no OS ID is returned), else retrieves and returns the OS version of the host.
- **Example Usage:**
  ```bash
  $ get_host_os_version 00:00:00:00:00:00
  ```

### Quality and security recommendations

1. This function relies heavily on the `get_host_os_id` function, so make sure that function is thoroughly tested and fails gracefully if anything goes wrong.
2. Consider adding error checking for invalid or improperly formatted MAC addresses.
3. Be aware that MAC addresses can sometimes be spoofed, which could lead to misleading results. Additional security measures may be needed to confirm the identity of the host machine.
4. If the `os_config` function is capable of modifying system settings, ensure it is properly secured against unauthorized use.
5. The returned OS version should be sanitized if it's going to be used as an argument for other commands, to protect against command injection attacks.

