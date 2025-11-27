### `n_interface_add_ip`

Contained in `lib/node-functions.d/common.d/n_network-functions.sh`

Function signature: 6a786746bbd31691fcadd616683c9d48446f70621c619cbce04fff61c3e311ed

### Function overview

This function, `n_interface_add_ip`, is used to add an IP address to a specified network interface. This is a low-level operation typically used in network setup or reconfiguration scripts. The function takes three arguments: the name of the network interface, the IP address to be added, and the netmask. The final argument, the netmask is also converted to CIDR notation as needed. If provided IP address is already assigned to the network interface, the function logs this condition and returns without making changes.

### Technical description

- **name**: `n_interface_add_ip`
- **description**: Adds an IP address to a specified network interface. The function also converts the provided netmask to CIDR form. 
- **globals**: None
- **arguments**: 
    - `$1`: The network interface to which the IP address will be added. 
    - `$2`: The IP address to add.
    - `$3`: The network mask associated with the IP address.
- **outputs**: Notifies user if the provided IP already exists on the specified interface. 
- **returns**: 
    - 1 if invalid arguments are passed.
    - 0 if the operation is successful or the IP address already exists on the interface.
- **example usage**: `n_interface_add_ip eth0 192.168.1.2 255.255.255.0`

### Quality and security recommendations

1. Ensure to use this function with valid and trusted input only. The function does not sanitize or validate input, therefore, untrusted input could potentially lead to issues.
2. Return codes should be handled or verified after calling this function to ensure the operation was successful.
3. Implement error handling to account for potential failure in IP assignment.
4. The function can potentially accept a CIDR notation netmask as it doesn't perform validation. This could be a useful extension or a potential issue needing to be addressed, depending on your context. If you need to restrict addresses to a traditional 4 octet netmask, you could add a check for this.
5. Avoid using this function in scripts that don't need to alter network configurations. Using such functions can be a potential security risk.

