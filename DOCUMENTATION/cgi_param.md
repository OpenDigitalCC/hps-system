## `cgi_param`

Contained in `lib/functions.d/cgi-functions.sh`

### Function overview

The `cgi_param` function is a tool for managing CGI parameters in a Bash script environment. It reads from a query string and saves the validly formatted key-value pairs into a global associative array. The function also supports methods for retrieving the value of a specified key (command "get"), checking if a specified key is present (command "exists"), and validating if a key's value equals to a given value (command "equals"). An invalid command results in an error message and a returned value of 2.

### Technical description

- **name**: `cgi_param`
- **description**: The function processes CGI parameters passed as a query string. It supports handling command and key-value pairs, reading from query string only once, dispatching commands (get, exists, equals), and error handling when an invalid command is put in.
- **globals**: [ `__CGI_PARAMS_PARSED`: A flag indicating whether the query string has been parsed, `CGI_PARAMS`: An associative array holding key-value pairs from the parsed query string ]
- **arguments**: [ `$1`: The command, `$2`: The key, `$3`: An optional value used for the "equals" command ]
- **outputs**: For the command "get", if the key exists, it prints the corresponding value. For an invalid command, it prints an error message.
- **returns**: No specific return value. Overall result mainly depends on the success of the commands run.
- **example usage**: `cgi_param "get" "example"`

### Quality and security recommendations

- Apply more rigorous input validation and error handling where required to ensure the robustness and reliability of the script.
- Avoid using environment variables (`QUERY_STRING`) directly, as they can be very unpredictable.
- Be aware of the risk of command injection as the script has the potential to be exploited.
- Restrict the regex patter that validates the `decoded_key` to include only what's necessary in order to avoid potential security vulnerabilities.
- Use a more descriptive name for the function for better readability and maintainability.
- Always initialize your variables.
- Validate `key` before using it, as it might not be in a valid format.

