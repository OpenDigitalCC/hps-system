## `ip_to_int`

Contained in `lib/functions.d/network-functions.sh`

### Function Overview

The **ip_to_int()** function is used to transform an IPV4 address that was passed as an argument, into an integer equivalent. It does this by splitting the IP address into its four octets and executing bit-shift operations followed by additions.

### Technical Description

- **Name:** ip_to_int()
- **Description:** This function converts an IPV4 address, passed as a string, into an equivalent integer. The IP address is split into octets which undergo bit-shift operations and are then added together for the result.  
- **Globals:** None
- **Arguments:**
   - **$1:** IP address string to be converted.
- **Outputs:** An integer corresponding to the input IPV4 address.
- **Returns:**
    - Returns the integer equivalent of the input IPV4 address.
- **Example usage:**
    -  `ip_to_int "192.168.1.1"`
    - The outputs will be `3232235777` which stands for the integer equivalent of IP address "192.168.1.1".

### Quality and Security Recommendations
1. Input validation is always a good practice. Ensure that the input string meets all criteria for a valid IPV4 address before proceeding with conversion.
2. Use local variables instead of globals whenever possible, as globals can be manipulated in other parts of the script, potentially leading to unexpected results.
3. Always double-quote your variables when using them. This prevents word splitting and pathname expansion.
4. Error handling should be added for cases where there are input or computation errors for improved reliability.

