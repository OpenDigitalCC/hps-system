### `check_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 3b874dd0168548a5363b9c63f357dab1016d452e1155213b1190930b50bb44c5

### Function overview

The bash function `check_latest_version()` is designed to check the latest version of an operating system provided by a manufacturer for a specified CPU architecture. The function currently supports operating systems hosted on `rockylinux.org`. Inputs include the CPU architecture, the manufacturer, and the operating system name. Outputs will be the latest version of the specified operating system or appropriate error messages.

### Technical description

- **Name:** `check_latest_version()`
- **Description:** This function checks the provided URL for the latest version of an operating system. Specifically tailored for `rockylinux.org`, the function parses the fetched webpage to find OS version numbers and returns the latest version found.
- **Globals:** No global variables are used in this function.
- **Arguments:** `$1: CPU architecture (Not currently used in function)`, `$2: Manufacturer (Not currently used in function)`, `$3: Operating System name (Used to form URL and output appropriate version or error messages)`
- **Outputs:** Latest version of the operating system or appropriate error messages.
- **Returns:** `0` if the latest version of the operating system is successfully found, `1` otherwise
- **Example Usage:** `check_latest_version x86_64 Intel rockylinux`

### Quality and security recommendations

1. Input Validation: Implement input validation for CPU architecture and manufacturer parameters, which are currently unused.
2. Error Handling: Additional error handling could be implemented if the curl command fails due to network issues.
3. Expand OS Support: The function's functionality could be expanded to support other OS providers beyond just `rockylinux.org`.
4. Secure HTTP Transfers: Consider enforcing HTTPS when fetching the HTML to enhance the security of the function.
5. Scrutinize Regular Expressions: Regular expressions used for matching versions could be reviewed and made more robust to prevent potential errors in output.

