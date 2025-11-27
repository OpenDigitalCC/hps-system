### `n_network_show_vlans`

Contained in `lib/node-functions.d/common.d/n_network-functions.sh`

Function signature: f26ff21c1e6be88c21597a853a7bba0ce26eb5cdde8d64ee5d8674a12a3b2bbc

### Function Overview

This function, `n_network_show_vlans`, explores the `/sys/class/net` directory. It attempts to find network devices that have VLANs (Virtual Local Area Networks). For each valid VLAN device, it collects various statistics about the device such as its current operational state, MTU (Maximum Transmission Unit), VLAN ID, and any IPv4 addresses associated with it.

### Technical Description

This function has the following technical details:

- **Name:** n_network_show_vlans
- **Description:** Iterates over the `/sys/class/net` folder directory. It checks for network interfaces that carry VLANs. For each valid interface, it captures the interface's current operational state, MTU, VLAN ID, and associated IPv4 addresses.
- **Globals:** None.
- **Arguments:** None.
- **Outputs:** For each valid network device, it echoes a colon-separated string containing the `interface name`, `operational state`, `IPv4 addresses`, `MTU`, and `VLAN ID`.
- **Returns:** It doesn't explicitly return a value. However, it echoes the required string for each valid network interface.
- **Example usage:** 

    To show VLANs in a network, simply call the function without any argument as `n_network_show_vlans`.

### Quality and Security Recommendations

1. Add more error handling: The script currently defaults to continue on errors such as invalid interface entries in the `/sys/class/net` directory. Consider adding more granular error checking and reporting.
2. Use functions for operations performed repeatedly: For instance, the code to read from sysfs files could be collected into a single, reusable function with good error handling.
3. Validate directory and file paths: Current implementation may break if, during runtime, the expected interface directories or their contents are not available. Consider protobuf compatibilities.
4. Implement function return codes: To ensure that the function can be safely used in other scripts, consider including return codes to indicate the success or failure of the function.
5. Secure Information: Ensure information such as IP addresses, VLAN ID are used or stored securely when using this function as bash scripts are plain text files.

