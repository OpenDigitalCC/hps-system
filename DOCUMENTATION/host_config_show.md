## `host_config_show`

Contained in `lib/functions.d/host-functions.sh`

### Function overview

The `host_config_show` function in Bash is primarily used to process a configuration file for a specific host identified by a MAC address. If a configuration file does not exist for the given MAC address, it logs the info and returns. If a configuration file does exist, it reads each line (considering each line as a key-value pair, separated by '=') and processes it by trimming and escaping special characters in the value associated with each key. After processing, it then echoes these key-value pairs.

### Technical description

- **name**: host_config_show
- **description**: This function is designed to process a host's configuration file identified by its MAC address. It performs tasks such as reading key-value pairs, trimming and escaping special characters in the values, and returning the key-value pairs.
- **globals**: [
    - HPS_HOST_CONFIG_DIR: Directory where host configuration files are stored.
    ]
- **arguments**: [
    - $1: The MAC address used to identify the host's configuration file.
    ]
- **outputs**: It outputs processed key-value pairs read from the configuration file.
- **returns**: It returns 0 if no configuration file exists for the given MAC address.
- **example usage**: 

```bash
host_config_show "00:0a:95:9d:68:16"
```

### Quality and security recommendations

- Escape all the other special characters that can cause issues if not properly handled.
- Validate the input MAC address format.
- Implement error handling to manage scenarios when the directory does not exist or does not have the required permissions.
- Test the function with a large configuration file to ensure performance is not affected.
- When displaying log messages, consider using a logging level more granular than 'info', so that users can control the verbosity of the logs.
- If possible, manage the secured reading of configuration files, especially if they contain sensitive information.
- Consider refactoring the method's internals in a way that doesn't just `echo` out the output, in order to provide more flexible usage of the function.

