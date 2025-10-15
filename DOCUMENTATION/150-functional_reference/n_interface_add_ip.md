### `n_interface_add_ip`

Contained in `lib/host-scripts.d/common.d/n_network_functions.sh`

Function signature: 7e40d3cc8158f30bbc3b61ed12b5bdee7c2150fd7411dc6b70f9cb96ed29457e

### Function overview

The `n_interface_add_ip` function in Bash is used to add an IP address with an optional netmask to a specified network interface. If the netmask is provided not as a CIDR, the function also converts it to CIDR format.

### Technical description

- **Name:** `n_interface_add_ip`
- **Description:** This function is used to add an IP address to a network interface. If a netmask is provided not as a CIDR, the function converts it to the CIDR format.
- **Globals:** [ ]
- **Arguments:** 
  - `$1: iface` Network interface to which an IP address will be assigned.
  - `$2: ip_addr` The IP address to be added to the network interface.
  - `$3: netmask` The netmask for the IP address to be added. It can be in CIDR or standard netmask format.
- **Outputs:** The function outputs the return status of the `ip addr add` command.
- **Returns:** The function returns the exit status of the `ip addr add` command. If the command is successful it returns 0, otherwise, it returns a non-zero status.
- **Example usage:**
```bash
n_interface_add_ip eth0 192.168.1.10 24
```

### Quality and Security Recommendations

1. It is recommended to add input validation for arguments to ensure correct values for network interface, IP address and netmask are passed to the function.
2. To ensure good security practices, you could check that the network interface exists before trying to add an IP address to it.
3. To ensure the good quality of function, consider the addition to handle error cases and outputs corresponding error messages to standard error for easier troubleshooting.

