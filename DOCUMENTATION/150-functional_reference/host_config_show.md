### `host_config_show`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 84f65b3dca74b99c5f2890c67f216c67c0deb77fe856d7ec3d6f8447b05622e8

### Function Overview 

The `host_config_show()` function in Bash is used to display the configuration of a specific host, based on the provided MAC address. After validating the MAC is provided, it uses a helper function to get the path of the config file, perform necessary checks, and then it reads and displays the config file while managing the format, escape sequences, and quotes. If the config file is not found, it throws an information log entry with the respective MAC.

### Technical Description 

- **Name:** host_config_show
- **Description:** This bash function displays the configuration of a specified host based on the MAC address supplied as an argument. It checks for the validity and existence of the MAC and reads the corresponding configuration file. Comments and empty lines in this file are skipped and in the end, key-value pairs are displayed in a specifically formatted manner.
- **Globals:** N/A
- **Arguments:** 
    1. `$1` - The MAC address. It must be supplied for the function to display the configuration.
- **Outputs:** The function outputs key-value pairs from a config file. Formatted as `key="value"`.
- **Returns:** The function returns 0 if the operations are successful and the key-value pairs have been displayed; 1 if a MAC address is not provided or not found, in these cases an info log or error log is displayed.
- **Example usage:** 
    ```
    host_config_show "00:0a:95:9d:68:16"
    ```

### Quality and Security Recommendations 

1. The function can be improved by making sure that the MAC address passed is in the valid format. This can be achieved by using regular expressions.
2. The error messages can be made more detailed to explain the underlying issues more clearly.
3. Consider handling the reading of the file line by line in a more safe manner for experimental file types.
4. Handle exceptions and edge cases, such as non-string inputs or unexpected behavior from the helper function `get_host_conf_filename`.
5. For better security, always sanitize the provided input to prevent potential Bash injection attacks.

