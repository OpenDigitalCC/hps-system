### `_osvc_create_hb_secrets`

Contained in `lib/functions.d/opensvc-function-helpers.sh.sh`

Function signature: aed67edfeb1fd1a63d3e83b7088b23dd0bd8242d25f17ebe70d11e474348804d

### Function overview

The bash function `_osvc_create_hb_secrets` checks if a heartbeat secret object exists, checks for the presence of a secret key, creates this secret object if it does not exist, generates a random secret for heartbeat authentication and adds it to the object. The function also verifies the created heartbeat secret.

### Technical description

- **Name**: `_osvc_create_hb_secrets`
- **Description**: This function checks for the presence of a heartbeat secret object, creates one if it does not exist, generates a random secret, and adds it to the object. After addition, it verifies the function of the secret.
- **Globals**: None
- **Arguments**: No directly passed arguments
- **Outputs**: Logs various debug, info and error messages about the status and process of heartbeat secret object creation and verification.
- **Returns**: 0 if the heartbeat secrets are successfully configured, 1 if any error occurs during the process.
- **Example usage**:
```bash
_osvc_create_hb_secrets
```

### Quality and security recommendations

1. This function does not use any command line arguments. It does not have any form of argument sanitization or validation as there are no arguments.
2. This function relies heavily on the commands `om` and `openssl`, check that these system utilities are available and reliable in the bash environment.
3. For system hardening, the error redirections `>/dev/null 2>&1` and `2>/dev/null` could potentially hide valuable debugging information. Consider more granular log verbosity controls.
4. For security considerations, investigate how secrets are transmitted, to avoid leakage. 
5. Review the error handling mechanisms to ensure failed function calls are properly handled.
6. The random secret key generation using /dev/urandom could be examined to ensure that it meets security best practices.
7. Ensure that all 'hps_log' output is correctly routed and secured, as it might contain critical system information.

