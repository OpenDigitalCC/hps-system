### `normalise_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: 597ad94d9559d604fae13c8fd8ef8bde5b6c19fee81c409691213ad492d3d6b3

### Function Overview

The `normalise_mac` function in Bash is used to standardize the format of MAC addresses. It accepts a single MAC address as input, removes all common delimiters (such as "-" , ":" , "." or white space), converts it to lowercase, and validates the resulting output for being exactly 12 hexadecimal characters, which is the standard MAC address format.

### Technical Description

- **name**: normalise_mac
- **description**: Normalizes the provided MAC address by removing common delimiters, converting to lowercase, and validating the MAC address format.
- **globals**: NA 
- **arguments**: [ $1: A string representing a MAC address. Input MAC address could be with any common delimiters like colon(:), hyphen(-), dot(.) or a whitespace.]
- **outputs**: The function outputs a standardized MAC address in lowercase and without delimiters if the input is valid. If the input doesn't match the standard MAC address format, it outputs an error message to stderr "[x] Invalid MAC address format: $1". 
- **returns**: The function returns with a status of zero when successfully offering a normalized MAC address. It returns a status of 1 if the provided MAC address is invalid.
- **example usage**: 
   ```
   $ normalise_mac "01-23-45-67-89-ab"
   0123456789ab
   ```

### Quality and Security Recommendations

1. Be cautious while handling the argument and take steps to ensure that it does not carry any harmful inputs such as shell code injections.
2. Always use the function in a safe environment, taking into consideration input sanitation and privilege separation.
3. To enhance the function, consider adding more input validations, such as checking if the input is null or empty before processing.
4. Lastly, always inform the users of the function about the correct input to provide. Since the function expects an argument to be a MAC address, providing this in the function's help or documentation would help avoid confusion and unexpected output.

