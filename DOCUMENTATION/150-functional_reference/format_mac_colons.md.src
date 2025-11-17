### `format_mac_colons`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 5496abb67b397a89b718680b3f650d5c789886634c83a14eef1474f51a2ddb06

### Function Overview

The `format_mac_colons()` function takes in a MAC address as an argument and outputs the MAC address in lowercase with colons inserted after every two characters. It first validates whether the provided MAC address is valid and consists entirely of hex characters. If the MAC address is missing or in an invalid format, the function will output an error message to stderr and halt execution.

### Technical Description

- **Name**: `format_mac_colons()`
- **Description**: This function formats a MAC address by removing any existing delimiters (colons, dashes, dots) and then re-inserting colons after every two characters. The outputted MAC address is always in lowercase.
- **Globals**: None
- **Arguments**: 
   - `$1 (mac)`: the MAC address to be formatted
- **Outputs**: If the input MAC address is valid, it outputs the formmated MAC address to stdout. If the input MAC address is invalid or missing, it outputs an error message to stderr.
- **Returns**: The function returns 0 if the MAC address was successfully formatted. It returns 1 and ceases execution if the MAC address is invalid or missing.
- **Example usage**: `format_mac_colons "AB-CD-EF-12-34-56"`
  
### Quality and Security Recommendations

1. **Error Checking**: Add explicit error checking for the input MAC address argument to ensure that it meets expected characteristics such as its length and whether it only contains valid characters.

2. **Detailed Error Messages**: Include more details in the error messages for easier troubleshooting. For example, the error message can indicate which part of the MAC address string is incorrect.

3. **Testing**: Add more comprehensive unit tests for this function to cover all edge cases.

4. **Documentation**: Document the expected format of a MAC address explicitly at the start of the function.

5. **Robust Input Handling**: The current handling of different delimiter characters ('-', ':', '.') is good, but could be made more robust by adding support for variations in letter case (upper/lower) and spacing within the MAC address.

