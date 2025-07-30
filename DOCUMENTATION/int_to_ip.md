## `int_to_ip`

Contained in `lib/functions.d/network-functions.sh`

### Function Overview
The `int_to_ip()` function is designed to convert an integer into IP format. This function is often used to work with IP addresses in scripts, supporting tasks like network conversions and other networking-related operations.

### Technical Description
- **Name**: `int_to_ip()`
- **Description**: This function takes an integer as an input and converts it into a corresponding IP address.
- **Globals**: None
- **Arguments**: 
  - `$1`: The integer value that needs to be converted into an IP address.
- **Outputs**: Outputs the IP address corresponding to the input integer.
- **Returns**: None
- **Example Usage**:
    ```bash
    local network="192.168.1.0"
    local broadcast="192.168.1.255"
    local gateway_ip="192.168.1.1"
    local net_int=$(ip_to_int "$network")
    local bc_int=$(ip_to_int "$broadcast")
    local gw_int=$(ip_to_int "$gateway_ip")
    echo "$(int_to_ip "$gw_int")"
    ```

### Quality and Security Recommendations
1. The function suffers from a lack of input validation. Any integer can potentially be passed into the function. Therefore, ensure to validate the integer before conversion to avoid any potential errors or security vulnerabilities.
2. You should add error handling in case of unexpected input (e.g., non-integer values) or unexpected return values.
3. Consider enclosing the whole block of code into another function with its specific functionality. It would increase the reusability of your code.
4. Add comments to improve code readability and maintainability.
5. Consider returning meaningful error messages instead of letting the script fail silently.
6. Security-wise, sanitize all inputs to the bash function in order to prevent injection attacks.
7. Update your function to use the standard error output (stderr) for error messages.

