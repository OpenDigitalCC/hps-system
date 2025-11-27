### `netmask_to_cidr`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 591afba929cc6e4793e6bae6dbae1c9f2b4f4429ff9102867ddd8a651f7f496d

### Function overview

The `netmask_to_cidr` function is designed to accept a standard IP netmask as an argument and return the equivalent Classless Inter-Domain Routing (CIDR) notation. The CIDR notation is a compact representation of a network's IP address and its associated routing prefix. For example, the netmask `255.255.255.0` equals a CIDR of `24`.

### Technical description

- **Name:** `netmask_to_cidr`
- **Description:** This function receives netmask as an argument and converts it into CIDR.
- **Globals:** N/A
- **Arguments:** `$1: netmask` (The standard IP netmask need to be converted into CIDR. E.g., 255.255.255.0)
- **Outputs:** The CIDR notation. (E.g., 24)
- **Returns:** 
0 if it successfully echoes the CIDR.
1 if the provided netmask doesn't match any predefined value.
- **Example usage:**
```bash
$ cidr="$(netmask_to_cidr '255.255.255.0')"
echo $cidr  # Output: 24
```

### Quality and security recommendations

1. Implement error checking to ensure the netmask provided is a legit netmask in the correct format.
2. Return error codes consistently so calling code can distinguish between different types of error situations.
3. Improve documentation, especially for the return values and what conditions lead to those return values.
4. Apply defensive programming principles such as checking that the function received exactly 1 argument, and return an error immediately if not.
5. Sanitize the input to prevent possible injection attacks. Although it's highly unlikely in this specific function, it's still a good habit to form in bash programming.

