#### `cgi_param`

Contained in `lib/functions.d/cgi-functions.sh`

Function signature: 5007f95c313c04a01df7ba39bff0241f44511cd570d795bc11a890edf032f323

##### Function overview
The `cgi_param` function parses the `QUERY_STRING` once and then performs some action based on the provided command (`$cmd`). The possible commands are `get`, `exists`, and `equals`. The `get` command prints the value of the parameter with the provided key (`$key`). The `exists` command checks if the given key exists. The `equals` command verifies if the value of the given key is equal to the provided value (`$value`). If the command is not recognized, the function prints an error message and returns `2`.

##### Technical description
**Function**: `cgi_param`

**Description**: The function parses the `QUERY_STRING` to obtain CGI parameters only once, and perform actions (`get`, `exists`, `equals`) on these parameters depending on the command provided.

**Globals**: [ `__CGI_PARAMS_PARSED`: A flag used to ensure that the `QUERY_STRING` is parsed only once, `CGI_PARAMS`: An associative array that holds the parsed CGI parameters]

**Arguments**: 
- `$1(cmd)`: The command to be executed on the CGI parameters. It can be `get`, `exists`, or `equals`.
- `$2(key)`: The key of the CGI parameter to be processed.
- `$3(value)`: The value that is supposed to be compared with the value of the CGI parameter specified by `$key` in case of `equals` command.

**Outputs**: Depending on the `cmd` argument, the function might:
- print the value of the `$key` parameter (`get` command),
- print an error message when an unrecognized command is provided.

**Returns**: 
- Nothing, in scenarios where the function checks whether a certain parameter exists.
- `2` when an invalid command is provided.

**Example Usage**:

```
cgi_param get username
cgi_param exists userpassword
cgi_param equals sessionId 12345
```

##### Quality and security recommendations
1. Consider using more strict error handling: Currently, the function only handles unrecognized commands but does not cover cases where other arguments might be missing or provided in an incorrect format.
2. Sanitize all input: Before passing the `QUERY_STRING` to the `read` command, ensure it doesn't contain any malicious data that can lead to command injection or other vulnerabilities.
3. Validate parsed parameters: Besides checking the parameters' format before storing them in the `CGI_PARAMS` array, it would be beneficial to also check their content (e.g., make sure the values are within expected boundaries/standards for specific keys).
4. Document expected format and restrictions for `QUERY_STRING`, `$cmd`, `$key`, and `$value`: Having a clear explanation on how the function expects its input, and how it handles unexpected input, can help prevent misuse and make debugging easier.

