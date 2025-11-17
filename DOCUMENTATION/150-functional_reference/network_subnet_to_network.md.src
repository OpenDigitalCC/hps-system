### `network_subnet_to_network`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 86f8adc9399482c2b4132b1a58360669317a1355449f2c1bdefdc599f5997e0f

### Function overview

The function `network_subnet_to_network` is used to convert a network subnet into a network address. It does this by removing the CIDR suffix from the input subnet. It takes the subnet as an argument, checks if it's not empty, removes the CIDR suffix and verifies if the result is not empty. If the subnet is empty or without a CIDR suffix, the function returns 1. Otherwise, it echoes the network address and returns 0.

### Technical description

- **Name:** network_subnet_to_network
- **Description:** Converts a network subnet into a network address.
- **Globals:** None
- **Arguments:** [ $1 - subnet: A string that represents a network subnet with a CIDR suffix. ]
- **Outputs:** On success, it outputs the network address without the CIDR suffix. If the input subnet is empty or without a CIDR suffix, no output is produced.
- **Returns:** The function returns 0 on success, or 1 if the input subnet is empty or without a CIDR suffix.
- **Example usage:** 

```bash
network_subnet_to_network "192.168.1.0/24"
```

### Quality and security recommendations

1. Add more validation on the subnet input to ensure it properly formatted. This function assumes the provided subnet includes a CIDR suffix, but does not validate this.
2. Return error messages on stdout to inform the user why an operation failed. A no output situation might not be intuitive for the user.
3. Consider exit codes more expressive of the error or success nature, instead of just 0 and 1.
4. Use more distinctive variable names to avoid any potential overlaps with environment variables.

