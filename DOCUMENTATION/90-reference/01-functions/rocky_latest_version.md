#### `rocky_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: f42e139a07133ae36c4e9783c1fbb144e1167e59537bd374c0b346f853c77a3d

##### Function Overview

The `rocky_latest_version` function is used to retrieve the current latest version of Rocky Linux. The function does this by issuing a cURL request to the official Rocky Linux download page, parsing the returned HTML for version numbers and sorting them. The function then returns the highest version number.

##### Technical Description:

- **Name**: rocky_latest_version
- **Description**: This function retrieves the latest version number of Rocky Linux by parsing the HTML from the official Rocky Linux download webpage.
- **Globals**: 
    - base_url: The URL to the official Rocky Linux download webpage
    - html: Stores the HTML content retrieved from the Rocky Linux download page 
    - versions: An array that stores the version numbers extracted from the HTML content
- **Arguments**: This function does not take any arguments.
- **Outputs**: If successful, the function will output the latest version number of Rocky Linux.
- **Returns**: 
    - 1: If the cURL request fails or no version numbers are found in the HTML content
    - The latest version of Rocky Linux: If the cURL request is successful and version numbers are found in the HTML content
- **Example Usage**:
    ```bash
    rocky_latest_version
    ```

##### Quality and Security Recommendations

1. Always use the `-r` (raw) option with the `readarray` or `mapfile` Bash built-ins to avoid problems with backslashes. A `-t` option could also be added to remove trailing newlines.

2. The function could be improved by adding error handling for the case where the Rocky Linux download page URL changes or becomes inaccessible.

3. For critical applications, avoid parsing HTML with regex carefully. Instead, use a proper HTML parsing tool or API if available.

4. Consider validating the output of this command before using it in your script. For instance, you could check that the format of the returned version number matches your expectations.

5. Avoid logging sensitive information. Since this function doesn't handle sensitive data, it's not a concern in this case, but it's a good general practice when writing Bash scripts.

