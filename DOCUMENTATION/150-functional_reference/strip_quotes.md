### `strip_quotes`

Contained in `lib/functions.d/network-functions.sh`

Function signature: b2892c33de60887f65c7f2b7946fafee0d873041d3a244be57b49c6339bb1cb5

### Function overview

The `strip_quotes` function is designed to process a string and remove leading and trailing quotes. This includes both single ('') and double ("") quotes. The function achieves this through the use of local bash string manipulations.

### Technical description

- **Name:** `strip_quotes`
- **Description:** The function takes one string argument with either leading or trailing or both types of quotes and remove them.
- **Globals:** None
- **Arguments:** 
    - `$1: str` This is a string input sent to the function. It is expected to have leading and/or trailing quotes which are to be removed.
- **Outputs:** The function prints the input string with the quotes removed.
- **Returns:** The function does not explicitly return a value, it only outputs the string without quotes via an echo command.
- **Example usage:** `strip_quotes "\"Hello World!\""` or `strip_quotes "'Hello World!'"`

### Quality and security recommendations
1. As the function does not account for inner quotes within the string, it is advisable to extend its functionality to handle such cases.
2. While executing scripts, always validate/filter the inputs for any malicious content, as appropriate. In this context, the function could be extended to check and validate the input string.
3. Since the function echoes the output, it might lead to risk of command injection attacks. A better way would be to return the value and let the caller decide what to do with the returned value.
4. Provide more descriptive error messages that would explain the problem if the script fails.
5. Increase resilience of the function by handling edge cases such as empty strings or strings without quotes.

