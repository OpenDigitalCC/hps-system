#### `host_config_exists`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 93698d3265775cdeb0581fb007522cdb74832e2c705812027e67b512cd33964b

##### Function overview

The `host_config_exists` function in Bash is used to check if a host configuration file for a specific MAC address exists. It does this by constructing the file path using a globally defined configuration directory and the MAC address (passed as an argument), and then checking if a file at that path exists.

##### Technical description

```bash
- Name:   host_config_exists

- Description:  This function checks for the existence of a host configuration file for a certain MAC address within a predetermined host configuration directory.

- Globals: 
    - HPS_HOST_CONFIG_DIR: The directory where host configuration files are stored.

- Arguments: 
    - $1: The MAC address of the host whose config file is being searched for.

- Outputs:  Outputs nothing to stdout or stderr, though Bash will naturally output an error message to stderr if there's an unexpected problem (e.g. insufficient permissions to access the directory).

- Returns:  Returns with 0 status if the host config file for the provided MAC address exists, otherwise returns with 1 status.

- Example Usage:   
```
host_config_exists "00:11:22:33:44:55"
```
If there's a config file "00:11:22:33:44:55.conf" in the directory specified by `${HPS_HOST_CONFIG_DIR}`, this will return with 0 status. Otherwise, it will return with 1 status.
```

##### Quality and security recommendations

1. Make sure that the `HPS_HOST_CONFIG_DIR` variable is set to a secure directory that only trusted users have read and write access to. This is to prevent any unauthorized access or changes to configuration files.

2. Validate the MAC address input in the function. This could be done by checking the format of the input to ensure that it follows the MAC format 6 groups of two hexadecimal digits.

3. Check that the discerned config file path is within the expected bounds to avoid any potential for directory traversal. 

4. Avoid using relative paths for the `HPS_HOST_CONFIG_DIR` to ensure that the function's output is always consistent regardless of the current working directory.

