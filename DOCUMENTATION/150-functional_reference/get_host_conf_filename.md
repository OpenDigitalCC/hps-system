### `get_host_conf_filename`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 8b543e00f7c0c713c4d8c537217c6a9c6addf01207ee1dfb10ecf00e0041e3e7

### Function overview

The `get_host_conf_filename` function accepts a MAC address as an argument and proceeds to look for a corresponding configuration file in the active cluster hosts directory. If the MAC address is not provided, the function logs an error and returns. If the active cluster hosts directory cannot be determined, the function logs an error and returns. The function also logs errors and returns in the case that the configuration file does not exist or is not readable. When successful, the function outputs the path of the configuration file and returns zero.

### Technical description

- **Name:** `get_host_conf_filename`
- **Description:** This function is used to retrieve the path of a configuration file for a given MAC address in the active cluster hosts directory.
- **Globals:** None
- **Arguments:** 
  - `$1: MAC address` - This is expected to be a MAC address as a string.
- **Outputs:** If successful, this function will output the path to the configuration file.
- **Returns:**
  - `0` if the function successfully retrieves the path of the configuration file.
  - `1` if either the MAC address is not provided or the active cluster hosts directory cannot be determined.
  - `2` if the configuration file does not exist or is not readable.
- **Example usage:**

  ```bash
  get_host_conf_filename "00:0A:95:9D:68:16"
  ```

### Quality and security recommendations

1. Validate the format of the MAC address not only for presence but also for the correct syntax.
2. Handle exceptions for the `get_active_cluster_hosts_dir` function call.
3. Consider testing if the configuration file is not just readable but also in a valid format.
4. In addition to logging, consider more user-friendly error handling that informs what actions the user should take.
5. Securing the directory and files that the function accesses to prevent unauthorized changes.
6. Consider using more general exit status codes to increase portability across different systems.

