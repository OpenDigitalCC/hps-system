### `n_network_get_interfaces`

Contained in `lib/node-functions.d/common.d/n_network-functions.sh`

Function signature: cde74a72e94b4ca270a63fc91054620090ca6a1841b86382e554ab03431369eb

### Function overview

The `n_network_get_interfaces` function is a Bash function that's used to discover the attributes of all network interfaces on a Linux system. It handles each network interface found in the `/sys/class/net` directory, skipping non-physical ones. For each valid interface, it gathers basic attributes like the operational state, MAC address, MTU, speed, driver name, IPs and IP assignment type (dhcp or static). The function then echoes this information in a string format.

### Technical description

- **name** : `n_network_get_interfaces`
- **description** : Retrieves attributes of all network interfaces on a Linux system.
- **globals** : None.
- **arguments** : No arguments are passed to the function.
- **outputs** : For each network interface, outputs a string containing the interface's name, operational state, MAC address, MTU, speed, driver, IPs and IP assignment type.
- **returns** : Does not explicitly return a value.
- **example usage** : `n_network_get_interfaces`

### Quality and security recommendations

1. Implement error-handling. Right now, the function does not handle potential errors beyond suppressing the output of commands that might fail. Improving error-handling could make the function more robust and easier to debug.
2. Validate inputs. While the function currently doesn't accept any arguments, if this changes in the future, all user-supplied inputs should be validated.
3. Keep up-to-date with system changes. The function relies on several system files and commands to retrieve network interface information. Ensure these are consistent with the current system configuration.
4. Avoid exposing sensitive information. The `echo` command used in the function could potentially reveal sensitive information (such as MAC addresses), depending on where the function's output is directed.
5. Simplify the function for better maintainability. The function is quite long and complex, try to simplify and refactor the function to make it easier to read and maintain.

