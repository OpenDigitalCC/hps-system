### `n_node_information`

Contained in `lib/host-scripts.d/common.d/common.sh`

Function signature: a53c403a79b02efa055af96455d7288b4626bc0cee2439f670491834854b9407

### Function Overview

The function `n_node_information()` is used to gather and report information about a node in a network. The function first checks if it can load the host configuration; if it cannot, it returns an error message and exits the function. It then gathers key information about the node such as IP address, MAC address, uptime, console status, and count of active services. Finally, it prints this information in a structured format. If the console is disabled, it adds a specific note to connect via SSH.

### Technical Description

**Name:** `n_node_information()`

**Description:** This function collects basic information about the node and then prints it in a structured manner. 

**Globals:** 
- `HOSTNAME`: The hostname of the node
- `TYPE`: Type of node
- `HOST_PROFILE`: Profile for host
- `STATE`: Current state of the node
- `IP`: IP address of the node
- `NETMASK`: Network mask of the node
- `provisioning_node`: IP of the provisioning node
- `mac_address`: MAC address of the node
- `dns_domain`: DNS domain of the node
- `uptime_display`: Uptime of the node
- `active_count`: Number of active services
- `virtualization_status`: Virtualization status (if any)
- `virtualization_type`: Virtualization type (if any)
- `console_status`: Console status (either "enabled" or "disabled")
- `UPDATED`: Information about the last update

**Arguments:** None

**Outputs:** Prints a detailed report about the node's information to the console

**Returns:** Returns 0 if everything went well, returns 1 in case of failure to load host configuration

**Example Usage:**
```bash
n_node_information
```

### Quality and Security Recommendations

1. Handle Errors: It is better to have formal error handling where error messages are stored in a log rather than echoed to the console.
2. Shell Config: Consider using ShellCheck as a static analysis tool for shell scripts to avoid common errors and pitfalls.
3. Security: If the data is sensitive or needs to be secure, ensure it's over a secure connection or encrypted.
4. Validate Inputs: Even though this script doesn't accept user inputs directly, it's always a good practice to validate, filter, or sanitize any inputs.
5. Check Return Values: Always check the returned value of a command before proceeding with the script. If a certain command fails, it's better to inform the user and halt the script, instead of continuing and possibly leading to unpredictable results.

