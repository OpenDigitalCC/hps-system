### `keysafe_issue_token`

Contained in `lib/functions.d/keysafe_functions.sh`

Function signature: a535c705c6f66c5f6bb4cb03f77f0a1320e62fa27e687ab3cf0e601508b20886

### Function overview

The Bash function `keysafe_issue_token()` generates a unique token in two modes, open and secure, based on the provided client MAC address and the intended purpose. It saves the generated token along with some metadata in a file on the keysafe directory and then returns the token back to the caller. If no node id is provided as the third parameter when the function is called, it defaults to "unknown".

### Technical description

- **Name:** `keysafe_issue_token`
- **Description:** This function generates and returns a unique token after validating the arguments (client_mac and purpose). The function either uses a UUID for open mode or Biscuit token generation for secure mode (not yet implemented). It then records the information about the issued token.
- **Globals:** [ `HPS_CLUSTER_CONFIG_BASE_DIR: This holds the base directory for cluster configuration`, `HPS_KEYSAFE_MODE: Holds the keysafe mode which can be open or secure` ]
- **Arguments:** [ `$1: client_mac`, `$2: purpose`, `$3: node_id (optional, defaults to "unknown")` ]
- **Outputs:** Prints the generated token to stdout, or logs error messages to stderr when problems occur.
- **Returns:** `0 if successful`, `1 if keysafe directory not found`, `2 if unable to create token file`, `3 if required arguments are missing`, `4 if secure mode is not yet implemented`, `5 if invalid keysafe mode`.
- **Example usage:** `keysafe_issue_token "MAC_ADDRESS" "PURPOSE" "NODE_ID"`

### Quality and security recommendations

1. Improve error handling: Add more detail to error outputs, so that the specific error condition can be readily identified.
2. Implement secure mode: The secure mode for token generation has not been implemented and should be as soon as feasible.
3. Add validation for modes: Validate that only known modes ("open", "secure") can be assigned to `HPS_KEYSAFE_MODE`.
4. Exclude open mode in production: Do not use the open mode in a production environment as it is insecure and meant only for prototyping.
5. Store tokens securely: Depending on the function's usage, consider storing the generated tokens in a more secure or encrypted manner.

