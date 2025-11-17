### `n_ips_command`

Contained in `lib/node-functions.d/pre-load.sh`

Function signature: 49296795b09096589391a79f5e195603621ed9b9a086011ba67bdad22202778c

### Function overview

The `n_ips_command` function is a Bash script which sends requests to an IPS gateway (a specific type of network device). It builds a query string from the input command and an optional list of parameters, sends a POST request to the gateway with this information, then checks the HTTP status code in the response. If the request was successful the function will output the response to standard out (stdout). If any problems are detected, an error message is stored in the `N_IPS_COMMAND_LAST_ERROR` variable for later use.

### Technical description
###### name
n_ips_command - Sends a command to the IPS gateway, by preparing and sending a POST request.

###### description
Parses the command and additional parameters passed to the function. It builds a query string, encodes any URL specific characters and sends to the node provisioned by the IPS gateway. The response from the POST request is evaluated for error handling. If response is successful, it prints the response output.

###### globals
- `N_IPS_COMMAND_LAST_ERROR` : This is used to store the most recent error that has occurred. 
- `N_IPS_COMMAND_LAST_RESPONSE` : This is used to store the response of the most recent executed command.

###### arguments
- `$1` : Command to be executed on the IPS gateway
- `$@` : Additional parameters for the command in the format param=value (optional)

###### outputs
- Prints the response received from executing the command on the IPS gateway to standard out

###### returns
- `1` : If fails to determine the IPS gateway
- `2` : If curl exits with a non-zero status code
- `3` : If the request ends with any HTTP Error code starting with 4 or 5
- `0` : If all operations are successful

###### example usage
`n_ips_command YOUR_COMMAND Param1=Value1 Param2=Value2`

### Quality and security recommendations
1. Avoid storing sensitive data in global variables. If needed, clear or overwrite them as soon as their purpose is served.
2. As curl's `-w` write out option is used which enables cURL to output debug information, ensure no sensitive data is being outputted for security reasons.
3. URL encoding is not applied on the key passed as argument which as of now is not a problem but might become a security risk if these keys are not standardized, and can contain special characters.
4. Add input validation techniques to ensure sensible and safe values are passed as arguments.
5. Handle other potential HTTP status codes, such as 3xx redirect responses, to make your script more robust.

