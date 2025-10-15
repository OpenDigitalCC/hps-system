### `n_remote_host_variable`

Contained in `lib/host-scripts.d/pre-load.sh`

Function signature: a6a6dcce5193b038b3b72301649c925f02faeada882cdad35f26a54763120ec0

### Function overview

The `n_remote_host_variable` function is used to get or set remote host variables. The function is built to receive two arguments: a `name` which refers to the name of the variables, and an optional `value`, which if present, signifies that we are performing a SET operation. If the `value` is absent, the function defaults to a GET operation. The function executes an `n_ips_command` to perform either the variable SET or GET operation, and receives an exit code. It outputs the result of the operation if it is successful, otherwise it logs the error description and returns the error code.

### Technical description

#### name
`n_remote_host_variable`

#### description
Performs GET or SET operation on a specified remote host variable depending on the presence of a second argument.

#### globals
`N_IPS_COMMAND_LAST_ERROR`: stores the last error message from the `n_ips_command`.

#### arguments
`$1`: Specifies the name of the remote host variable.

`$2`(optional): If this parameter is present, a variable SET operation is performed. If not, a GET operation is executed.

#### outputs
If the operation is successful, the result from the `n_ips_command` operation will be printed. Otherwise, an error message will be logged.

#### returns
0: If the `n_ips_command` operation is successful.
    
Otherwise returns the code signifying the type of error occurred during the operation.

#### example usage

To get a remote host variable:
```bash
n_remote_host_variable "hostname"
```
    
To set a remote host variable:
```bash
n_remote_host_variable "hostname" "127.0.0.1"
```

### Quality and security recommendations
1. Always ensure that the name parameter (`$1`) is provided while making a call to `n_remote_host_variable`. If not, the function should throw an informative error.
2. Ensure to validate user inputs before use. This can help ward off potential security vulnerabilities such as command injection attacks.
3. Make sure to always check the exit code of the `n_ips_command` to handle potential errors effectively.
4. It's recommended to enclose variables in double quotes to avoid word splitting and globbing.
5. Log all potential error messages for easier debugging.
6. Always remember to check the validity of the host variable before making a GET or SET operation call to the `n_ips_command`.

