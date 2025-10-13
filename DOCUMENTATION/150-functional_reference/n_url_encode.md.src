### `n_url_encode`

Contained in `lib/host-scripts.d/pre-load.sh`

Function signature: 4e21e5663f425634af5a4baa7396afcc1884c8ecdeb58e9f5ffd146304fd834a

### Function Overview

This function, `n_url_encode()`, is used to encode a provided string in the URL encoding standard. Each non-alphanumeric character in the input string is replaced with its hexadecimal representation prefixed by '%'. Alphanumeric characters, as well as '.', '~', '_', and '-', are left as-is. Spaces are also replaced by '%20'. 

### Technical Description

- **Name**: 
   - `n_url_encode()`
- **Description**:
   - This function encodes a provided string into URL encoding format by converting each non-alphanumeric character into a hexadecimal representation prefixed by '%'.
- **Globals**: 
   - `(LC_ALL=C)`: This changes the locale to `C` to ensure predictable character classification.
- **Arguments**: 
   - `($1)`: This is the string input that will be URL encoded.
- **Outputs**: 
   - There is no explicit output. The result is printed to the standard output.
- **Returns**: 
   - The function returns a new URL encoded string.
- **Example Usage**:
  ```bash
  n_url_encode "Hello, World!"
  # Outputs: Hello%2C%20World%21
  ```

### Quality and Security Recommendations

1. Input validation should be implemented for the function argument. This ensures that the function input is a string before attempting to perform the URL encoding operation.
2. For better readability and maintainability, consider using meaningful variable names instead of single letters.
3. Each special character used should have a clear comment indicating why it's being included in the URL encoding process.
4. ShellCheck warnings should not be ignored unless absolutely necessary, as they might indicate potential bugs or security vulnerabilities. Issue `SC2039` is being ignored here, which relates to the use of undocumented/bin/sh features, and should be addressed appropriately.
5. Try to avoid using global variables where possible, as this can lead to unwanted side-effects if they are modified elsewhere in the script.
6. Although this function can be used in any shell script, care should be taken not to use it on data that is already encoded, as it may lead to double encoding issues. Plan your code to avoid such situations.

