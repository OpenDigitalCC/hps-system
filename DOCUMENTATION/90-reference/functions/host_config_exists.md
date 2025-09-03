### `host_config_exists`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 93698d3265775cdeb0581fb007522cdb74832e2c705812027e67b512cd33964b

### Function Overview

The `host_config_exists` function is a Bash function in that checks for the existence of a specific configuration file based on a provided *mac* address. It takes a *mac* address as an argument, and constructs a file path to the configuration file using the *mac* address as the file name and a pre-defined directory as its path. It then uses a conditional statement to check if the file exists, returning a boolean indicating the result.

### Technical Description

- **Name:** `host_config_exists`
- **Description:** The function checks for the existence of a specific configuration file that correlates to the provided *mac* address.
- **Globals:** 
    - `HPS_HOST_CONFIG_DIR`: This global variable defines the directory where the configuration files are stored.
- **Arguments:** 
    - `$1: mac`: This argument is the *mac* address which will be used as the base for configuration file name.
- **Outputs:** This function does not directly output any value.
- **Returns:** The function returns a boolean value which indicates whether the sought configuration file exists.
- **Example Usage:**
```bash
if host_config_exists "00:11:22:33:44:55"
then
    echo "Configuration file exists."
else
    echo "Configuration file does not exist."
fi
```

### Quality and Security Recommendations

1. Make sure the `HPS_HOST_CONFIG_DIR` is always defined and set to a valid directory to prevent the function from searching in the incorrect location, leading to incorrect results.
2. Consider validating the *mac* argument to ensure that it is a valid *mac* address. This could prevent potential errors down the line or potential security vulnerabilities if malicious or incorrectly formatted *mac* addresses are provided.
3. The function should handle or communicate any errors it encounters during execution in a secure manner. Currently, it does not communicate any issues outwardly.
4. To better adhere to Unix philosophy, consider making the function output informative messages or codes to standard error when it encounters problems (e.g. when the directory does not exist).
5. Always remember to mark your variables as local where possible to prevent them from leaking into the global script environment, which can be a security risk and a source of bugs. This function does a good job of this by declaring `mac` and `config_file` as local variables.

