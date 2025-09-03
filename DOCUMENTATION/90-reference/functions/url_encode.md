### `url_encode`

Contained in `lib/host-scripts.d/common.d/common.sh`

Function signature: 244a7c143b13a17ef50725eef748c82a2bd2df462a35d3727b81937558bae3ec

### Function Overview

The `url_encode` function is used to encode URLs in Bash. The function accepts a string as an input and returns a URL-encoded string as output. It scans through each byte of the input string and performs a case-by-case encoding. Specifically, all alphanumeric characters and the special characters .,_ and - are left as they are. Spaces are replaced with '%20' hex value for fast processing, and all other characters are replaced with their respective '%' followed by their hex value.

### Technical Description

- **Name**: url_encode
- **Description**: This function is used for URL encoding in Bash. It accepts a string, iterates through its characters and replaces each character based on particular rules.
- **Globals**: N/A
- **Arguments**: $1: input string for url encoding.
- **Outputs**: URL-encoded string.
- **Returns**: 0
- **Example usage**: 
    ```
    s="HELLO World!?/#"
    url_encode "$s"
    ```

### Quality and Security Recommendations

1. Consider using a well-established library or built-in function for URL encoding if available, as there might be edge cases we are not considering in this implementation.
2. Make sure you always encode URLs when using them as part of commands or requests, as failure to do so could lead to command injection or other security vulnerabilities.
3. It is essential to write unit tests for this function to make sure it works as expected. Consider testing with all types of characters including alphanumeric and special characters.
4. Avoid the use of the variables with generic names like 's', 'out', 'c', 'i' to improve readability.
5. Consider handling the case of receiving more than one parameter by showing an error message.
6. Document the purpose of disabling SC2039 ShellCheck warning at the beginning of the function.

