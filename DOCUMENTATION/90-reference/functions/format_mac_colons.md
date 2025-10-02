### `format_mac_colons`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 95ebd5c4198ab3943c5263e6ec4e563812216afc2059562fef0d3c1357dc53ca

### Function Overview

The `format_mac_colons` function is designed to validate a MAC address input, convert it to lowercase, and insert colons in the MAC address format. This simplifies the process of formatting MAC addresses to adhere to standard MAC address representation.

### Technical Description

**Function name:** `format_mac_colons`

**Description:** This function validates a supplied MAC address to ensure it consists of exactly 12 hexadecimal characters. After validation, it converts the MAC address to lowercase and inserts colons in the appropriate position to adhere with the standard representation of a MAC address. 

**Globals:** None

**Arguments:** 
- `$1`: This argument should be a MAC address of 12 hexadecimal number.

**Outputs:** If valid, a MAC address with colons inserted would be produced. If invalid, the function will output an error message directed to the standard error output (stderr).

**Returns:** 
- `1`: if supplied MAC address is invalid. 
- Formatted MAC address: if the supplied MAC address is valid.

**Example usage:**
```bash
format_mac_colons "123456abcdef"
```

### Quality and Security Recommendations

1. Input Sanitization: Ensure that the input to the function is properly sanitized before it is processed by the function.
2. Error Handling: The function should have plans to handle unexpected inputs (like a null input or an input with non-hexadecimal characters) and not just invalid length.
3. Include a clear and descriptive comment on what the function does at the beginning of the function. This includes listing out all assumptions, preconditions and postconditions.
4. Add more detailed output messages that can guide the user on the type and format of input the function requires whenever invalid inputs are provided.
5. It would be beneficial to provide more return codes to cover other potential error situations, such as an empty input string. Making return codes more descriptive can make debugging simpler.
6. Always ensure to follow the least privilege principle - only give the minimum amount of permissions necessary for the function to execute.

