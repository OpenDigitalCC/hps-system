### `normalise_mac`

Contained in `lib/functions.d/network-functions.sh`

Function signature: ac8cefca0a4fe56f9e4ef01e54a13bb17bd1107670d5f1b98c4c04d07fd2425e

### Function overview 

The `normalise_mac()` function is used to validate and standardize the format of a MAC address. The function performs the following processes: it removes all the common delimiters such as colon (:), dash (-), dot (.), and space ( ). Then, it converts all the characters in the MAC address to lowercase. The last process validates the MAC address. The resulting MAC address should exactly have 12 hexadecimal characters. If the MAC address format is invalid, the function will print an error message and return 1. If the format is valid, it will display the normalized MAC address. 

### Technical description
```yaml
- name: normalise_mac
- description: A function to validate and standardize MAC addresses. It removes common delimiters, converts to lower case, and validates the address to be exactly 12 hexadecimal characters.
- globals: [ ]
- arguments: [ $1: The MAC address to be normalized and validated ]
- outputs: An error message to stderr if the MAC address is invalid. If valid, the normalized MAC address will be returned.
- returns: The function will return 1 if the MAC is invalid.
- example usage: normalise_mac "00-80-41-ae-fd-7e"
```

### Quality and security recommendations

1. Implement higher-level error handling: Rather than only printing to stderr, throw an error that can be caught by other parts of your application.
2. Ensure to sanitize input: Even though the script appears resistant to command injection, proper input sanitization should always be performed when accepting user input.
3. Testing: Add various test cases to confirm the function behaves as expected and is able to handle edge cases and unexpected inputs.
4. Document the function: Add clear and concise documentation to the function explaining its use, inputs, and outputs for better understandability and maintainability of code.
5. Return unique error codes: Return unique error codes for different error cases for easier debugging.

