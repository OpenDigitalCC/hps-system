### `cgi_param`

Contained in `lib/functions.d/cgi-functions.sh`

Function signature: 85408b6df1acbfa275ec1da76b313025e087b22ded762bda3f063e12f6b557f6

### Function overview

The `cgi_param` function in Bash is used to interpret and manipulate parameters from a QUERY_STRING in a CGI context. The function provides different actions based on the input command provided to it. The available commands are 'get', 'exists', and 'equals'. The function begins by checking if QUERY_STRING has been parsed. On its first run, it decodes the QUERY_STRING into key-value pairs and stores them for subsequent use. It then uses the chosen command to return specific outputs.

### Technical description

- **Name:** `cgi_param`
- **Description:** A function for interpreting and manipulating parameters from a QUERY_STRING in a CGI context.
- **Globals:**
  - `__CGI_PARAMS_PARSED`: It indicates whether the QUERY_STRING has already been parsed into key-value pairs. 
  - `CGI_PARAMS`: Associative array that holds the decoded key-value pairs from the QUERY_STRING.
- **Arguments:**
  - `$1: Command`: The action that the function should perform - 'get', 'exists', or 'equals'.
  - `$2: Key`: The name of the CGI parameter to be retrieved, checked for existence, or compared to a value.
  - `$3: Value`: An optional value to compare with the value of the specified CGI parameter. Only associated with the 'equals' command.
- **Outputs:** The function outputs either the value of the specified parameter (if the command is 'get'), or specific exit code that indicates the function's success.
- **Returns:** The function generally does not have a numeric return value, exits are primarily via 'return'.
- **Example Usage:**
```bash
cgi_param get username
cgi_param exists email
cgi_param equals state active
```

### Quality and security recommendations

1. Validate all input: Although the function performs some validation on the key inputs, also ensuring the validation of command and value inputs could increase security.
2. Regularly update the function to meet current best practices and standards.
3. Avoid using global variables: Global variables can be altered anywhere in your script, leading to unpredictable results. Use if only necessary and ensure to control their state.
4. Provide clear error messages: The function could provide more detailed error messages that clearly indicate what the user did wrong.
5. Secure the function against SQL injection: The function currently does no specific check against SQL injection attacks. Consider implementing features to guard against this.
6. Consider edge cases: Always consider possible edge cases in order to ensure that the function behaves reliably.

