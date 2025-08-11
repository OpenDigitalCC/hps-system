#### `host_config_show`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 6105ece190686264b3985f4c2de384ff48edc977456deeb1f70f8a863bb065a8

##### Function Overview

The function `host_config_show()` is designed to read and display a configuration file for a host in a network. Accepting a MAC address as a parameter, it looks for the corresponding configuration file in the `HPS_HOST_CONFIG_DIR` directory, which is defined elsewhere in the script. If the configuration file exists, the function reads it through line by line. For each line it extracts a key and a value separated by `=`. If any value exists for the key, then it's presented in a specific format. Also, the function logs an informational message if no configuration file exists for the given MAC address.

##### Technical Description

- **Name:** `host_config_show()`
- **Description:** Reads and displays a host's configuration file based on its MAC address.
- **Globals:** `[ HPS_HOST_CONFIG_DIR: Directory where host configuration files are stored.]`
- **Arguments:** `[ $1: The MAC address of a host in the network. ]`
- **Outputs:** Outputs each key-value pair from the config file, with special characters such as quotes and backslashes in values properly escaped. If no configuration file exists for the provided MAC address, it logs an informational message.
- **Returns:** Returns `0` if no configuration file exists, signaling that the function ran successfully with this outcome.
- **Example Usage:**

    ```bash
    host_config_show "00:0a:95:9d:68:16"
    ```

##### Quality and Security Recommendations 

1. Sanitize the input to ensure that the MAC address is in a valid format. This can help to prevent potential command injection attacks or unintended behavior.
2. Check if the `HPS_HOST_CONFIG_DIR` global is set before attempting to use it. If it's not set, the function should return an error.
3. For a more resilient design, handle unexpected errors such as reading from a corrupt config file or issues with file permissions.
4. Avoid disclosing too much information in log files to prevent potential information leakage.
5. Log not only the absence of a configuration file, but also when a file is found and successfully processed.

