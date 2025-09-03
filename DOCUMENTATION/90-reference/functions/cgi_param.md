### `cgi_param`

Contained in `lib/functions.d/cgi-functions.sh`

Function signature: 5007f95c313c04a01df7ba39bff0241f44511cd570d795bc11a890edf032f323

### Function overview

The bash function `cgi_param` is designed to decode and retrieve parameters from the `QUERY_STRING` in a CGI context. The function uses a query-string from the CGI context and processes it to detect commands and key-value pairs. The function is triggered to process the query string only once, with subsequent calls to commands (get, exist, equals) retrieving or comparing the saved values. If an unknown command is passed, an error message is returned.

### Technical description

- __Name__: `cgi_param`
- __Description__: This function parses a query string into parameters, then provides a way to retrieve a parameter value, check if a parameter exists, or see if a parameter's value matches a provided value by using the 'get', 'exists' or 'equals' commands respectively.
- __Globals__: 
    - `QUERY_STRING`: The string to extract parameters and their values from.
    - `__CGI_PARAMS_PARSED`: Global flag to detect if the query string has been parsed.
    - `CGI_PARAMS`: An array to save decoded keys and their values.
- __Arguments__: 
    - `$1`: The command to run: 'get', 'exists', 'equals'.
    - `$2`: The name of the parameter.
    - `$3`: Optional. The value to compare against when the command is 'equals'.
- __Outputs__: If the 'get' command is called, the value of the named parameter. If not, a success status or an error message in case of an invalid command.
- __Returns__: The function can return different values depending on the command given. If 'get' command, will print value to stdout. If 'exists', 0 is returned if parameter exists, 1 if not. If 'equals', returns 0 if parameter equals given value, 1 if not. Returns 2 if command is invalid.
- __Example usage__: 

```bash
cgi_param get username
cgi_param exists page_count
cgi_param equals user_role admin
```

### Quality and security recommendations
1. Use stricter validation on parameter keys while parsing. Right now, only alphanumeric characters plus underscores are allowed. However, consider more restrictive set.
2. Be sure to escape all variable expansions to prevent code injection.
3. Consider ways of handling or communicating parse failures more explicitly - it may prove difficult to debug if the `QUERY_STRING` is not formatted as expected.
4. Implement a more robust error handling mechanism. For example, when the user provides an invalid command, an exception should be handled that doesn't allow further execution of the script.
5. Add more guard clauses for blank, null, or unexpected inputs to avoid unexpected behaviour.
6. Always try to keep your function's behavior predictable and documented.

