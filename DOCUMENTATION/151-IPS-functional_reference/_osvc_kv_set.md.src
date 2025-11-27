### `_osvc_kv_set`

Contained in `lib/functions.d/opensvc-functions.sh`

Function signature: e83bb88e314eb7098eb2ed8868cdecf150f3a7c4cec631f0ac14eadabbeaa0d3

### Function overview

The function `_osvc_kv_set()` is a local key-value setter. This bash function sets a key-value combination in the OSVC configuration file. It uses the local variable `k` to represent key, and `v` to represent value. These are then passed to `om config set` with the `--kw` option.

### Technical description

- **Name**: `_osvc_kv_set`
- **Description**: This function takes a key and a value as inputs, and sets this pair in the OSVC configuration, by using `om config set` command.
- **Globals**: None.
- **Arguments**: 
  - `$1: key` - This argument represents the key that we need to set.
  - `$2: value` - This argument represents the corresponding value for the key.
- **Outputs**: Executes `om config set` with `--kw` option and the passed key-value pair.
- **Returns**: None. The changes are made in the configuration.
- **Example usage**: `_osvc_kv_set "myKey" "myVal"`

### Quality and security recommendations

1. Check for null or empty key-value pairs: Before setting a key-value pair in the configuration, it should be validated that neither the key nor the value is null or empty. This could be done as a guard clause within the function.
2. Avoid overriding of existing keys: While setting a new key-value pair, ensure that the key does not already exist to prevent unintentional overwriting.
3. Input sanitization: Ensure that key and value inputs do not contain characters that could potentially exploit script vulnerabilities or disrupt normal operation.
4. Configuration file permissions: Check for necessary permissions before updating the configuration file. If the permissions are not sufficient, the function should either notify the user or fail gracefully.

