### `host_config_show`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 6105ece190686264b3985f4c2de384ff48edc977456deeb1f70f8a863bb065a8

### Function Overview

The `host_config_show` function in Bash is used to read a host configuration file that corresponds to a certain MAC address. If a configuration file doesn't exist for a given MAC address, an informational log message is displayed. If found, the function reads through the file, trims any leading or trailing quotes from each value, escapes any embedded quotes and backslashes, and then echoes each key-value pair.

### Technical Description

- **Name:** `host_config_show`
- **Description:** Reads a host configuration file that matches a given MAC address. The function will output key-value pairs from the file, with necessary characters escaped for safety. If no such file exists, it logs an informative message.
- **Globals:** 
  - `HPS_HOST_CONFIG_DIR`: This global points to the directory where host configuration files are stored. 
  - `hps_log`: This global logs messages based on the application's events.
- **Arguments:** 
  - `$1`: This is the MAC address of the device. It's supposed to match with a configuration file within the directory specified by `HPS_HOST_CONFIG_DIR`. 
  - `$2`: This argument is not used by the function.
- **Outputs:** Key-value pairs from the configuration file, if it exists. Otherwise, an information log message is output.
- **Returns:** Returns 0- indicating successful execution of the function.
- **Example Usage:** `host_config_show "04:0E:3F:A1:B2:C3"`

### Quality and Security Recommendations

1. Implement argument validation: `host_config_show` could fail unexpectedly (or silently) if it receives unexpected data. Implement checks for the MAC address format and whether `HPS_HOST_CONFIG_DIR` is set.
2. Use clearer env var names: `HPS_HOST_CONFIG_DIR` and `hps_log` could be renamed to more descriptive names for better readability of the code.
3. Handle failure condition: Does the user need to know when `host_config_show` can't find a particular MAC address? If so, consider changing the return code from 0 in case a corresponding configuration file doesn't exist for the mac address passed.
4. Sanitize file reading: The `read` command used in the while loop might encounter issues dealing with special character sequences. Use `-r` option to prevent this.
5. Protect against variable shadowing: By using `local` for `mac` and `config_file`, this function avoids shadowing variables in the parent scope. Make sure to follow this good practice in the rest of your code as well.

