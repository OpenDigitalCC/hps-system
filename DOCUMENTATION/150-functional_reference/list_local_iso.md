### `list_local_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 2551c5d34fea622a4876a48c635391772020f951a812cc21a423cc6b87227a67

### Function Overview

The `list_local_iso` function in bash is designed to locate and list ISO files that match a specific naming pattern in a designated directory. The naming pattern is created based on the input arguments detailing the CPU type, manufacturer, operating system name, and optionally, the operating system version. If no matching ISO files are found, the function outputs an alert message and returns a status code of 1. If matches are found, the base name of each matching ISO file is outputted.

### Technical Description

- Name: `list_local_iso`
- Description: The function searches for and lists ISO files in a directory that match a specified naming pattern, made up from the arguments for CPU type, manufacturer, operating system name, and potentially, the operating system version.
- Globals: None required.
- Arguments: 
    - `$1`: The CPU type descriptor.
    - `$2`: The manufacturer descriptor.
    - `$3`: The operating system name descriptor.
    - `$4`: (Optional) The operating system version descriptor.
- Outputs: A status message indicating the search process for local ISOs and the names of any ISO files found that match the naming pattern. If no matches are found, an alert message is outputted.
- Returns: If no matching files are found, the function returns `1`.
- Example Usage: `list_local_iso intel dell windows 10`

### Quality and Security Recommendations

1. Conduct regular checks on the permissions assigned to the directory referenced in this function to ensure ISO files are not accessible to unauthorized parties.
2. Sanitize inputs to prevent potential code injections or file misdirections.
3. Implement error handling or exception management for situations where the directory does not exist or is not accessible.
4. Improve the clarity of existing function documentation especially with regards to its behavior when handling optional arguments.
5. Consider enhancement to allow for different patterns or multiple directories searching.

