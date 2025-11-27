### `parse_os_id`

Contained in `lib/functions.d/os-function-helpers.sh`

Function signature: 377174d0352f5462a85cd347c6433a1bb72d67220d6e9555a200df9e2ed68095

### Function Overview

The `parse_os_id` function is designed to parse the unique identifier of an operating system. This identifier is passed as an argument to the function in the form of a colon-separated string. The function will then break down this string into three distinct parts - the OS architecture, the OS name and the OS version using the Internal Field Separator (IFS).

### Technical Description

- **Name:** parse_os_id
- **Description:** This function accepts a colon-separated string as input and breaks it down into three key components - the OS architecture, OS name, and OS version.
- **Globals:** None
- **Arguments:**
  1. `$1`: os_id - It is the colon-separated operating system identifier string.
- **Outputs:** This function does not output any value. It assigns values to OS_ID_ARCH, OS_ID_NAME, and OS_ID_VERSION based on the breakdown of os_id.
- **Returns:** N/A
- **Example Usage:** 
~~~
os_id="amd64:ubuntu:18.04"
parse_os_id "$os_id"
echo $OS_ID_ARCH    # Output: amd64
echo $OS_ID_NAME    # Output: ubuntu
echo $OS_ID_VERSION # Output: 18.04
~~~

### Quality and Security Recommendations

1. Always make sure that you are passing a string in the appropriate format (architecture:name:version) for the function to work properly.
2. Ensure to validate the input and catch any errors if the input is not in the anticipated format.
3. Ensure that the function is compatible with the operating system's naming conventions.
4. Consider edge cases where the OS name or version contain unconventional characters that might break the parsing logic.
5. Avoid using global variables that may interfere with other functions or commands. Always use local variables unless a global variable is strictly necessary.
6. Always quote your variables to prevent word splitting.
7. Always check the return status of commands and functions used in your code to ensure they were successful.

