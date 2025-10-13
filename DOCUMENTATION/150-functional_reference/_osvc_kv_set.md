### `_osvc_kv_set`

Contained in `lib/functions.d/opensvc-functions.sh`

Function signature: 205e9959eb03768165fdad531dcee8a8f9e63a89fb6430c7cd0be2747c1488ee

### Function overview

The function `_osvc_kv_set` is designed to set the value for a specific configuration key within the data object. This function uses the `om config set` operation to establish the key-value pair, with the parameters for the key and value being specified as arguments upon invocation of the function.

### Technical description

**Name**: `_osvc_kv_set`

**Description**: The function configures a key-value pair for a specific configuration in a data object. This configuration takes place within the scope of `om` module's `config` operation.

**Globals**: None.

**Arguments**:

- `$1`: The first argument is the key that the user wants to set in the configuration. It is mandatory and will result in an error if not provided.
- `$2`: The second argument is the value to be associated with the key in the configuration. It is mandatory and will result in an error if not provided.

**Outputs**: The function itself doesn't directly output anything, but as it configures settings in a global scope there can be indirect effects based on the operation of the `om config set` operation.

**Returns**: This function does not have a return value.

**Example usage**: `_osvc_kv_set "username" "root"`

### Quality and security recommendations

1. It is recommended to ensure that the input parameters (key and value) are thoroughly validated before being passed to this function. This validation can include checks for input type, format, and length.
2. Avoid using sensitive information as keys as they may be exposed in log files or error messages.
3. Document clearly the usage of this function, as it has a direct impact on the configuration settings, and misuse can lead to unstable behavior of the application.
4. Ensure that only privileged users are able to execute this command to avoid unauthorized changes in the system's configuration.
5. Treat this command as a potential injection vector, sanitize input and avoid dynamic construction of configuration commands where possible.
6. Avoid logging the exact values of configurations to on-disk log files to prevent leak of sensitive data.

